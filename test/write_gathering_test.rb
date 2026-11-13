# frozen_string_literal: true

require_relative "test_helper"

# Small writes are gathered before they reach the native writer; what the
# archive holds is the same as writing each straight away.
class WriteGatheringTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ziperu-gather")
    @zip = File.join(@dir, "t.zip")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def pieces(seed)
    r = Random.new(seed)
    Array.new(3000) { r.bytes([1, 7, 100, 4000, 16_383, 16_384, 70_000].sample(random: r)) }
  end

  def test_mixed_sizes_keep_their_order
    data = { "a" => pieces(1), "b" => pieces(2) }
    Ziperu::OutputStream.open(@zip) do |zos|
      data.each do |name, parts|
        zos.put_next_entry(name)
        parts.each { |part| zos << part }
      end
      zos.put_next_entry("dir/", nil, nil, Ziperu::Entry::STORED)
    end
    Ziperu::File.open(@zip) do |zf|
      data.each { |name, parts| assert_equal parts.join, zf.read(name) }
      assert_empty zf.verify
    end
  end

  def test_rollback_drops_the_gathered_bytes
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("kept")
      zos << "keep"
      zos.put_next_entry("dropped")
      zos << ("gone" * 10)
      zos.rollback_entry
      zos.put_next_entry("after")
      zos << "after"
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal %w[kept after], zf.entries.map(&:name)
      assert_equal "keep", zf.read("kept")
      assert_equal "after", zf.read("after")
    end
  end

  def test_small_writes_then_a_raw_copy
    src = File.join(@dir, "src.zip")
    Ziperu::OutputStream.open(src) do |zos|
      zos.put_next_entry("raw")
      zos << "raw data"
    end
    Ziperu::File.open(src) do |zf|
      Ziperu::OutputStream.open(@zip) do |zos|
        zos.put_next_entry("small")
        zos << "s" << "m" << "a" << "l" << "l"
        zos.copy_raw_entry(zf.get_entry("raw"))
      end
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal "small", zf.read("small")
      assert_equal "raw data", zf.read("raw")
    end
  end

  def test_a_stream_gets_everything
    out = +"".b
    io = Object.new
    io.define_singleton_method(:write) do |chunk|
      out << chunk
      chunk.bytesize
    end
    zos = Ziperu::OutputStream.new(io, stream: true)
    zos.put_next_entry("lines.txt")
    1000.times { |i| zos.puts "line #{i}" }
    zos.close_buffer
    Ziperu::File.open_buffer(out) do |zf|
      assert_equal Array.new(1000) { |i| "line #{i}\n" }.join, zf.read("lines.txt")
    end
  end

  def test_text_in_any_encoding
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("t")
      zos << "héllo " << "wörld".encode("UTF-16LE").b << " ☃"
      zos.print "ünïcode", 7
    end
    expected = "héllo ".b + "wörld".encode("UTF-16LE").b + " ☃".b + "ünïcode7".b
    Ziperu::File.open(@zip) { |zf| assert_equal expected, zf.read("t") }
  end
end
