# frozen_string_literal: true

require_relative "test_helper"

class ZipFileTest < Minitest::Test
  include TestHelper

  def test_open_counts_entries
    Zip::File.open(fixture("basic.zip")) do |zf|
      assert_equal 4, zf.size
      assert_equal %w[dir/ dir/nested.txt empty.txt hello.txt], zf.map(&:name).sort
    end
  end

  def test_entry_metadata
    Zip::File.open(fixture("basic.zip")) do |zf|
      e = zf.get_entry("hello.txt")
      assert_equal 14, e.size
      assert_equal Zip::COMPRESSION_METHOD_DEFLATE, e.compression_method
      assert_predicate e, :file?
      assert_equal 2024, e.time.year
      assert_predicate zf.get_entry("dir/"), :directory?
    end
  end

  def test_read_entry
    Zip::File.open(fixture("basic.zip")) do |zf|
      assert_equal "hello, world!\n", zf.read("hello.txt")
      assert_equal "", zf.read("empty.txt")
      assert_equal "nested\n", zf.get_input_stream("dir/nested.txt", &:read)
    end
  end

  def test_open_buffer
    zf = Zip::File.open_buffer(File.binread(fixture("basic.zip")))
    assert_equal "hello, world!\n", zf.read("hello.txt")
  end

  def test_missing_file_raises_enoent
    assert_raises(Errno::ENOENT) { Zip::File.open(fixture("nope.zip")) }
  end

  def test_garbage_raises_zip_error
    assert_raises(Zip::Error) { Zip::File.open_buffer("not a zip at all") }
  end

  def test_missing_entry_raises_enoent
    Zip::File.open(fixture("basic.zip")) do |zf|
      assert_raises(Errno::ENOENT) { zf.read("missing") }
    end
  end
end
