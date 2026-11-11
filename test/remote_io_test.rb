# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "support/range_server"

# Ziperu::RemoteIO: an archive read over HTTP Range requests, a little at
# a time.
class RemoteIOTest < Minitest::Test
  def setup
    @files = (1..40).to_h { |i| ["dir/file#{i}.bin", Random.new(i).bytes(100_000)] }
    buf = Ziperu::OutputStream.write_buffer do |zos|
      @files.each do |name, data|
        zos.put_next_entry(Ziperu::Entry.new("", name, compression_method: Ziperu::Entry::STORED))
        zos << data
      end
    end
    @zip = buf.string
    @server = RangeServer.new(@zip)
  end

  def teardown
    @server.stop
  end

  def test_listing_and_one_entry_read_little_of_the_archive
    io = Ziperu::RemoteIO.new(@server.url)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files.keys, zf.entries.map(&:name)
      assert_equal @files["dir/file17.bin"], zf.read("dir/file17.bin")
    end
    assert_operator @server.bytes_sent, :<, 600_000, "a few blocks of a 4 MB archive"
    assert_operator io.requests, :<=, 4
  end

  def test_every_entry_and_verify
    io = Ziperu::RemoteIO.new(@server.url, block_size: 64 * 1024, cache_blocks: 4)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      @files.each { |name, data| assert_equal data, zf.read(name) }
      assert_empty zf.verify
    end
  end

  def test_extract_all_and_input_stream
    io = Ziperu::RemoteIO.new(@server.url)
    Dir.mktmpdir do |dest|
      Ziperu::File.open_buffer(io, write: false) { |zf| zf.extract_all(dest) }
      assert_equal @files["dir/file40.bin"], File.binread(File.join(dest, "dir/file40.bin"))
    end
    io.rewind
    Ziperu::InputStream.open(io) do |is|
      assert_equal "dir/file1.bin", is.get_next_entry.name
      assert_equal @files["dir/file1.bin"], is.read
    end
  end

  def test_redirect_is_followed
    io = Ziperu::RemoteIO.new(@server.url("/moved"))
    assert_equal @zip.bytesize, io.size
    io.seek(100)
    assert_equal @zip.byteslice(100, 1000), io.read(1000)
  end

  def test_io_behaviour
    io = Ziperu::RemoteIO.new(@server.url, block_size: 1000)
    assert_equal 0, io.pos
    assert_equal @zip.byteslice(0, 2500), io.read(2500)
    assert_equal 2500, io.tell
    io.seek(-10, IO::SEEK_END)
    assert_equal @zip.byteslice(-10, 10), io.read
    assert io.eof?
    assert_nil io.read(1)
    assert_equal "", io.read
    io.seek(-5, IO::SEEK_CUR)
    assert_equal @zip.byteslice(-5, 5), io.read(100)
    io.close
    assert_raises(IOError) { io.read(1) }
  end

  def test_a_server_without_ranges_gives_the_whole_file_once
    plain = RangeServer.new(@zip, ranges: false)
    io = Ziperu::RemoteIO.new(plain.url)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files["dir/file3.bin"], zf.read("dir/file3.bin")
    end
    assert_equal 1, plain.hits
  ensure
    plain&.stop
  end

  def test_a_block_as_the_source
    calls = []
    io = Ziperu::RemoteIO.new(size: @zip.bytesize) do |offset, length|
      calls << [offset, length]
      @zip.byteslice(offset, length)
    end
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files["dir/file9.bin"], zf.read("dir/file9.bin")
    end
    refute_empty calls
  end

  def test_a_short_answer_raises
    io = Ziperu::RemoteIO.new(size: 1000) { |_offset, _length| "x" }
    assert_raises(Ziperu::RemoteIO::Error) { io.read(10) }
  end

  def test_bad_arguments
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new }
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new(@server.url) { "" } }
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new(size: 1, block_size: 0) { "" } }
  end
end
