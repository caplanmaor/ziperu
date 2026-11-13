# frozen_string_literal: true

# Streams behave as Ruby IOs do: reads at the edges, closed streams,
# directories, paths given as Pathnames, archives written to an IO.
# Each test pins down a bug found in a review or testing round.

require_relative "test_helper"
require_relative "support/archive_scratch"
require "tmpdir"
require "timeout"
require "delegate"

class IOSemanticsTest < Minitest::Test
  include TestHelper
  include ArchiveScratch

  def test_a_zero_length_read_reads_nothing
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("x")
      z.write("hello world")
    end
    Ziperu::InputStream.open(@path) do |is|
      is.get_next_entry
      assert_equal "hello", is.read(5)
      assert_equal "", is.sysread(0)
      assert_equal "", is.read(0)
      refute is.eof?
      assert_equal " world", is.read
    end
  end

  def test_closed_input_stream_behaves_like_a_closed_io
    zis = Ziperu::InputStream.new(sample_zip)
    zis.get_next_entry
    zis.close
    refute_predicate zis, :eof?
    assert_raises(IOError) { zis.read }
    assert_raises(IOError) { zis.gets }
    assert_raises(IOError) { zis.rewind }
    assert_raises(IOError) { zis.get_next_entry }
  end

  def test_negative_read_length_is_an_argument_error
    Ziperu::InputStream.open(sample_zip) do |zis|
      zis.get_next_entry
      assert_raises(ArgumentError) { zis.read(-1) }
    end
  end

  def test_nothing_to_read_after_the_last_entry
    Ziperu::InputStream.open(sample_zip) do |zis|
      nil while zis.get_next_entry
      assert_equal "", zis.read
    end
  end

  def test_reading_a_directory_entry_gives_an_empty_string
    Ziperu::File.open(sample_zip) do |zf|
      assert_equal "", zf.read("dir/")
      assert_equal "", zf.get_entry("dir/").get_input_stream(&:read)
    end
  end

  # The buffer for each step of a streamed read was sized (and zeroed) by
  # what the caller asked for, so a large `read(n)` did that work over and
  # over; what comes back is the same either way.
  def test_a_streamed_read_with_a_huge_length_returns_the_entry
    data = Random.new(1).bytes(300_000)
    Ziperu::OutputStream.open(two_entry_zip) do |zos|
      zos.put_next_entry("big.bin")
      zos.write(data)
    end

    File.open(two_entry_zip, "rb") do |file|
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

  def test_a_pathname_is_a_path
    src = File.join(@dir, "src.txt")
    File.write(src, "from a pathname")
    Ziperu::File.open(@path, create: true) do |zf|
      zf.add("p.txt", Pathname(src))
      zf.add_stored("s.txt", Pathname(src))
    end
    Ziperu::File.open(@path) do |zf|
      zf.replace("p.txt", Pathname(src))
      assert_equal "from a pathname", zf.read("s.txt")
    end
    Ziperu::File.open(@path) { |zf| assert_equal "from a pathname", zf.read("p.txt") }
  end

  def test_an_output_stream_over_an_io_writes_the_archive_on_close
    io = StringIO.new
    zos = Ziperu::OutputStream.new(io, stream: true)
    zos.put_next_entry("a.txt")
    zos.write("x")
    zos.close
    assert_predicate io, :closed?
    Ziperu::File.open_buffer(io.string) { |zf| assert_equal "x", zf.read("a.txt") }
  end
end
