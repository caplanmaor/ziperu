# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "minitest/mock"

# A write that fails part-way leaves what was there before as it was: an
# overwrite during extraction, a commit to `write: path`, and the Windows
# replace fallback.
class SafeFailureTest < Minitest::Test
  PAYLOAD = "ENTRY-PAYLOAD-THAT-WILL-BE-CORRUPTED" * 100

  def setup
    @root = Dir.mktmpdir
    @dest = File.join(@root, "dest")
    Dir.mkdir(@dest)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_a_failed_overwrite_keeps_the_original_file
    zip = corrupt_archive
    %i[native ruby].each do |path|
      File.write(File.join(@dest, "a.txt"), "original")
      assert_raises(StandardError, path.to_s) do
        Ziperu::File.open(zip) do |zf|
          if path == :native
            zf.extract_all(@dest, on_exists: :overwrite)
          else
            zf.extract_all(@dest) { true }
          end
        end
      end
      assert_equal "original", File.read(File.join(@dest, "a.txt")), "#{path}: the original survives"
      assert_equal ["a.txt"], Dir.children(@dest), "#{path}: no staging file is left"
    end
  end

  def test_an_overwrite_that_succeeds_replaces_the_file
    zip = File.join(@root, "ok.zip")
    Ziperu::OutputStream.open(zip) do |zos|
      zos.put_next_entry("a.txt")
      zos.write("new")
    end
    %i[native ruby].each do |path|
      File.write(File.join(@dest, "a.txt"), "original, and longer than the new data")
      Ziperu::File.open(zip) do |zf|
        path == :native ? zf.extract_all(@dest, on_exists: :overwrite) : zf.extract_all(@dest) { true }
      end
      assert_equal "new", File.read(File.join(@dest, "a.txt")), path.to_s
      assert_equal ["a.txt"], Dir.children(@dest)
    end
  end

  def test_a_failed_commit_to_write_path_keeps_what_was_there
    src = File.join(@root, "src.zip")
    Ziperu::OutputStream.open(src) do |zos|
      zos.put_next_entry("x.txt")
      zos.write("x")
    end
    out = File.join(@root, "out.zip")
    File.write(out, "keep me")
    gone = File.join(@root, "gone.txt")
    File.write(gone, "soon deleted")
    assert_raises(SystemCallError) do
      Ziperu::File.open(src, write: out) do |zf|
        zf.add("gone.txt", gone)
        File.delete(gone)
      end
    end
    assert_equal "keep me", File.read(out)
    assert_equal %w[out.zip src.zip], Dir.children(@root).reject { |f| f == "dest" }.sort
  end

  def test_a_commit_to_write_path_replaces_what_was_there
    src = File.join(@root, "src.zip")
    Ziperu::OutputStream.open(src) do |zos|
      zos.put_next_entry("x.txt")
      zos.write("x")
    end
    out = File.join(@root, "out.zip")
    File.write(out, "old")
    Ziperu::File.open(src, write: out) { |zf| zf.get_output_stream("y.txt") { |os| os << "y" } }
    Ziperu::File.open(out) { |zf| assert_equal %w[x.txt y.txt], zf.entries.map(&:name).sort }
  end

  def test_the_windows_fallback_puts_the_original_back_when_the_rename_fails
    skip "the fallback is for Windows" unless Ziperu::RUNNING_ON_WINDOWS

    archive = File.join(@root, "a.zip")
    File.write(archive, "original")
    staged = File.join(@root, "new.zip")
    File.write(staged, "new")
    zf = Ziperu::File.allocate
    zf.instance_variable_set(:@name, archive)
    real_rename = File.method(:rename)
    calls = 0
    flaky = lambda do |from, to|
      calls += 1
      # The two plain attempts and the rename of the new archive into
      # place fail; moving the original aside and back works.
      raise Errno::EACCES, to if from == staged

      real_rename.call(from, to)
    end
    File.stub(:rename, flaky) do
      assert_raises(Errno::EACCES) { zf.send(:rename_over_original, staged) }
    end
    assert_equal "original", File.read(archive)
    assert_operator calls, :>=, 4
    assert_equal %w[a.zip new.zip], Dir.children(@root).reject { |f| f == "dest" }.sort
  end

  private

  # One stored entry whose data no longer matches its CRC.
  def corrupt_archive
    zip = File.join(@root, "bad.zip")
    Ziperu::OutputStream.open(zip) do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "a.txt", compression_method: Ziperu::Entry::STORED))
      zos.write(PAYLOAD)
    end
    bytes = File.binread(zip)
    at = bytes.index(PAYLOAD)
    bytes.setbyte(at + PAYLOAD.bytesize - 1, "!".ord)
    File.binwrite(zip, bytes)
    zip
  end
end
