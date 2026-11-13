# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# InputStream with `streaming: true`: a pipe read in one pass, local
# header by local header.
class StreamingReadTest < Minitest::Test
  FILES = {
    "a.txt"     => "hello " * 1000,
    "dir/b.bin" => Random.new(3).bytes(200_000),
    "empty.txt" => "",
    "c.txt"     => "the end"
  }.freeze

  def setup
    @dir = Dir.mktmpdir("ziperu-stream-read")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # `bytes` on the read end of a pipe, written from a thread.
  def piped(bytes)
    r, w = IO.pipe
    w.binmode
    writer = Thread.new do
      w.write(bytes)
    rescue IOError, SystemCallError
      nil
    ensure
      w.close
    end
    yield r
  ensure
    r&.close
    writer&.join
  end

  def read_all(bytes, **opts)
    found = {}
    piped(bytes) do |r|
      Ziperu::InputStream.open(r, streaming: true, **opts) do |is|
        while (entry = is.get_next_entry)
          data = is.read
          found[entry.name] = [data, entry.size, entry.crc]
        end
      end
    end
    found
  end

  def streamed_archive
    Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("dir/")
      FILES.each do |name, data|
        zos.put_next_entry(name)
        zos << data
      end
    end.to_a.join
  end

  def test_an_archive_written_as_a_stream
    found = read_all(streamed_archive)
    assert_equal ["dir/", *FILES.keys], found.keys
    FILES.each do |name, data|
      got, size, crc = found[name]
      assert_equal data, got.to_s, name
      assert_equal data.bytesize, size, "#{name}: the size, learned from the descriptor"
      assert_equal Zlib.crc32(data), crc, name
    end
  end

  def test_an_archive_with_sizes_in_its_headers
    path = File.join(@dir, "a.zip")
    Ziperu::OutputStream.open(path) do |zos|
      FILES.each do |name, data|
        zos.put_next_entry(name, nil, nil, Ziperu::Entry::STORED)
        zos << data
      end
      zos.put_next_entry("bz.txt", nil, nil, Ziperu::Entry::BZIP2)
      zos << ("bzip " * 500)
      zos.put_next_entry("def.txt")
      zos << ("deflated " * 500)
    end
    found = read_all(File.binread(path))
    FILES.each { |name, data| assert_equal data, found[name][0].to_s, name }
    assert_equal "bzip " * 500, found["bz.txt"][0]
    assert_equal "deflated " * 500, found["def.txt"][0]
  end

  def test_entries_can_be_skipped_and_read_in_pieces
    piped(streamed_archive) do |r|
      Ziperu::InputStream.open(r, streaming: true) do |is|
        is.get_next_entry # dir/
        is.get_next_entry # a.txt, skipped
        assert_equal "dir/b.bin", is.get_next_entry.name
        assert_equal FILES["dir/b.bin"].byteslice(0, 10), is.read(10)
        assert_equal FILES["dir/b.bin"].byteslice(10, 70_000), is.read(70_000)
        assert_equal "empty.txt", is.get_next_entry.name
        assert_equal "", is.read
        assert_equal "c.txt", is.get_next_entry.name
        assert_equal "the", is.read(3)
        assert_raises(Ziperu::Error) { is.rewind }
        assert_nil is.get_next_entry
      end
    end
  end

  def test_a_stored_entry_with_its_sizes_after_the_data_cannot_be_streamed
    bytes = Ziperu::OutputStream.body do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "s.bin", compression_method: Ziperu::Entry::STORED))
      zos << "stored"
    end.to_a.join
    piped(bytes) do |r|
      Ziperu::InputStream.open(r, streaming: true) do |is|
        assert_raises(Ziperu::Error) { is.get_next_entry }
      end
    end
  end

  def test_limits_count_what_comes
    bomb = Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("zeros")
      8.times { zos << ("\0" * 1_000_000) }
    end.to_a.join
    assert_raises(Ziperu::LimitError) { read_all(bomb, max_entry_size: 1_000_000) }
    assert_raises(Ziperu::LimitError) { read_all(bomb, max_total_size: 2_000_000) }
    assert_raises(Ziperu::LimitError) { read_all(streamed_archive, max_entries: 2) }
    assert_equal 1, read_all(bomb, max_entry_size: 10_000_000).size
  end

  def test_corrupt_data_is_caught
    bytes = streamed_archive.b
    at = bytes.index("hello".b) || (bytes.index("PK\x03\x04".b, 40) + 60)
    bytes[at + 20, 4] = "XXXX"
    assert_raises(Ziperu::Error) { read_all(bytes) }
  end

  def test_without_streaming_a_pipe_is_read_whole_as_before
    found = {}
    piped(streamed_archive) do |r|
      Ziperu::InputStream.open(r) do |is|
        while (entry = is.get_next_entry)
          found[entry.name] = is.read
        end
      end
    end
    assert_equal FILES["dir/b.bin"], found["dir/b.bin"]
  end

  def test_a_file_ignores_streaming
    path = File.join(@dir, "f.zip")
    File.binwrite(path, streamed_archive)
    Ziperu::InputStream.open(path, streaming: true) do |is|
      assert_equal "dir/", is.get_next_entry.name
      assert_equal "a.txt", is.get_next_entry.name
      is.rewind
      assert_equal FILES["a.txt"], is.read
    end
  end
end
