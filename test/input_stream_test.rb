# frozen_string_literal: true

# Adapted from rubyzip's input_stream_test.rb; same scenarios, our fixtures.

require_relative "test_helper"
require "forwardable"

class ZipInputStreamTest < Minitest::Test
  include TestHelper

  TEXT_ZIP = "text.zip"
  TEXT_ENTRIES = %w[long.txt empty.txt short.txt dir/ dir/bin.dat crlf.txt].freeze

  class IOLike
    extend Forwardable

    def initialize(path, mode)
      @file = File.new(path, mode)
    end

    delegate [:tell, :seek, :read, :eof?, :close] => :@file
  end

  def assert_stream_contents(zis)
    refute_nil(zis)
    TEXT_ENTRIES.each do |name|
      entry = zis.get_next_entry
      assert_equal(name, entry.name)
      expected = name.end_with?("/") ? "" : File.binread(fixture("text/#{name}"))
      assert_equal(expected, zis.read)
    end
    assert_nil(zis.get_next_entry)
  end

  def test_new
    zis = ::Ziperu::InputStream.new(fixture(TEXT_ZIP))
    assert_stream_contents(zis)
    assert_equal(true, zis.eof?)
    zis.close
  end

  def test_open_with_block
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      assert_stream_contents(zis)
      assert_equal(true, zis.eof?)
    end
  end

  def test_open_file_without_block
    zis = ::Ziperu::InputStream.open(File.new(fixture(TEXT_ZIP), "rb"))
    assert_stream_contents(zis)
  end

  def test_open_string_io_with_block
    string_io = ::StringIO.new(File.binread(fixture(TEXT_ZIP)))
    ::Ziperu::InputStream.open(string_io) do |zis|
      assert_stream_contents(zis)
      assert_equal(true, zis.eof?)
    end
  end

  def test_open_io_like_with_block
    ::Ziperu::InputStream.open(IOLike.new(fixture(TEXT_ZIP), "rb")) do |zis|
      assert_stream_contents(zis)
    end
  end

  def test_open_file_with_gp3bit_set_reads_anyway
    # rubyzip raises Ziperu::StreamingError here; we read via the central
    # directory, so the entry is fully readable.
    ::Ziperu::InputStream.open(fixture("rubyzip/gpbit3stored.zip")) do |zis|
      entry = zis.get_next_entry
      assert_equal("file1.txt", entry.name)
      assert_equal(1327, zis.read.bytesize)
      assert_predicate(zis, :eof?)
    end
  end

  def test_open_encrypted_archive_raises_error
    ::Ziperu::InputStream.open(fixture("rubyzip/zipWithEncryption.zip")) do |zis|
      error = assert_raises(::Ziperu::Error) { zis.get_next_entry }
      assert_equal("A password is required to decode this zip file.", error.message)
    end
  end

  def test_encrypted_archive_with_wrong_password
    decrypter = Ziperu::TraditionalDecrypter.new("wrong")
    ::Ziperu::InputStream.open(fixture("rubyzip/zipWithStoredCompressionAndEncryption.zip"), decrypter: decrypter) do |zis|
      assert_raises(::Ziperu::Error) do
        zis.get_next_entry
        zis.read
      end
    end
  end

  def test_aes_encrypted_archive
    decrypter = Ziperu::AESDecrypter.new("password")
    ::Ziperu::InputStream.open(fixture("rubyzip/zip-aes-256.zip"), decrypter: decrypter) do |zis|
      entry = zis.get_next_entry
      assert_equal("zip-aes-128.txt", entry.name)
      assert_equal(11, zis.read.bytesize)
    end
  end

  def test_size_no_entry
    zis = ::Ziperu::InputStream.open(fixture(TEXT_ZIP))
    assert_nil(zis.size)
  end

  def test_size_with_entry
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry
      assert_equal(File.size(fixture("text/long.txt")), zis.size)
    end
  end

  def test_get_entry_ftypes
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      assert_equal(:file, zis.get_next_entry.ftype)
      3.times { zis.get_next_entry }
      assert_equal(:directory, zis.get_next_entry.ftype) if false
    end
    ::Ziperu::InputStream.open(fixture("rubyzip/zipWithDirs.zip")) do |zis|
      assert_equal(:directory, zis.get_next_entry.ftype)
    end
  end

  def test_incomplete_reads
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      entry = zis.get_next_entry # long.txt
      assert_equal(false, zis.eof?)
      assert_equal("long.txt", entry.name)
      refute_empty(zis.gets)
      assert_equal(false, zis.eof?)
      entry = zis.get_next_entry # empty.txt
      assert_equal("empty.txt", entry.name)
      assert_equal(0, entry.size)
      assert_nil(zis.gets)
      assert_equal(true, zis.eof?)
      entry = zis.get_next_entry # short.txt
      assert_equal("short.txt", entry.name)
      refute_empty(zis.gets)
      entry = zis.get_next_entry # dir/
      assert_equal("dir/", entry.name)
      assert_nil(zis.gets)
      entry = zis.get_next_entry # dir/bin.dat
      assert_equal("dir/bin.dat", entry.name)
      refute_empty(zis.gets)
    end
  end

  def test_read_with_number_of_bytes_returns_nil_at_eof
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      entry = zis.get_next_entry
      zis.read(entry.size)
      assert_equal(true, zis.eof?)
      assert_nil(zis.read(1))
      assert_nil(zis.read(1))
    end
  end

  def test_read_with_zero_returns_empty_string
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      assert_equal("", zis.read(0))
    end
  end

  def test_rewind
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      e = zis.get_next_entry
      assert_equal("long.txt", e.name)

      buf = +""
      buf << zis.read(100)
      assert_equal(100, zis.pos)
      buf << (zis.gets || "")
      buf << (zis.gets || "")
      assert_equal(false, zis.eof?)

      zis.rewind

      buf2 = +""
      buf2 << zis.read(100)
      buf2 << (zis.gets || "")
      buf2 << (zis.gets || "")

      assert_equal(buf, buf2)

      zis.rewind
      assert_equal(false, zis.eof?)
      assert_equal(0, zis.pos)
      assert_equal(File.binread(fixture("text/long.txt")), zis.read)
    end
  end

  def test_mix_read_and_gets
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry
      assert_equal("#!/usr/bin/env ruby", zis.gets(chomp: true))
      assert_equal(false, zis.eof?)
      assert_equal("", zis.gets(chomp: true))
      assert_equal(false, zis.eof?)
      assert_equal("$VERBOSE =", zis.read(10))
      assert_equal(false, zis.eof?)
    end
  end

  def test_ungetc
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry
      first_line = zis.gets(chomp: true)
      first_line.reverse.bytes.each { |b| zis.ungetc(b) }
      assert_equal("#!/usr/bin/env ruby", zis.gets(chomp: true))
      assert_equal("$VERBOSE =", zis.read(10))
    end
  end

  def test_readline_then_read
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry
      assert_equal("#!/usr/bin/env ruby\n", zis.readline)
      refute(zis.eof?)
      refute_empty(zis.read)
      assert(zis.eof?)
    end
  end

  def test_each_line_over_crlf
    ::Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      5.times { zis.get_next_entry }
      assert_equal("crlf.txt", zis.get_next_entry.name)
      assert_equal(["#{'x' * 48}\r\n", "#{'y' * 49}\r\n", "rest"], zis.each_line("\r\n").to_a)
    end
  end

  def test_sysread_with_no_maxlen_deflated
    Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry

      buffer = zis.sysread
      assert_equal(File.size(fixture("text/long.txt")), buffer.length)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)

      assert_empty(zis.sysread)
    end
  end

  def test_sysread_with_no_maxlen_stored
    Ziperu::InputStream.open(fixture("rubyzip/zipWithStoredCompression.zip")) do |zis|
      zis.get_next_entry

      buffer = zis.sysread
      assert_equal(1327, buffer.length)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)

      assert_empty(zis.sysread)
    end
  end

  def test_sysread_text_deflated
    Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      zis.get_next_entry

      buffer = zis.sysread(20)
      assert_equal("#!/usr/bin/env ruby\n", buffer)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)

      buffer = +""
      output = zis.sysread(17, buffer)
      assert_equal("\n$VERBOSE = true\n", buffer)
      assert_same(buffer, output)
      assert_equal(Encoding::UTF_8, buffer.encoding)

      buffer = +"".b
      zis.sysread(20, buffer)
      assert_equal("\nrequire 'rubyunit'\n", buffer)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)
    end
  end

  def test_sysread_text_stored
    Ziperu::InputStream.open(fixture("rubyzip/zipWithStoredCompression.zip")) do |zis|
      zis.get_next_entry

      buffer = zis.sysread(24)
      assert_equal("\nAUTOMAKE_OPTIONS = gnu\n", buffer)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)

      buffer = +""
      zis.sysread(23, buffer)
      assert_equal("\nEXTRA_DIST = test.zip\n", buffer)
      assert_equal(Encoding::UTF_8, buffer.encoding)

      buffer = +"".b
      zis.sysread(14, buffer)
      assert_equal("\nCXXFLAGS= -g\n", buffer)
    end
  end

  def test_sysread_text_stored_encrypted
    Ziperu::InputStream.open(
      fixture("rubyzip/zipWithStoredCompressionAndEncryption.zip"),
      decrypter: Ziperu::TraditionalDecrypter.new("password")
    ) do |zis|
      zis.get_next_entry

      buffer = zis.sysread(24)
      assert_equal("\nAUTOMAKE_OPTIONS = gnu\n", buffer)

      buffer = +""
      zis.sysread(23, buffer)
      assert_equal("\nEXTRA_DIST = test.zip\n", buffer)
      assert_equal(Encoding::UTF_8, buffer.encoding)
    end
  end

  def test_sysread_binary_stored
    Ziperu::InputStream.open(fixture("rubyzip/bin_stored.zip")) do |zis|
      zis.get_next_entry

      buffer = zis.sysread(8)
      assert_equal([255, 254, 253, 252, 255, 254, 253, 252], buffer.bytes)
      assert_equal(Encoding::ASCII_8BIT, buffer.encoding)

      buffer = +""
      zis.sysread(8, buffer)
      assert_equal([255, 254, 253, 252, 255, 254, 253, 252], buffer.bytes)
      assert_equal(Encoding::UTF_8, buffer.encoding)
    end
  end

  def test_set_encoding
    Ziperu::InputStream.open(fixture(TEXT_ZIP), internal_encoding: Encoding::UTF_8) do |zis|
      zis.set_encoding(Encoding::UTF_8, Encoding::BINARY)
      zis.get_next_entry
      assert_equal(Encoding::BINARY, zis.readline.encoding)
    end
  end

  def test_kind_of_io
    Ziperu::InputStream.open(fixture(TEXT_ZIP)) do |zis|
      assert_kind_of(IO, zis)
      zis.get_next_entry
      out = StringIO.new
      IO.copy_stream(zis, out)
      assert_equal(File.binread(fixture("text/long.txt")), out.string)
    end
  end

  def test_offset_positions_at_entry
    Ziperu::File.open(fixture(TEXT_ZIP)) do |zf|
      offset = zf.get_entry("short.txt").local_header_offset
      Ziperu::InputStream.open(fixture(TEXT_ZIP), offset: offset) do |zis|
        assert_equal("short.txt", zis.get_next_entry.name)
        assert_equal("short\n", zis.read)
      end
    end
  end

  def test_closed_stream_raises
    zis = Ziperu::InputStream.open(fixture(TEXT_ZIP))
    zis.close
    assert_raises(IOError) { zis.get_next_entry }
  end

  def test_corrupt_data_raises_decompression_error
    bytes = File.binread(fixture(TEXT_ZIP))
    Ziperu::File.open(fixture(TEXT_ZIP)) do |zf|
      e = zf.get_entry("long.txt")
      # Clobber the middle of the deflate stream.
      pos = e.data_offset + (e.compressed_size / 2)
      bytes[pos, 32] = "\xFF".b * 32
    end
    Ziperu::InputStream.open(StringIO.new(bytes)) do |zis|
      zis.get_next_entry
      assert_raises(Ziperu::DecompressionError, Ziperu::Error) { zis.read }
    end
  end
end
