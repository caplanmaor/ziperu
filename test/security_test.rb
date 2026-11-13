# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Hostile archives: the shapes the zip crate's 9.1.x hardening and
# ziperu's own checks are for. Each one must be refused, skipped or read
# correctly, never written outside the destination or taken on trust.
class SecurityTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-security")
    @out = File.join(@dir, "out")
    FileUtils.mkdir_p(@out)
  end

  def teardown
    Ziperu.max_entry_size = nil
    FileUtils.rm_rf(@dir)
  end

  # Whatever appeared beside the destination that the test did not put there.
  def outside
    Dir.children(@dir).reject { |n| n == "out" || n == "src" || n.end_with?(".zip") }
  end

  def symlinks_supported?
    probe = File.join(@dir, "probe-link")
    File.symlink("probe-target", probe)
    true
  rescue NotImplementedError, SystemCallError
    false
  ensure
    FileUtils.rm_f(probe)
  end

  def test_a_unicode_path_field_cannot_rename_an_entry_out_of_the_destination
    # The header says safe.txt; Info-ZIP's Unicode Path field, CRC and
    # all, says ../evil.txt. Readers that honour the field (this one, the
    # crate, 7-Zip) see the latter name, and it has to go through the same
    # path check as any other.
    path = File.join(@dir, "upath.zip")
    Ziperu::OutputStream.open(path) do |z|
      e = Ziperu::Entry.new("", "safe.txt")
      field = e.extra.create(:unicodepath)
      field.name = "../evil.txt"
      field.crc = Zlib.crc32("safe.txt")
      z.put_next_entry(e)
      z.write("boom")
    end
    _out, err = capture_io do
      Ziperu::File.open(path) do |zf|
        assert_equal "../evil.txt", zf.entries.first.name, "the field is honoured, as 7-Zip would"
        zf.extract_all(@out)
      end
    end
    assert_match(/unsafe/, err)
    assert_empty outside
    assert_empty Dir.children(@out)
  end

  def test_the_central_directory_name_is_the_one_used_whatever_the_local_header_says
    # Readers that walk local headers (unzip streaming, some scanners)
    # would see same.txt; ziperu, like every central-directory reader,
    # sees what the directory says, and the one name goes through every
    # check. The data is the same bytes either way.
    path = File.join(@dir, "mismatch.zip")
    Ziperu::OutputStream.open(path) do |z|
      z.put_next_entry("same.txt")
      z.write("x")
    end
    bytes = File.binread(path)
    central = bytes.rindex("PK\x01\x02".b)
    bytes[central + 46, 8] = "ours.txt"
    File.binwrite(path, bytes)
    Ziperu::File.open(path) do |zf|
      assert_equal %w[ours.txt], zf.entries.map(&:name)
      assert_equal "x", zf.read("ours.txt")
      zf.extract_all(@out)
    end
    assert_equal %w[ours.txt], Dir.children(@out)
    Ziperu::InputStream.open(path) { |is| assert_equal "ours.txt", is.get_next_entry.name }
  end

  def test_a_file_entry_through_a_symlink_cannot_leave_the_destination
    skip "needs symlink support" unless symlinks_supported?
    # link -> ../escape, then link/x.txt: the link is created last, so
    # x.txt lands in a real directory, and a link to the outside is
    # refused anyway.
    src = File.join(@dir, "src")
    FileUtils.mkdir_p(src)
    File.symlink("../escape", File.join(src, "link"))
    path = File.join(@dir, "link.zip")
    Ziperu::File.open(path, create: true) do |zf|
      zf.add("link", File.join(src, "link"))
      zf.get_output_stream("link/x.txt") { |o| o.write "through" }
    end
    _out, err = capture_io do
      Ziperu::File.open(path) { |zf| zf.extract_all(@out, symlinks: :create) }
    end
    assert_match(/outside the destination|skipped/, err)
    assert_empty outside, "nothing written beside the destination"
    assert File.file?(File.join(@out, "link", "x.txt"))
    refute File.symlink?(File.join(@out, "link"))
  end

  def test_max_entry_size_is_enforced_on_open
    path = File.join(@dir, "sizes.zip")
    Ziperu::OutputStream.open(path) do |z|
      z.put_next_entry("small.txt")
      z.write("x" * 10)
      z.put_next_entry("big.bin")
      z.write("\0" * 100_000)
    end
    Ziperu.max_entry_size = 50_000
    err = assert_raises(Ziperu::LimitError) { Ziperu::File.open(path) {} }
    assert_match(/declared size of 100000, over the limit of 50000/, err.message)
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(path) {} }
    Ziperu.max_entry_size = 100_000
    Ziperu::File.open(path) { |zf| assert_equal 2, zf.size }
  end

  def test_a_declared_size_smaller_than_the_data_is_not_taken_on_trust
    path = File.join(@dir, "lie.zip")
    Ziperu::OutputStream.open(path) do |z|
      z.put_next_entry("lie.bin", nil, nil, Ziperu::Entry::STORED)
      z.write("A" * 1000)
    end
    bytes = File.binread(path)
    central = bytes.rindex("PK\x01\x02".b)
    bytes[central + 24, 4] = [10].pack("V") # uncompressed size: 10, not 1000
    bytes[central + 20, 4] = [10].pack("V") # compressed size too
    File.binwrite(path, bytes)
    # The declared size bounds the read, and the CRC (of all 1000 bytes)
    # then fails: the entry is reported broken rather than handed over
    # truncated or in full.
    Ziperu::File.open(path) do |zf|
      assert_raises(Ziperu::DecompressionError) { zf.read("lie.bin") }
      assert_raises(Ziperu::Error) { zf.extract_all(@out) }
      refute_empty zf.verify
    end
  end

  def test_duplicate_names_are_listed_but_only_the_last_is_written_back
    path = File.join(@dir, "dup.zip")
    Ziperu::OutputStream.open(path) do |z|
      z.put_next_entry("a.txt")
      z.write("first")
    end
    first = File.binread(path)
    Ziperu::OutputStream.open(path) do |z|
      z.put_next_entry("a.txt")
      z.write("second")
    end
    second = File.binread(path)
    # Splice: both local entries, both central records, one end record.
    a_central = first.rindex("PK\x01\x02".b)
    b_central = second.rindex("PK\x01\x02".b)
    a_local = first.byteslice(0, a_central)
    b_local = second.byteslice(0, b_central)
    a_rec = first.byteslice(a_central, first.rindex("PK\x05\x06".b) - a_central)
    b_rec = second.byteslice(b_central, second.rindex("PK\x05\x06".b) - b_central)
    b_rec = b_rec.dup
    b_rec[42, 4] = [a_local.bytesize].pack("V") # the second entry's local header offset
    eocd = second.byteslice(second.rindex("PK\x05\x06".b)..)
    eocd = eocd.dup
    eocd[8, 2] = [2].pack("v")
    eocd[10, 2] = [2].pack("v")
    eocd[12, 4] = [a_rec.bytesize + b_rec.bytesize].pack("V")
    eocd[16, 4] = [a_local.bytesize + b_local.bytesize].pack("V")
    File.binwrite(path, a_local + b_local + a_rec + b_rec + eocd)
    Ziperu::File.open(path) do |zf|
      assert_equal 2, zf.size
      assert_equal "second", zf.read("a.txt"), "the lookup finds the later record, as rubyzip's does"
      zf.extract_all(@out)
      assert_equal "second", File.read(File.join(@out, "a.txt"))
    end
  end
end
