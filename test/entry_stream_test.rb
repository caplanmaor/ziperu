# frozen_string_literal: true

require_relative "test_helper"

# Zip::File#get_input_stream and Entry#get_input_stream hand out
# Zip::InputStream objects positioned at the entry.
class EntryStreamTest < Minitest::Test
  include TestHelper

  def test_file_get_input_stream_by_name
    Zip::File.open(fixture("text.zip")) do |zf|
      zf.get_input_stream("short.txt") do |is|
        assert_kind_of(Zip::InputStream, is)
        assert_equal("short\n", is.read)
      end
    end
  end

  def test_entry_get_input_stream_without_block
    Zip::File.open(fixture("text.zip")) do |zf|
      is = zf.get_entry("long.txt").get_input_stream
      assert_equal("#!/usr/bin/env ruby\n", is.gets)
      assert_equal(1, is.lineno)
      is.close
    end
  end

  def test_directory_entry_gives_null_stream
    Zip::File.open(fixture("text.zip")) do |zf|
      is = zf.get_input_stream("dir/")
      assert_predicate(is, :eof?)
      assert_equal("", is.read)
      assert_nil(is.read(1))
      assert_nil(is.gets)
    end
  end

  def test_streams_are_independent
    Zip::File.open(fixture("text.zip")) do |zf|
      a = zf.get_input_stream("long.txt")
      b = zf.get_input_stream("dir/bin.dat")
      a_first = a.read(10)
      b_first = b.read(10)
      assert_equal(File.binread(fixture("text/long.txt"))[0, 10], a_first)
      assert_equal(File.binread(fixture("text/dir/bin.dat"))[0, 10], b_first)
      assert_equal(File.binread(fixture("text/long.txt"))[10..], a.read)
      assert_equal(File.binread(fixture("text/dir/bin.dat"))[10..], b.read)
    end
  end

  def test_stream_outlives_zip_file
    is = Zip::File.open(fixture("text.zip")) { |zf| zf.get_input_stream("short.txt") }
    GC.start
    assert_equal("short\n", is.read)
  end

  def test_open_buffer_from_io
    File.open(fixture("text.zip"), "rb") do |f|
      zf = Zip::File.open_buffer(f)
      assert_equal("short\n", zf.read("short.txt"))
    end
  end
end
