# frozen_string_literal: true

# What ziperu offers beyond rubyzip: archive limits, verify, symlink
# entries, progress callbacks.

require_relative "test_helper"
require "tmpdir"

class FeaturesTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "a.zip")
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("dir/")
      zos.put_next_entry("dir/one.txt")
      zos.write("one " * 100)
      zos.put_next_entry("two.txt")
      zos.write("two " * 200)
    end
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    Ziperu.max_entries = nil
    Ziperu.max_total_size = nil
  end

  def test_max_entries_is_enforced_on_open
    Ziperu.max_entries = 2
    error = assert_raises(Ziperu::LimitError) { Ziperu::File.open(@zip) {} }
    assert_match(/entry count of 3, over the limit of 2/, error.message)
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(@zip) {} }
    Ziperu.max_entries = 3
    Ziperu::File.open(@zip) { |zf| assert_equal 3, zf.entries.size }
    # The archive is not held open by the refused attempt.
    Ziperu.max_entries = 1
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@zip) {} }
    File.delete(@zip)
  end

  def test_max_total_size_is_enforced_on_open
    Ziperu.max_total_size = 1000
    error = assert_raises(Ziperu::LimitError) { Ziperu::File.open(@zip) {} }
    assert_match(/declared total size of 1200/, error.message)
    Ziperu.max_total_size = 1200
    Ziperu::File.open(@zip) { |zf| assert_equal "two " * 200, zf.read("two.txt") }
    assert_raises(Ziperu::LimitError) do
      Ziperu.max_total_size = 10
      Ziperu::File.open_buffer(File.binread(@zip)) {}
    end
  end

  def test_verify_reports_entries_whose_data_is_corrupt
    Ziperu::File.open(@zip) { |zf| assert_empty zf.verify }
    bytes = File.binread(@zip)
    Ziperu::File.open(@zip) do |zf|
      e = zf.get_entry("two.txt")
      name_len, extra_len = bytes[e.local_header_offset + 26, 4].unpack("vv")
      pos = e.local_header_offset + 30 + name_len + extra_len + 4
      bytes[pos, 8] = "\xFF".b * 8
    end
    Ziperu::File.open_buffer(bytes) do |zf|
      failures = zf.verify
      assert_equal ["two.txt"], failures.keys.map(&:name)
      assert_kind_of Ziperu::DecompressionError, failures.values.first
    end
  end

  def test_verify_checks_encrypted_entries_only_with_a_decrypter
    path = fixture("rubyzip/zip-aes-256.zip")
    Ziperu::File.open(path) do |zf|
      assert_empty zf.verify
      assert_empty zf.verify(decrypter: Ziperu::AESDecrypter.new("password", Ziperu::AESEncryption::STRENGTH_256_BIT))
      failures = zf.verify(decrypter: Ziperu::AESDecrypter.new("wrong", Ziperu::AESEncryption::STRENGTH_256_BIT))
      assert_equal zf.entries.size, failures.size
    end
  end

  def test_symlink_entries_write_as_links_and_extract_on_request
    skip "needs symlink support" unless symlinks_supported?
    target = File.join(@tmp, "real.txt")
    File.write(target, "real")
    link = File.join(@tmp, "link.txt")
    File.symlink("real.txt", link)

    archive = File.join(@tmp, "links.zip")
    Ziperu::File.open(archive, create: true) do |zf|
      zf.add("real.txt", target)
      zf.add("link.txt", link)
    end
    Ziperu::File.open(archive) do |zf|
      entry = zf.get_entry("link.txt")
      assert_predicate entry, :symlink?
      assert_equal "real.txt", zf.read("link.txt")
      assert_equal Ziperu::Entry::STORED, entry.compression_method
    end

    out = File.join(@tmp, "out")
    _out, err = capture_io { Ziperu::File.open(archive) { |zf| zf.extract_all(out) } }
    assert_match(/skipped symlink/, err)
    refute File.symlink?(File.join(out, "link.txt"))

    FileUtils.rm_rf(out)
    Ziperu::File.open(archive) { |zf| zf.extract_all(out, symlinks: :create) }
    assert File.symlink?(File.join(out, "link.txt"))
    assert_equal "real", File.read(File.join(out, "link.txt"))
  end

  def test_a_symlink_entry_with_fields_the_raw_copy_loses_is_rewritten_as_a_link
    skip "needs symlink support" unless symlinks_supported?
    target = File.join(@tmp, "real.txt")
    File.write(target, "real")
    link = File.join(@tmp, "link.txt")
    File.symlink("real.txt", link)
    archive = File.join(@tmp, "links.zip")
    # An extended timestamp, as Info-ZIP writes: the raw copy would drop
    # it, so the entry is written afresh on the next rewrite.
    Ziperu.write_extended_timestamps = true
    Ziperu::File.open(archive, create: true) do |zf|
      zf.add("real.txt", target)
      zf.add("link.txt", link)
    end
    Ziperu.write_extended_timestamps = false
    Ziperu::File.open(archive) { |zf| zf.get_entry("real.txt").comment = "edited" }
    Ziperu::File.open(archive) do |zf|
      entry = zf.get_entry("link.txt")
      assert_predicate entry, :symlink?
      assert_equal "real.txt", zf.read("link.txt")
      assert entry.extra[:universaltime]
      assert_empty zf.verify
    end
  end

  def test_add_recursive_stores_symlinks_when_asked
    skip "needs symlink support" unless symlinks_supported?
    src = File.join(@tmp, "tree")
    FileUtils.mkdir_p(File.join(src, "sub"))
    File.write(File.join(src, "sub", "real.txt"), "real")
    File.symlink("sub/real.txt", File.join(src, "link.txt"))
    File.symlink("sub", File.join(src, "linkdir"))

    skipped = File.join(@tmp, "skipped.zip")
    _out, err = capture_io { Ziperu::File.add_recursive(skipped, src) }
    assert_match(/skipped symlink/, err)
    Ziperu::File.open(skipped) { |zf| assert_equal %w[sub/ sub/real.txt], zf.entries.map(&:name) }

    stored = File.join(@tmp, "stored.zip")
    assert_silent { Ziperu::File.add_recursive(stored, src, symlinks: :store) }
    Ziperu::File.open(stored) do |zf|
      assert_equal %w[link.txt linkdir sub/ sub/real.txt], zf.entries.map(&:name)
      assert_predicate zf.get_entry("link.txt"), :symlink?
      assert_equal "sub/real.txt", zf.read("link.txt")
      assert_predicate zf.get_entry("linkdir"), :symlink?, "a link to a directory is a link, not descended into"
    end
    assert_raises(ArgumentError) { Ziperu::File.add_recursive(stored, src, symlinks: :follow) }
  end

  def test_a_symlink_entry_pointing_outside_the_destination_is_refused
    skip "needs symlink support" unless symlinks_supported?
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    link = File.join(@tmp, "escape")
    File.symlink("../../outside", link)
    archive = File.join(@tmp, "escape.zip")
    Ziperu::File.open(archive, create: true) { |zf| zf.add("sub/escape", link) }
    out = File.join(@tmp, "out2")
    _out, err = capture_io do
      Ziperu::File.open(archive) { |zf| zf.extract_all(out, symlinks: :create) }
    end
    assert_match(/points outside/, err)
    refute File.symlink?(File.join(out, "sub", "escape"))
  end

  def test_progress_is_reported_for_extract_all_and_add_recursive
    seen = []
    out = File.join(@tmp, "out")
    Ziperu::File.open(@zip) do |zf|
      zf.extract_all(out, progress: ->(entry, done, total) { seen << [entry.name, done, total] })
    end
    assert_equal [["dir/", 1, 3], ["dir/one.txt", 2, 3], ["two.txt", 3, 3]], seen

    seen = []
    Ziperu::File.open(File.join(@tmp, "added.zip"), create: true) do |zf|
      zf.add_recursive(out, progress: ->(entry, done, _total) { seen << [entry.name, done] })
    end
    assert_equal [["dir/", 1], ["dir/one.txt", 2], ["two.txt", 3]], seen
  end

  def test_zipcrypto_entries_write_and_read_back
    [Ziperu::Entry::DEFLATED, Ziperu::Entry::STORED].each do |method|
      path = File.join(@tmp, "crypto#{method}.zip")
      data = "secret #{method} " * 300
      Ziperu::OutputStream.open(path, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |zos|
        zos.put_next_entry("s.txt", "", Ziperu::ExtraField.new, method)
        zos.write(data[0, 1000])
        zos.write(data[1000..])
        zos.put_next_entry("plain.txt")
        zos.write("x")
      end
      Ziperu::File.open(path) do |zf|
        entry = zf.get_entry("s.txt")
        assert_predicate entry, :encrypted?
        assert_equal 9, entry.gp_flags & 9
        assert_equal method, entry.compression_method
        assert_equal data.bytesize, entry.size
        assert_equal Zlib.crc32(data), entry.crc
        assert_equal data, entry.get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new("pw"), &:read)
        assert_raises(Ziperu::Error) { entry.get_input_stream(&:read) }
        assert_raises(Ziperu::Error) { entry.get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new("no"), &:read) }
        # The stream's encrypter applies to every entry, as in rubyzip.
        assert_predicate zf.get_entry("plain.txt"), :encrypted?
        assert_equal "x",
                     zf.get_entry("plain.txt").get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new("pw"),
&:read)
        assert_empty zf.verify(decrypter: Ziperu::TraditionalDecrypter.new("pw"))
      end
      Ziperu::InputStream.open(path, decrypter: Ziperu::TraditionalDecrypter.new("pw")) do |zis|
        zis.get_next_entry
        assert_equal data, zis.read
      end
    end
  end

  def test_zipcrypto_refuses_methods_it_cannot_encrypt
    assert_raises(ArgumentError) do
      Ziperu::OutputStream.write_buffer(encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |zos|
        zos.put_next_entry("z", "", Ziperu::ExtraField.new, Ziperu::Entry::ZSTD)
      end
    end
  end

  def test_a_commit_succeeds_while_another_instance_holds_the_archive_open
    outer = Ziperu::File.open(@zip)
    assert_equal "two " * 200, outer.read("two.txt")
    Ziperu::File.open(@zip) { |inner| inner.mkdir("added") }
    # The first instance keeps working on what it opened.
    assert_equal "two " * 200, outer.read("two.txt")
    outer.close
    Ziperu::File.open(@zip) { |zf| assert_includes zf.entries.map(&:name), "added/" }
    leftovers = Dir.children(@tmp).grep(/\.old\z/)
    assert_empty leftovers
  end

  private

  def symlinks_supported?
    probe = File.join(@tmp, "probe-link")
    File.symlink("probe-target", probe)
    true
  rescue NotImplementedError, Errno::EACCES, Errno::EPERM
    false
  end
end
