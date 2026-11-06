# frozen_string_literal: true

# Archives opened from a Ruby IO are read through it lazily, from any
# seekable object; a pipe falls back to taking the whole stream.

require_relative "test_helper"
require "delegate"
require "tempfile"

class IoSourceTest < Minitest::Test
  include TestHelper

  # Counts what the native core actually pulls through a Ruby IO.
  class CountingIO < SimpleDelegator
    attr_reader :bytes_read

    def initialize(io)
      super
      @bytes_read = 0
    end

    def read(*args)
      chunk = __getobj__.read(*args)
      @bytes_read += chunk.bytesize if chunk
      chunk
    end
  end

  # Reads normally until armed, then raises from inside the native core.
  class ExplodingIO < SimpleDelegator
    attr_accessor :armed

    def read(*args)
      raise "boom from the io" if armed

      __getobj__.read(*args)
    end
  end

  BIG = Random.new(7).bytes(2_000_000)

  def big_archive
    @big_archive ||= Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("big.bin", nil, nil, Ziperu::Entry::STORED)
      zos.write(BIG)
      zos.put_next_entry("small.txt")
      zos.write("small\n")
    end.string
  end

  def test_reads_only_what_it_needs
    io = CountingIO.new(StringIO.new(big_archive))
    Ziperu::File.open_buffer(io) do |zf|
      assert_equal "small\n", zf.read("small.txt")
    end
    assert_operator io.bytes_read, :<, 300_000, "the 2 MB entry should not have been read"
  end

  def test_any_seekable_object_works
    Tempfile.create(["ziperu", ".zip"]) do |tf|
      tf.binmode
      tf.write(big_archive)
      tf.flush
      Ziperu::File.open_buffer(tf) do |zf|
        assert_equal BIG, zf.read("big.bin")
        assert_equal "small\n", zf.get_entry("small.txt").get_input_stream(&:read)
      end
    end
  end

  def test_entries_from_the_same_io_read_independently
    Ziperu::InputStream.open(StringIO.new(big_archive)) do |zis|
      big = zis.get_next_entry
      assert_equal "big.bin", big.name
      first = zis.read(1000)
      small = zis.get_next_entry
      assert_equal "small\n", zis.read
      assert_equal "small.txt", small.name
      assert_equal BIG.byteslice(0, 1000), first
    end
  end

  def test_pipe_falls_back_to_taking_the_whole_stream
    rd, wr = IO.pipe
    writer = Thread.new do
      wr.binmode
      wr.write(File.binread(fixture("text.zip")))
      wr.close
    end
    names = []
    Ziperu::InputStream.open(rd) do |zis|
      while (entry = zis.get_next_entry)
        names << entry.name
        assert_equal "short\n", zis.read if entry.name == "short.txt"
      end
    end
    writer.join
    assert_includes names, "short.txt"
  ensure
    rd&.close
  end

  def test_io_exceptions_propagate_unchanged
    io = ExplodingIO.new(StringIO.new(File.binread(fixture("text.zip"))))
    Ziperu::File.open_buffer(io) do |zf|
      io.armed = true
      error = assert_raises(RuntimeError) { zf.read("long.txt") }
      assert_equal "boom from the io", error.message
      io.armed = false
      assert_equal "short\n", zf.read("short.txt")
    end
  end

  def test_lazy_source_survives_writing_back_to_the_same_buffer
    io = StringIO.new(big_archive.dup)
    Ziperu::File.open_buffer(io) do |zf|
      zf.get_output_stream("added.txt") { |os| os.write "added" }
      zf.remove("small.txt")
    end
    Ziperu::File.open_buffer(io) do |zf|
      assert_equal %w[added.txt big.bin], zf.entries.map(&:name).sort
      assert_equal "added", zf.read("added.txt")
      assert_equal BIG, zf.read("big.bin")
    end
  end

  def test_io_stays_alive_while_a_reader_uses_it
    zis = Ziperu::InputStream.new(StringIO.new(big_archive))
    zis.get_next_entry
    GC.start
    assert_equal BIG.byteslice(0, 65_536), zis.read(65_536)
    zis.close
  end
end
