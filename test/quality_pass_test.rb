# frozen_string_literal: true

# Bugs found while reading the code through, each pinned down here.

require_relative "test_helper"
require "tmpdir"

class QualityPassTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "a.zip")
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("a.txt")
      zos.write("first")
      zos.put_next_entry("b.txt")
      zos.write("second")
    end
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # Taking back "the last entry" with none added took back one the archive
  # already had, and the central directory was written over its header.
  def test_an_append_that_fails_before_adding_anything_leaves_the_archive_alone
    before = File.binread(@zip)
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(@zip, append: true) { raise "boom" }
    end

    assert_equal before, File.binread(@zip)
    Ziperu::File.open(@zip) { |zf| assert_equal "second", zf.read("b.txt") }
  end

  def test_an_append_that_fails_after_adding_an_entry_leaves_the_archive_alone
    before = File.binread(@zip)
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(@zip, append: true) do |zos|
        zos.put_next_entry("c.txt")
        zos.write("third")
        raise "boom"
      end
    end

    assert_equal before, File.binread(@zip)
  end

  # The buffer for each step of a streamed read was sized (and zeroed) by
  # what the caller asked for, so a large `read(n)` did that work over and
  # over; what comes back is the same either way.
  def test_a_streamed_read_with_a_huge_length_returns_the_entry
    data = Random.new(1).bytes(300_000)
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("big.bin")
      zos.write(data)
    end

    File.open(@zip, "rb") do |file|
      reader, writer = IO.pipe
      reader.binmode
      writer.binmode
      feeder = Thread.new do
        IO.copy_stream(file, writer)
        writer.close
      end
      Ziperu::InputStream.open(reader) do |zis|
        zis.get_next_entry
        assert_equal data, zis.read(1 << 40)
      end
      feeder.join
      reader.close
    end
  end

  # A read that spanned the oldest cached block and one not yet cached
  # dropped the first to make room for the second.
  def test_remote_io_keeps_the_block_it_is_about_to_read
    data = (0...120).map { |i| (i % 251).chr }.join.b
    io = Ziperu::RemoteIO.new(size: data.bytesize, block_size: 10, cache_blocks: 2) do |offset, length|
      data.byteslice(offset, length)
    end
    io.seek(50)
    io.read(5)
    io.seek(90)
    io.read(5)
    io.seek(55)

    assert_equal data.byteslice(55, 10), io.read(10)
  end

  # rubyzip's compressor classes are kept for code that names them; they
  # pass their output through the encrypter.
  def test_the_rubyzip_compressors_work_with_the_null_encrypter
    out = +"".b
    stored = Ziperu::PassThruCompressor.new(out)
    stored << "abc"

    assert_equal "abc", out
    assert_equal 3, stored.size

    out = +"".b
    deflater = Ziperu::Deflater.new(out)
    deflater << "hello hello hello"
    deflater.finish

    assert_equal "hello hello hello", Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(out)
  end

  def test_time_setter_takes_a_component_named_with_or_without_the_equals_sign
    entry = Ziperu::Entry.new("a.zip", "a.txt")
    stamp = Time.at(1_700_000_000)
    entry.send(:time=, stamp, component: :atime)
    entry.send(:time=, stamp, component: :atime=)

    assert_equal stamp.to_i, entry.atime.to_i
  end
end
