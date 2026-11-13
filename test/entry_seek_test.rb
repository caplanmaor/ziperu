# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# InputStream#seek in a Stored entry: random access without reading
# everything before the byte wanted (rubyzip #569).
class EntrySeekTest < Minitest::Test
  DATA = Random.new(7).bytes(300_000)

  def setup
    @dir = Dir.mktmpdir("ziperu-seek")
    @path = File.join(@dir, "a.zip")
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("first.txt")
      zos << "first"
      zos.put_next_entry(Ziperu::Entry.new("", "stored.bin", compression_method: Ziperu::Entry::STORED))
      zos << DATA
      zos.put_next_entry("deflated.txt")
      zos << ("d" * 10_000)
    end
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_seek_in_a_stored_entry
    sources.each do |label, open|
      open.call do |zf|
        zf.get_input_stream("stored.bin") do |is|
          assert_equal 0, is.seek(250_000)
          assert_equal DATA.byteslice(250_000, 10), is.read(10), label
          assert_equal 250_010, is.pos
          is.seek(-10, IO::SEEK_END)
          assert_equal DATA.byteslice(-10, 10), is.read, label
          assert is.eof?
          is.seek(-100, IO::SEEK_CUR)
          assert_equal DATA.byteslice(-100, 50), is.read(50), label
          is.pos = 3
          assert_equal DATA.byteslice(3, 4), is.read(4)
          is.seek(1_000_000)
          assert_nil is.read(1)
          is.rewind
          assert_equal DATA, is.read, "#{label}: rewind goes back to the checked read"
        end
      end
    end
  end

  def test_gets_after_a_seek
    path = File.join(@dir, "lines.zip")
    Ziperu::OutputStream.open(path) do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "l.txt", compression_method: Ziperu::Entry::STORED))
      zos << "one\ntwo\nthree\n"
    end
    Ziperu::File.open(path) do |zf|
      zf.get_input_stream("l.txt") do |is|
        is.gets
        is.seek(8)
        assert_equal "three\n", is.gets
      end
    end
  end

  def test_a_compressed_entry_cannot_be_seeked_in
    Ziperu::File.open(@path) do |zf|
      zf.get_input_stream("deflated.txt") do |is|
        assert_raises(Ziperu::Error) { is.seek(10) }
        assert_equal "d" * 10_000, is.read, "the stream is still usable"
      end
    end
  end

  def test_bad_arguments
    Ziperu::File.open(@path) do |zf|
      zf.get_input_stream("stored.bin") do |is|
        assert_raises(Errno::EINVAL) { is.seek(-1) }
        assert_raises(ArgumentError) { is.seek(0, 42) }
      end
    end
  end

  private

  def sources
    {
      "file"   => ->(&b) { Ziperu::File.open(@path, &b) },
      "buffer" => ->(&b) { Ziperu::File.open_buffer(File.binread(@path), &b) },
      "io"     => ->(&b) { File.open(@path, "rb") { |io| Ziperu::File.open_buffer(io, &b) } }
    }
  end
end
