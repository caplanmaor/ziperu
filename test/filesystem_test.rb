# frozen_string_literal: true

# Smoke test for the Zip::FileSystem mixin (rubyzip's own filesystem tests
# run against it via `rake compat`).

require_relative "test_helper"
require "zip/filesystem"
require "tmpdir"

class FileSystemTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "fs.zip")
    FileUtils.cp(fixture("text.zip"), @zip)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_file_api
    Zip::File.open(@zip) do |zf|
      assert zf.file.exist?("short.txt")
      assert zf.file.file?("short.txt")
      assert zf.file.directory?("dir")
      refute zf.file.exist?("nope")
      assert_equal 6, zf.file.size("short.txt")
      assert_equal "short\n", zf.file.read("short.txt")
      assert_equal Time.local(2024, 3, 15, 12, 30, 0), zf.file.mtime("short.txt")
      assert_equal "short\n", zf.file.open("short.txt", &:read)
      assert_predicate zf.file.stat("short.txt"), :file?
    end
  end

  def test_dir_api
    Zip::File.open(@zip) do |zf|
      assert_equal %w[crlf.txt dir empty.txt long.txt short.txt], zf.dir.entries(".").sort
      assert_equal %w[bin.dat], zf.dir.entries("dir")
      assert_equal %w[crlf.txt empty.txt long.txt short.txt], zf.dir.glob("*.txt").map(&:name).sort
    end
  end

  def test_mutation_through_file_api
    Zip::File.open(@zip) do |zf|
      zf.file.open("written.txt", "w") { |f| f.puts "via file api" }
      zf.dir.mkdir("made")
      zf.file.rename("short.txt", "renamed.txt")
      zf.file.delete("empty.txt")
    end
    Zip::File.open(@zip) do |zf|
      assert_equal "via file api\n", zf.file.read("written.txt")
      assert zf.file.directory?("made")
      assert_equal "short\n", zf.file.read("renamed.txt")
      refute zf.file.exist?("empty.txt")
      assert_equal File.binread(fixture("text/long.txt")), zf.file.read("long.txt")
    end
  end

  # Like rubyzip, unix permissions only exist on entries whose "made by"
  # system is Unix; text.zip was written on Windows, so use a Unix fixture.
  def test_chmod_persists_through_raw_copy
    zip = File.join(@tmp, "unix.zip")
    FileUtils.cp(fixture("rubyzip/zipWithDirs.zip"), zip)
    before = Zip::File.open(zip) { |zf| zf.get_entry("dir1/file11").compressed_size }

    Zip::File.open(zip) { |zf| zf.file.chmod(0o600, "dir1/file11") }

    Zip::File.open(zip) do |zf|
      entry = zf.get_entry("dir1/file11")
      assert_equal 0o600, zf.file.stat("dir1/file11").mode & 0o777
      assert_equal before, entry.compressed_size, "entry was copied, not recompressed"
    end
  end

  def test_local_extra_fields_merge_lazily
    # ntfs.zip and oddExtraField.zip carry timestamps/uid in local headers.
    Zip::File.open(fixture("rubyzip/ntfs.zip")) do |zf|
      entry = zf.first
      assert_predicate entry, :absolute_time?
      refute_nil entry.atime
    end
  end
end
