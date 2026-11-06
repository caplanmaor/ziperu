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

  def test_a_symlink_entry_pointing_outside_the_destination_is_refused
    skip "needs symlink support" unless symlinks_supported?
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    link = File.join(@tmp, "escape")
    File.symlink("../outside", link)
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

  private

  def symlinks_supported?
    probe = File.join(@tmp, "probe-link")
    File.symlink("probe-target", probe)
    true
  rescue NotImplementedError, Errno::EACCES, Errno::EPERM
    false
  end
end
