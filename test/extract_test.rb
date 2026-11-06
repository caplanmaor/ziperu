# frozen_string_literal: true

# Scenarios from rubyzip's file_extract_test, file_extract_directory_test and
# file_extract_all_test, against our fixtures.

require_relative "test_helper"
require "tmpdir"

class ExtractTest < Minitest::Test
  include TestHelper

  # Like rubyzip, extract joins entry_path onto destination_directory, so an
  # absolute entry_path (with a drive letter, on Windows) is not meaningful;
  # work with relative paths inside a temp dir.
  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @orig_dir = Dir.pwd
    Dir.chdir(@tmp)
    @out = "extEntry"
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.rm_rf(@tmp)
    Ziperu.reset!
  end

  def long_txt
    File.binread(fixture("text/long.txt"))
  end

  def test_extract_via_file_and_entry
    Ziperu::File.open(fixture("text.zip")) do |zf|
      zf.extract("long.txt", @out)
      assert_equal long_txt, File.binread(@out)
      File.unlink(@out)

      entry = zf.get_entry("long.txt")
      entry.extract(@out)
      assert_equal long_txt, File.binread(@out)
    end
  end

  def test_extract_exists
    File.write(@out, "written text")

    assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("short.txt", @out) }
    end
    assert_equal "written text", File.read(@out)
  end

  def test_extract_exists_overwrite_via_block
    File.write(@out, "written text")

    called_correctly = false
    Ziperu::File.open(fixture("text.zip")) do |zf|
      zf.extract("short.txt", @out) do |entry, extract_loc|
        called_correctly = zf.get_entry("short.txt") == entry && extract_loc == File.absolute_path(@out)
        true
      end
    end

    assert called_correctly
    assert_equal "short\n", File.binread(@out)
  end

  def test_extract_exists_overwrite_via_setting
    File.write(@out, "written text")
    Ziperu.on_exists_proc = true
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("short.txt", @out) }
    assert_equal "short\n", File.binread(@out)
  end

  def test_extract_non_entry
    Ziperu::File.open(fixture("text.zip")) do |zf|
      assert_raises(Errno::ENOENT) { zf.extract("nonExistingEntry", @out) }
    end
    refute File.exist?(@out)
  end

  def test_extract_directory
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("dir/", @out) }
    assert File.directory?(@out)
  end

  def test_extract_directory_exists_as_dir
    Dir.mkdir(@out)
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("dir/", @out) }
    assert File.directory?(@out)
  end

  def test_extract_directory_exists_as_file
    File.write(@out, "something")
    assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("dir/", @out) }
    end
  end

  def test_extract_directory_exists_as_file_overwrite
    File.write(@out, "something")
    called = false
    Ziperu::File.open(fixture("text.zip")) do |zf|
      zf.extract("dir/", @out) do |entry, dest_path|
        called = true
        assert_equal File.absolute_path(@out), dest_path
        assert_predicate entry, :directory?
        true
      end
    end
    assert called
    assert File.directory?(@out)
  end

  def test_extract_restores_mtime
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract("short.txt", @out) }
    assert_equal Time.local(2024, 3, 15, 12, 30, 0), File.mtime(@out)
  end

  def test_extract_all
    dest = File.join(@tmp, "all")
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(dest) }

    assert_equal long_txt, File.binread(File.join(dest, "long.txt"))
    assert_equal "", File.binread(File.join(dest, "empty.txt"))
    assert File.directory?(File.join(dest, "dir"))
    assert_equal File.binread(fixture("text/dir/bin.dat")), File.binread(File.join(dest, "dir", "bin.dat"))
  end

  def test_extract_all_class_method
    dest = File.join(@tmp, "all")
    Ziperu::File.extract_all(fixture("text.zip"), dest)
    assert_equal "short\n", File.binread(File.join(dest, "short.txt"))
  end

  def test_extract_all_creates_missing_intermediate_directories
    dest = File.join(@tmp, "all")
    Ziperu::File.open(fixture("nodirs.zip")) { |zf| zf.extract_all(dest) }
    assert_equal "deep content", File.read(File.join(dest, "a", "b", "c", "deep.txt"))
  end

  def test_extract_all_skips_symlinks
    dest = File.join(@tmp, "all")
    assert_output("", /WARNING: skipped symlink '.*tmp'/) do
      Ziperu::File.open(fixture("rubyzip/path_traversal/jwilk/dirsymlink.zip")) { |zf| zf.extract_all(dest) }
    end

    refute File.symlink?(File.join(dest, "tmp"))
    assert File.directory?(File.join(dest, "tmp"))
    assert File.exist?(File.join(dest, "tmp", "moo"))
  end

  def test_extract_all_exists_raises_by_default
    dest = File.join(@tmp, "all")
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "short.txt"), "pre-existing")

    assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(dest) }
    end
  end

  def test_extract_all_exists_overwrite_via_block
    dest = File.join(@tmp, "all")
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "short.txt"), "pre-existing")

    called = false
    Ziperu::File.open(fixture("text.zip")) do |zf|
      zf.extract_all(dest) do
        called = true
        true
      end
    end

    assert called
    assert_equal "short\n", File.binread(File.join(dest, "short.txt"))
  end

  # The uncompressed size fields in the zip file cannot be trusted; a header
  # that understates the size must not let a zip bomb through unnoticed.
  def test_extract_incorrect_size
    fake_zip = File.join(@tmp, "fake.zip")
    name = "short.txt"
    true_size = 6
    fake_size = 1

    data = File.binread(fixture("text.zip"))
    compressed_size = Ziperu::File.open(fixture("text.zip")) { |zf| zf.get_entry(name).compressed_size }
    true_bytes = [compressed_size, true_size, name.size].pack("VVv")
    fake_bytes = [compressed_size, fake_size, name.size].pack("VVv")
    assert_equal 2, data.scan(true_bytes).size, "size fields in local header and central directory"
    File.binwrite(fake_zip, data.gsub(true_bytes, fake_bytes))

    Ziperu::File.open(fake_zip) do |zf|
      entry = zf.find_entry(name)
      assert_equal fake_size, entry.size

      Ziperu.validate_entry_sizes = false
      assert_output("", /.+'short\.txt'.+1B.+/) { entry.extract }
      assert_equal true_size, File.size(name)
      FileUtils.rm name

      Ziperu.validate_entry_sizes = true
      error = assert_raises(Ziperu::EntrySizeError) { entry.extract }
      assert_equal "Entry 'short.txt' should be 1B, but is larger when inflated.", error.message
      # Also through the stream API, which rubyzip leaves unchecked.
      assert_raises(Ziperu::EntrySizeError) { zf.read(name) }
      assert_raises(Ziperu::EntrySizeError) { entry.get_input_stream(&:read) }
    end
  end
end
