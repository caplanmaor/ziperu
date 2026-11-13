# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# XZ and PPMd on write (bzip2 and zstd have their own tests), and what is
# not writable.
class MoreMethodsTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-methods")
    @path = File.join(@dir, "a.zip")
    @data = ("the quick brown fox " * 5000) + Random.new(3).bytes(20_000)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_xz_and_ppmd_entries_write_and_read_back
    { "xz.bin" => Ziperu::Entry::XZ, "ppmd.bin" => Ziperu::Entry::PPMD }.each do |name, method|
      Ziperu::OutputStream.open(@path) do |z|
        z.put_next_entry(name, nil, nil, method)
        z.write(@data)
        z.put_next_entry("best.bin", nil, nil, method, Zlib::BEST_COMPRESSION)
        z.write(@data)
      end
      Ziperu::File.open(@path) do |zf|
        e = zf.get_entry(name)
        assert_equal method, e.compression_method
        assert_operator e.compressed_size, :<, @data.bytesize / 2
        assert_equal @data, zf.read(name)
        assert_equal @data, zf.read("best.bin")
        assert_empty zf.verify
      end
      Ziperu::InputStream.open(@path) do |is|
        is.get_next_entry
        assert_equal @data, is.read
      end
    end
  end

  def test_through_file_add_and_a_rewrite
    Ziperu::File.open(@path, create: true) do |zf|
      e = zf.add("x.bin", StringIO.new(@data))
      e.compression_method = Ziperu::Entry::XZ
    end
    Ziperu::File.open(@path) { |zf| zf.get_entry("x.bin").comment = "edited" } # restreamed
    Ziperu::File.open(@path) do |zf|
      assert_equal Ziperu::Entry::XZ, zf.get_entry("x.bin").compression_method
      assert_equal @data, zf.read("x.bin")
    end
  end

  def test_lzma_is_read_but_not_written
    refute_includes Ziperu::WRITABLE_COMPRESSION_METHODS, Ziperu::COMPRESSION_METHOD_LZMA
    assert_includes Ziperu::READABLE_COMPRESSION_METHODS, Ziperu::COMPRESSION_METHOD_LZMA
    assert_raises(Ziperu::CompressionMethodError) do
      Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("l.bin", nil, nil, Ziperu::COMPRESSION_METHOD_LZMA) }
    end
  end
end
