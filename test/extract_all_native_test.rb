# frozen_string_literal: true

# File#extract_all's native path: every qualifying entry in one native call,
# with the same outcome as Entry#extract would give one entry at a time.

require_relative "test_helper"
require "tmpdir"

class ExtractAllNativeTest < Minitest::Test
  include TestHelper

  # Counts native calls, to tell the two paths apart.
  module Spy
    class << self
      attr_accessor :calls
    end
    self.calls = 0 # other test files extract too

    def extract_entries(*args)
      Spy.calls += 1
      super
    end
  end
  Ziperu::Native::Archive.prepend(Spy)

  TRAVERSAL = File.join(DATA_DIR, "rubyzip", "path_traversal")

  def setup
    @tmp = Dir.mktmpdir("ziperu-native")
    @dest = File.join(@tmp, "out")
    Spy.calls = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    Ziperu.reset!
  end

  def out(*parts)
    File.join(@dest, *parts)
  end

  def test_extracts_everything_in_one_native_call
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }

    assert_equal 1, Spy.calls
    assert_equal File.binread(fixture("text/long.txt")), File.binread(out("long.txt"))
    assert_equal "short\n", File.binread(out("short.txt"))
    assert_equal "", File.binread(out("empty.txt"))
    assert File.directory?(out("dir"))
    assert_equal File.binread(fixture("text/dir/bin.dat")), File.binread(out("dir", "bin.dat"))
  end

  def test_creates_missing_intermediate_directories
    Ziperu::File.open(fixture("nodirs.zip")) { |zf| zf.extract_all(@dest) }

    assert_equal 1, Spy.calls
    assert_equal "deep content", File.read(out("a", "b", "c", "deep.txt"))
  end

  def test_restores_times
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }
    assert_equal Time.local(2024, 3, 15, 12, 30, 0), File.mtime(out("short.txt"))
  end

  def test_restore_times_off
    before = Time.now - 5
    Ziperu::File.open(fixture("text.zip"), restore_times: false) { |zf| zf.extract_all(@dest) }

    assert_equal 1, Spy.calls
    assert_operator File.mtime(out("short.txt")), :>=, before
  end

  def test_restores_unix_permissions
    skip "Unix permissions" if Ziperu::RUNNING_ON_WINDOWS

    src = File.join(@tmp, "perms.zip")
    Ziperu::File.open(src, create: true) do |zf|
      zf.get_output_stream("run.sh", permissions: 0o755) { |os| os.write("#!/bin/sh\n") }
      zf.get_output_stream("ro.txt", permissions: 0o444) { |os| os.write("x") }
      zf.mkdir("d", 0o700)
    end

    Ziperu::File.open(src) { |zf| zf.extract_all(@dest) }
    assert_equal 1, Spy.calls
    assert_equal 0o755, File.stat(out("run.sh")).mode & 0o777
    assert_equal 0o444, File.stat(out("ro.txt")).mode & 0o777
    assert_equal 0o700, File.stat(out("d")).mode & 0o777

    FileUtils.rm_rf(@dest)
    Ziperu::File.open(src, restore_permissions: false) { |zf| zf.extract_all(@dest) }
    assert_equal 0, File.stat(out("run.sh")).mode & 0o111
  end

  def test_existing_file_raises
    FileUtils.mkdir_p(@dest)
    File.write(out("short.txt"), "pre-existing")

    error = assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }
    end

    assert_equal 1, Spy.calls
    assert_match(/short\.txt/, error.message)
    assert_equal "pre-existing", File.read(out("short.txt"))
  end

  def test_existing_directory_in_place_of_file_raises
    FileUtils.mkdir_p(out("short.txt"))

    assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }
    end
    assert File.directory?(out("short.txt"))
  end

  def test_existing_directory_is_reused
    FileUtils.mkdir_p(out("dir"))
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }
    assert_equal 1, Spy.calls
    assert File.exist?(out("dir", "bin.dat"))
  end

  def test_leading_dot_dot_is_refused
    assert_output("", %r{WARNING: skipped extracting '\.\./moo' to '.*/moo' as unsafe\.}) do
      Ziperu::File.open(File.join(TRAVERSAL, "jwilk", "relative0.zip")) { |zf| zf.extract_all(@dest) }
    end

    assert_equal 1, Spy.calls
    refute File.exist?(File.join(@tmp, "moo"))
    refute File.exist?(out("moo"))
  end

  def test_non_leading_dot_dot_is_refused
    assert_output("", %r{WARNING: skipped extracting 'tmp/\.\./\.\./moo'}) do
      Ziperu::File.open(File.join(TRAVERSAL, "relative1.zip")) { |zf| zf.extract_all(@dest) }
    end

    assert_equal 1, Spy.calls
    assert File.directory?(out("tmp"))
    refute File.exist?(File.join(@tmp, "moo"))
  end

  def test_breakout_of_destination_is_refused
    assert_output("", %r{WARNING: skipped extracting '\.\./out_evil/}) do
      Ziperu::File.open(File.join(TRAVERSAL, "out_evil.zip")) { |zf| zf.extract_all(@dest) }
    end

    assert_equal 1, Spy.calls
    refute File.exist?(File.join(@tmp, "out_evil", "breakout.txt"))
  end

  def test_absolute_name_lands_inside_destination
    Ziperu::File.open(File.join(TRAVERSAL, "jwilk", "absolute1.zip")) { |zf| zf.extract_all(@dest) }

    assert_equal 1, Spy.calls
    assert File.exist?(out("tmp", "moo"))
    refute File.exist?("/tmp/moo")
  end

  def test_symlink_is_skipped_with_the_usual_warning
    assert_output("", /WARNING: skipped symlink 'tmp' during extract_all\./) do
      Ziperu::File.open(File.join(TRAVERSAL, "jwilk", "dirsymlink.zip")) { |zf| zf.extract_all(@dest) }
    end

    assert_equal 1, Spy.calls
    refute File.symlink?(out("tmp"))
    assert File.exist?(out("tmp", "moo"))
  end

  def test_block_takes_the_ruby_path
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) { true } }
    assert_equal 0, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_on_exists_proc_overwrites_on_the_native_path
    Ziperu.on_exists_proc = true
    FileUtils.mkdir_p(@dest)
    File.write(out("short.txt"), "in the way")
    Ziperu::File.open(fixture("text.zip")) { |zf| zf.extract_all(@dest) }
    assert_equal 1, Spy.calls, "the global overwrite policy is passed to the native core"
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_restore_ownership_takes_the_ruby_path
    Ziperu::File.open(fixture("text.zip"), restore_ownership: true) { |zf| zf.extract_all(@dest) }
    assert_equal 0, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_encrypted_entries_take_the_ruby_path
    assert_raises(Ziperu::Error) do
      Ziperu::File.open(fixture("rubyzip/zipWithEncryption.zip")) { |zf| zf.extract_all(@dest) }
    end
    assert_equal 0, Spy.calls
  end

  def test_memory_source
    Ziperu::File.open_buffer(File.binread(fixture("text.zip"))) { |zf| zf.extract_all(@dest) }
    assert_equal 1, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_io_source
    File.open(fixture("text.zip"), "rb") do |io|
      Ziperu::File.open_buffer(io) { |zf| zf.extract_all(@dest) }
    end
    assert_equal 1, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_after_close
    zf = Ziperu::File.new(fixture("text.zip"))
    zf.close
    zf.extract_all(@dest)
    assert_equal 1, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end

  def test_batches_large_archives
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      300.times do |i|
        zos.put_next_entry("d#{i % 7}/f#{i}.txt")
        zos.write("entry #{i}")
      end
    end

    Ziperu::File.open_buffer(buffer.string) { |zf| zf.extract_all(@dest) }
    assert_equal 2, Spy.calls
    assert_equal "entry 299", File.read(out("d5", "f299.txt"))
    assert_equal 300, Dir.glob(File.join(@dest, "*", "*.txt")).size
  end

  # A header that understates the size raises with validation on, as the
  # per-entry path does, and warns with it off.
  def test_understated_size
    fake_zip = File.join(@tmp, "fake.zip")
    name = "short.txt"
    data = File.binread(fixture("text.zip"))
    compressed_size = Ziperu::File.open(fixture("text.zip")) { |zf| zf.get_entry(name).compressed_size }
    true_bytes = [compressed_size, 6, name.size].pack("VVv")
    fake_bytes = [compressed_size, 1, name.size].pack("VVv")
    File.binwrite(fake_zip, data.gsub(true_bytes, fake_bytes))

    error = assert_raises(Ziperu::EntrySizeError) do
      Ziperu::File.open(fake_zip) { |zf| zf.extract_all(@dest) }
    end
    assert_equal "Entry 'short.txt' should be 1B, but is larger when inflated.", error.message
    assert_equal 1, Spy.calls

    FileUtils.rm_rf(@dest)
    Ziperu.validate_entry_sizes = false
    assert_output("", /Entry 'short\.txt' should be 1B/) do
      Ziperu::File.open(fake_zip) { |zf| zf.extract_all(@dest) }
    end
    assert_equal 2, Spy.calls
    assert_equal "short\n", File.binread(out("short.txt"))
  end
end
