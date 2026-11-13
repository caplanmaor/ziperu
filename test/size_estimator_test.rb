# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "ziperu/rails_streaming"

# OutputStream.estimated_size against what the stream writer really emits,
# and the Rails streaming helper.
class SizeEstimatorTest < Minitest::Test
  include TestHelper

  class Sink
    attr_reader :bytes

    def initialize
      @bytes = 0
    end

    def write(d)
      @bytes += d.bytesize
    end
  end

  def stream(&block)
    sink = Sink.new
    Ziperu::OutputStream.write_buffer(sink, &block)
    sink.bytes
  end

  def stored(zos, name, data)
    zos.put_next_entry(Ziperu::Entry.new("", name, size: data.bytesize, compression_method: Ziperu::Entry::STORED))
    zos.write(data)
  end

  def test_stored_entries_directories_and_a_comment_to_the_byte
    data = { "a.txt" => "alpha" * 100, "dir/ünï.bin" => Random.new(1).bytes(70_000), "empty" => "" }
    estimate = Ziperu::OutputStream.estimated_size do |e|
      data.each { |n, d| e.add_stored(n, d.bytesize) }
      e.add_directory("dir/")
      e.comment("made by ziperu")
    end
    actual = stream do |zos|
      data.each { |n, d| stored(zos, n, d) }
      zos.put_next_entry("dir/")
      zos.comment = "made by ziperu"
    end
    assert_equal actual, estimate
  end

  def test_deflated_entries_with_a_known_compressed_size
    data = "compress me " * 1000
    # The compressed size from one run is what the estimate needs.
    once = Ziperu::OutputStream.write_buffer do |z|
      z.put_next_entry("d.txt")
      z.write(data)
    end.string
    csize = Ziperu::File.open_buffer(once).get_entry("d.txt").compressed_size
    estimate = Ziperu::OutputStream.estimated_size { |e| e.add_deflated("d.txt", compressed_size: csize, size: data.bytesize) }
    actual = stream do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "d.txt", size: data.bytesize))
      zos.write(data)
    end
    assert_equal actual, estimate
  end

  def test_more_than_65535_entries_need_the_zip64_end_records
    n = 70_000
    estimate = Ziperu::OutputStream.estimated_size { |e| n.times { |i| e.add_stored("f#{i}", 1) } }
    actual = stream { |zos| n.times { |i| stored(zos, "f#{i}", "x") } }
    assert_equal actual, estimate
  end

  def test_a_4_gib_entry_to_the_byte
    size = (1 << 32) + 5
    chunk = "\0" * (1 << 20)
    estimate = Ziperu::OutputStream.estimated_size do |e|
      e.add_stored("big.bin", size)
      e.add_stored("after.txt", 3)
    end
    actual = stream do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "big.bin", size: size, compression_method: Ziperu::Entry::STORED))
      left = size
      while left.positive?
        zos.write(left >= chunk.bytesize ? chunk : chunk.byteslice(0, left))
        left -= chunk.bytesize
      end
      stored(zos, "after.txt", "abc")
    end
    assert_equal actual, estimate
  end

  def test_bytes_written_counts_a_stream
    sink = Sink.new
    seen = []
    Ziperu::OutputStream.write_buffer(sink) do |zos|
      seen << zos.bytes_written
      stored(zos, "a", "x" * 1000)
      zos.put_next_entry("b")
      zos.write("y" * 100_000)
      seen << zos.bytes_written
    end
    assert_equal 0, seen.first
    assert_operator seen.last, :>, 1000
    assert_nil(Ziperu::OutputStream.write_buffer(StringIO.new) { |zos| @w = zos.bytes_written }.then { @w })
  end

  def test_rails_streaming_sets_headers_and_the_body
    controller = Class.new do
      include Ziperu::RailsStreaming

      attr_reader :response, :response_body

      def initialize
        @response = Struct.new(:headers).new({})
      end

      attr_writer :response_body
    end.new
    size = Ziperu::OutputStream.estimated_size { |e| e.add_stored("a.txt", 5) }
    controller.zip_stream("ré port.zip", size: size) { |zos| stored(zos, "a.txt", "hello") }
    h = controller.response.headers
    assert_equal "application/zip", h["content-type"]
    assert_equal size.to_s, h["content-length"]
    assert_equal "no", h["x-accel-buffering"]
    assert_equal %(attachment; filename="r_ port.zip"; filename*=UTF-8''r%C3%A9%20port.zip), h["content-disposition"]
    bytes = controller.response_body.to_a.join
    assert_equal size, bytes.bytesize
    Ziperu::File.open_buffer(bytes) { |zf| assert_equal "hello", zf.read("a.txt") }
    rack = Ziperu::RailsStreaming.headers("x.zip")
    refute rack.key?("content-length")
  end
end
