# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# The compression-ratio limit, and the zip64 switches on write.
class LimitsZip64Test < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-limits")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    Ziperu.max_compression_ratio = nil
    Ziperu.write_zip64_support = true
    FileUtils.rm_rf(@dir)
  end

  def test_max_compression_ratio_is_enforced_on_open
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("text.txt")
      z.write("some ordinary text " * 10) # compresses a few times over
      z.put_next_entry("zeros.bin")
      z.write("\0" * 1_000_000) # about 1000:1
    end
    ratio = Ziperu::File.open(@path) do |zf|
      e = zf.get_entry("zeros.bin")
      e.size.to_f / e.compressed_size
    end
    assert_operator ratio, :>, 100

    Ziperu.max_compression_ratio = 100
    err = assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path) {} }
    assert_match(/compression ratio of \d+\.\d, over the limit of 100/, err.message)
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(@path) {} }

    Ziperu.max_compression_ratio = ratio.ceil + 1
    Ziperu::File.open(@path) { |zf| assert_equal 2, zf.size }
  end

  def test_an_entry_declaring_data_but_no_compressed_bytes_is_an_infinite_ratio
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a.txt")
      z.write("a" * 100)
    end
    bytes = File.binread(@path)
    # Zero the compressed size in the central directory record.
    at = bytes.rindex("PK\x01\x02".b)
    bytes[at + 20, 4] = [0].pack("V")
    Ziperu.max_compression_ratio = 1_000_000
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(bytes) {} }
  end

  def test_zip64_per_entry_and_always
    zip64_extra = ->(path, name) do
      bytes = File.binread(path)
      Ziperu::File.open(path) do |zf|
        e = zf.get_entry(name)
        hdr = bytes.byteslice(e.local_header_offset, 30).unpack("VvvvvvVVVvv")
        extra = bytes.byteslice(e.local_header_offset + 30 + hdr[9], hdr[10])
        [hdr[1], extra.include?("\x01\x00".b)]
      end
    end
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("forced.txt", zip64: true)
      z.write("a")
      z.put_next_entry("plain.txt", nil, nil, Ziperu::Entry::DEFLATED, nil, zip64: false)
      z.write("b")
      z.put_next_entry(Ziperu::Entry.new("", "known.txt", size: 1, zip64: true))
      z.write("c")
    end
    assert_equal [45, true], zip64_extra.call(@path, "forced.txt")
    assert_equal [20, false], zip64_extra.call(@path, "plain.txt"), "zip64: false, though the size is unknown"
    assert_equal [45, true], zip64_extra.call(@path, "known.txt"), "zip64: true, though the size is known"
    Ziperu::File.open(@path) { |zf| assert_equal %w[a b c], %w[forced.txt plain.txt known.txt].map { |n| zf.read(n) } }

    Ziperu::File.open(@path, create: true) do |zf|
      zf.get_output_stream("via_file.txt", zip64: true) { |o| o.write "d" }
    end
    assert_equal [45, true], zip64_extra.call(@path, "via_file.txt")

    Ziperu.write_zip64_support = :always
    Ziperu::File.open(@path, create: true) { |zf| zf.add("k.txt", StringIO.new("k")); zf.mkdir("d") }
    assert_equal [45, true], zip64_extra.call(@path, "k.txt"), ":always, though the size is known"
    Ziperu::File.open(@path) { |zf| assert_empty zf.verify }
  end

  def test_zip64_is_written_for_unknown_sizes_unless_turned_off
    zip64_extra = ->(path, name) do
      bytes = File.binread(path)
      Ziperu::File.open(path) do |zf|
        e = zf.get_entry(name)
        hdr = bytes.byteslice(e.local_header_offset, 30).unpack("VvvvvvVVVvv")
        extra = bytes.byteslice(e.local_header_offset + 30 + hdr[9], hdr[10])
        [hdr[1], extra.include?("\x01\x00".b)]
      end
    end
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a.txt"); z.write("a") }
    assert_equal [45, true], zip64_extra.call(@path, "a.txt"), "unknown size: zip64-ready, version 4.5"

    Ziperu::OutputStream.open(@path, suppress_extra_fields: :zip64) { |z| z.put_next_entry("a.txt"); z.write("a") }
    assert_equal [20, false], zip64_extra.call(@path, "a.txt")

    Ziperu.write_zip64_support = false
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a.txt"); z.write("a") }
    assert_equal [20, false], zip64_extra.call(@path, "a.txt")

    # A size given up front needs no zip64 placeholder.
    Ziperu.write_zip64_support = true
    Ziperu::File.open(@path, create: true) { |zf| zf.add("k.txt", StringIO.new("k")) }
    assert_equal [20, false], zip64_extra.call(@path, "k.txt")
  end
end
