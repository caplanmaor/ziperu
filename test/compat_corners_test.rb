# frozen_string_literal: true

# Behaviour rubyzip's suite pinned down that is easy to regress: DOS time
# clamping, zip64 placeholders, count_entries on lying archives, reading
# after close, split archives and password error classes.

require_relative "test_helper"
require "tmpdir"

class CompatCornersTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "work.zip")
    FileUtils.cp(fixture("text.zip"), @zip)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    Ziperu.reset!
  end

  def test_dos_time_clamps_and_compares_at_two_seconds
    assert_equal 0x0021, Ziperu::DOSTime.local(1970, 6, 15, 12, 30, 30).to_binary_dos_date
    assert_equal 0xff9f, Ziperu::DOSTime.local(2200, 1, 1).to_binary_dos_date
    assert_equal Ziperu::DOSTime.local(2024, 1, 1, 0, 0, 1), Ziperu::DOSTime.local(2024, 1, 1, 0, 0, 0)
    refute_predicate Ziperu::DOSTime.parse_binary_dos_format(0x0021, 0), :absolute_time?
    assert_predicate Ziperu::DOSTime.now, :absolute_time?
  end

  def test_compression_level_sets_gp_flag_bits
    assert_equal 0b110, (Ziperu::Entry.new("", "a", compression_level: 1).gp_flags & 0b110)
    assert_equal 0b010, (Ziperu::Entry.new("", "a", compression_level: 9).gp_flags & 0b110)
    assert_equal 0, (Ziperu::Entry.new("", "a", compression_level:  1,
                                                compression_method: Ziperu::Entry::STORED).gp_flags & 0b110)
  end

  def test_zip64_extra_only_when_size_is_unknown
    path = File.join(@tmp, "z64.zip")
    src = File.join(@tmp, "src.txt")
    File.binwrite(src, "known size\n")
    Ziperu::File.open(path, create: true) do |zf|
      zf.add("known.txt", src)
      zf.get_output_stream("streamed.txt") { |os| os.write "unknown size up front" }
      zf.mkdir("dir")
    end
    Ziperu::File.open(path) do |zf|
      refute_predicate zf.get_entry("known.txt"), :zip64?
      assert_predicate zf.get_entry("streamed.txt"), :zip64?
      refute_predicate zf.get_entry("dir/"), :zip64?
      assert_equal "unknown size up front", zf.read("streamed.txt")
    end
  end

  def test_stored_entry_ignores_compression_level
    path = File.join(@tmp, "stored.zip")
    Ziperu::File.open(path, create: true) do |zf|
      zf.get_output_stream("s.txt", compression_method: Ziperu::Entry::STORED,
                                    compression_level:  Zlib::BEST_SPEED) { |os| os.write "x" * 100 }
    end
    Ziperu::File.open(path) do |zf|
      entry = zf.get_entry("s.txt")
      assert_equal Ziperu::Entry::STORED, entry.compression_method
      assert_equal 100, entry.compressed_size
    end
  end

  def test_count_entries_tolerates_impossible_entry_counts
    %w[zipWithTooBigCDirSizeField.zip zipWithTooBigCDirSizeField64.zip].each do |name|
      assert_output("", /Zip consistency problem:/) do
        assert_kind_of Integer, Ziperu::File.count_entries(fixture("rubyzip/#{name}"))
      end
      Ziperu.validate_declared_number_of_entries = true
      assert_raises(Ziperu::EntryNumberMismatchError) { Ziperu::File.count_entries(fixture("rubyzip/#{name}")) }
      Ziperu.validate_declared_number_of_entries = false
    end
    assert_equal 6, Ziperu::File.count_entries(@zip)
    assert_equal 6, File.open(@zip, "rb") { |io| Ziperu::File.count_entries(io) }
  end

  def test_entries_stay_readable_after_close
    zf = Ziperu::File.new(@zip)
    zf.rename("short.txt", "renamed.txt")
    zf.close
    assert_equal "short\n", zf.read("renamed.txt")
    assert_equal File.binread(fixture("text/long.txt")), zf.get_entry("long.txt").get_input_stream(&:read)
    # The file is not held open between reads, so it can be replaced.
    File.delete(@zip)
  end

  def test_split_round_trip
    big = File.join(@tmp, "big.zip")
    Ziperu::File.open(big, create: true) do |zf|
      zf.get_output_stream("random.bin") { |os| os.write Random.new(1).bytes(200_000) }
    end
    segments = Ziperu::File.split(big, segment_size: 65_536, delete_original: false)
    assert_equal 4, segments
    first = "#{big}.001"
    assert_raises(Ziperu::SplitArchiveError) { Ziperu::InputStream.open(first, &:get_next_entry) }

    joined = File.join(@tmp, "joined.zip")
    File.open(joined, "wb") do |out|
      (1..segments).each do |i|
        data = File.binread("#{big}.#{format("%03d", i)}")
        data = data.byteslice(4..) if i == 1 # split signature
        out.write(data)
      end
    end
    Ziperu::File.open(joined) { |zf| assert_equal Random.new(1).bytes(200_000), zf.read("random.bin") }
  end

  def test_wrong_password_error_classes_match_rubyzip
    error = assert_raises(Ziperu::DecompressionError) do
      Ziperu::InputStream.open(fixture("rubyzip/zipWithStoredCompressionAndEncryption.zip"),
                               decrypter: Ziperu::TraditionalDecrypter.new("wrong")) do |zis|
        zis.get_next_entry
        zis.read
      end
    end
    assert_match(/invalid password/, error.message)

    error = assert_raises(Ziperu::Error) do
      Ziperu::InputStream.open(fixture("rubyzip/zip-aes-256.zip"),
                               decrypter: Ziperu::AESDecrypter.new("wrong")) do |zis|
        zis.get_next_entry
        zis.read
      end
    end
    assert_equal "Bad password", error.message
  end

  def test_invalid_dos_date_warns_when_asked
    meta = { index: 0, name: "x", size: 0, compressed_size: 0, crc: 0, compression_method: 0,
             flags: 0, fstype: 0, version_made_by: 20, external_attributes: 0, unix_mode: nil,
             dos_date: 0, dos_time: 0, comment: "", extra: "", header_offset: 0, data_offset: 0 }
    # The timestamp is parsed when first asked for, except that with the
    # warning on it is parsed up front, so the warning comes on open.
    Ziperu.warn_invalid_date = true
    assert_output("", /invalid date/) { Ziperu::Entry.from_meta(nil, meta) }
    Ziperu.warn_invalid_date = false
    assert_silent { Ziperu::Entry.from_meta(nil, meta).time }
  end
end
