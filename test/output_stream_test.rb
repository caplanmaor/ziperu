# frozen_string_literal: true

# Adapted from rubyzip's output_stream_test.rb.

require_relative "test_helper"
require "tmpdir"
require "tempfile"

class ZipOutputStreamTest < Minitest::Test
  include TestHelper

  ENTRIES = %w[long.txt empty.txt short.txt dir/bin.dat crlf.txt].freeze
  COMMENT = "my zip comment"

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "output.zip")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    Ziperu.reset!
  end

  def write_test_zip(zos)
    ENTRIES.each do |name|
      zos.put_next_entry(name)
      zos.write(File.binread(fixture("text/#{name}")))
    end
  end

  def assert_test_zip_contents(path_or_io)
    Ziperu::InputStream.open(path_or_io) do |zis|
      ENTRIES.each do |name|
        entry = zis.get_next_entry
        assert_equal(name, entry.name)
        assert_equal(File.binread(fixture("text/#{name}")), zis.read)
      end
      assert_nil(zis.get_next_entry)
    end
  end

  def test_new
    zos = Ziperu::OutputStream.new(@zip)
    assert_equal(Encoding::ASCII_8BIT, zos.external_encoding)
    assert_nil(zos.internal_encoding)

    zos.comment = COMMENT
    write_test_zip(zos)
    zos.close
    assert_test_zip_contents(@zip)
    Ziperu::File.open(@zip) { |zf| assert_equal(COMMENT, zf.comment) }
  end

  def test_open
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.comment = COMMENT
      write_test_zip(zos)
    end
    assert_test_zip_contents(@zip)
  end

  def test_open_without_block_forwards_options
    encrypter = Ziperu::AESEncrypter.new("password")
    zos = Ziperu::OutputStream.open(@zip, encrypter: encrypter, suppress_extra_fields: true)

    assert_same encrypter, zos.instance_variable_get(:@encrypter)
    assert_equal true, zos.instance_variable_get(:@suppress_extra_fields)
  ensure
    zos&.close
  end

  def test_write_buffer
    buffer = Ziperu::OutputStream.write_buffer(StringIO.new) do |zos|
      assert_equal(Encoding::ASCII_8BIT, zos.external_encoding)
      zos.comment = COMMENT
      write_test_zip(zos)
    end
    assert_equal Encoding::ASCII_8BIT, buffer.external_encoding
    File.binwrite(@zip, buffer.string)
    assert_test_zip_contents(@zip)
  end

  def test_write_buffer_with_temp_file
    tmp_file = Tempfile.new("")
    Ziperu::OutputStream.write_buffer(tmp_file) do |zos|
      zos.comment = COMMENT
      write_test_zip(zos)
    end
    tmp_file.rewind
    File.binwrite(@zip, tmp_file.read)
    tmp_file.close!
    assert_test_zip_contents(@zip)
  end

  def test_write_buffer_with_open_file
    File.open(@zip, "wb") do |f|
      Ziperu::OutputStream.write_buffer(f) do |zos|
        zos.comment = COMMENT
        write_test_zip(zos)
      end
    end
    assert_test_zip_contents(@zip)
  end

  def test_write_buffer_with_default_io
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      write_test_zip(zos)
    end
    assert_kind_of StringIO, buffer
    assert_test_zip_contents(buffer)
  end

  def test_writing_to_closed_stream
    assert_io_error_in_closed_stream { |zos| zos << "hello world" }
    assert_io_error_in_closed_stream { |zos| zos.puts "hello world" }
    assert_io_error_in_closed_stream { |zos| zos.write "hello world" }
  end

  def test_writing_before_an_entry_is_opened
    Ziperu::OutputStream.open(@zip) do |zos|
      assert_raises(IOError) { zos << "no entry yet" }
    end
  end

  def test_cannot_open_file
    assert_raises(SystemCallError) { Ziperu::OutputStream.open(@tmp) }
  end

  def test_put_next_entry_stored
    stored_text = "hello world in stored text"
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("file1", "my comment", nil, Ziperu::Entry::STORED)
      zos << stored_text
    end

    assert(File.binread(@zip)[stored_text])
    Ziperu::File.open(@zip) do |zf|
      entry = zf.get_entry("file1")
      assert_equal(stored_text, zf.read("file1"))
      assert_equal(Ziperu::Entry::STORED, entry.compression_method)
      assert_equal("my comment", entry.comment)
    end
  end

  def test_put_next_entry_using_zip_entry_creates_entries_with_correct_timestamps
    path = fixture("text/short.txt")
    mtime = File.mtime(path)
    Ziperu::OutputStream.open(@zip) do |zos|
      zip_entry = Ziperu::Entry.new(zos, "short.txt", time: Ziperu::DOSTime.at(mtime))
      zos.put_next_entry(zip_entry)
      zos << File.binread(path)
    end

    Ziperu::InputStream.open(@zip) do |io|
      entry = io.get_next_entry
      assert_equal(Ziperu::DOSTime.at(mtime), Ziperu::DOSTime.at(entry.mtime))
    end
  end

  def test_chained_put_into_next_entry
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("file1", "", nil, Ziperu::Entry::STORED)
      zos << "hello world in stored text" << "with chain"
    end
    Ziperu::File.open(@zip) { |zf| assert_equal("hello world in stored textwith chain", zf.read("file1")) }
  end

  def test_print_deflated
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("print_test")
      assert_nil(zos.print("hello,", " world"))
    end
    Ziperu::InputStream.open(buffer) do |zis|
      assert_equal("print_test", zis.get_next_entry.name)
      assert_equal("hello, world", zis.read)
    end
  end

  def test_printf_deflated
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("printf_test")
      assert_nil(zos.printf("hello, %s", "world"))
    end
    Ziperu::InputStream.open(buffer) do |zis|
      zis.get_next_entry
      assert_equal("hello, world", zis.read)
    end
  end

  def test_write_deflated
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("write_test")
      assert_equal(12, zos.write("hello, world"))
    end
    Ziperu::InputStream.open(buffer) do |zis|
      entry = zis.get_next_entry
      assert_equal(Ziperu::Entry::DEFLATED, entry.compression_method)
      assert_equal("hello, world", zis.read)
    end
  end

  def test_directory_entry
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("adir/")
      zos.put_next_entry("adir/file.txt")
      zos.write("x")
    end
    Ziperu::File.open_buffer(buffer) do |zf|
      assert_predicate zf.get_entry("adir/"), :directory?
      assert_equal "x", zf.read("adir/file.txt")
    end
  end

  def test_zip64_default_usage
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("write_test")
      zos.write "hello, world!"
    end
    Ziperu::InputStream.open(buffer) do |zis|
      entry = zis.get_next_entry
      assert(entry.zip64?)
      assert_equal("hello, world!", zis.read)
    end
  end

  def test_zip64_off
    Ziperu.write_zip64_support = false
    buffer = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("write_test")
      zos.write "hello, world!"
    end
    Ziperu::InputStream.open(buffer) do |zis|
      refute(zis.get_next_entry.zip64?)
    end
  end

  def test_zip64_and_ut_suppressed
    buffer = Ziperu::OutputStream.write_buffer(suppress_extra_fields: true) do |zos|
      entry = Ziperu::Entry.new(nil, "write_test")
      entry.atime = Time.now
      zos.put_next_entry(entry)
      zos.write "hello, world!"
    end
    Ziperu::InputStream.open(buffer) do |zis|
      entry = zis.get_next_entry
      refute(entry.zip64?)
      refute(entry.absolute_time?)
    end
  end

  def test_only_zip64_suppressed
    buffer = Ziperu::OutputStream.write_buffer(suppress_extra_fields: :zip64) do |zos|
      entry = Ziperu::Entry.new(nil, "write_test")
      entry.atime = Time.now
      zos.put_next_entry(entry)
      zos.write "hello, world!"
    end
    Ziperu::InputStream.open(buffer) do |zis|
      entry = zis.get_next_entry
      refute(entry.zip64?)
      assert(entry.absolute_time?)
    end
  end

  def test_ut_but_not_zip64_suppressed_with_large_size
    buffer = Ziperu::OutputStream.write_buffer(suppress_extra_fields: true) do |zos|
      entry = Ziperu::Entry.new(nil, "write_test", size: 0x1_0000_0000)
      entry.atime = Time.now
      zos.put_next_entry(entry)
      zos.write "hello, world!"
    end
    Ziperu::InputStream.open(buffer) do |zis|
      entry = zis.get_next_entry
      assert(entry.zip64?)
      refute(entry.absolute_time?)
    end
  end

  def test_aes_round_trip
    buffer = Ziperu::OutputStream.write_buffer(encrypter: Ziperu::AESEncrypter.new("secret")) do |zos|
      zos.put_next_entry("secret.txt")
      zos.write "top secret"
    end

    Ziperu::InputStream.open(buffer) do |zis|
      assert_raises(Ziperu::Error) { zis.get_next_entry }
    end
    Ziperu::InputStream.open(buffer, decrypter: Ziperu::AESDecrypter.new("secret")) do |zis|
      entry = zis.get_next_entry
      assert_predicate entry, :encrypted?
      assert_equal "top secret", zis.read
    end
  end

  def test_traditional_encrypter_writes_zipcrypto_entries
    Ziperu::OutputStream.open(@zip, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |zos|
      zos.put_next_entry("x")
      zos.write("top secret")
    end
    Ziperu::InputStream.open(@zip, decrypter: Ziperu::TraditionalDecrypter.new("pw")) do |zis|
      entry = zis.get_next_entry
      assert_predicate entry, :encrypted?
      assert_equal "top secret", zis.read
    end
  end

  def test_copy_raw_entry
    Ziperu::File.open(fixture("text.zip")) do |zf|
      Ziperu::OutputStream.open(@zip) do |zos|
        zos.copy_raw_entry(zf.get_entry("long.txt"))
        zos.copy_raw_entry(zf.get_entry("short.txt"), "renamed.txt")
      end
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal %w[long.txt renamed.txt], zf.map(&:name)
      assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
      assert_equal "short\n", zf.read("renamed.txt")
      assert_equal Ziperu::Entry::DEFLATED, zf.get_entry("long.txt").compression_method
    end
  end

  def test_round_trip_with_rubyzip
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.comment = COMMENT
      write_test_zip(zos)
    end
    # Python's zipfile as an independent reader.
    skip "python not available" unless python
    out = `#{python} -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); print(z.testzip()); print(z.comment.decode()); print(len(z.namelist()))" "#{@zip}"`

    assert_equal ["None", COMMENT, ENTRIES.size.to_s], out.lines.map(&:chomp)
  end

  # A seekable IO receives each entry as the next one starts, as rubyzip
  # streams; nothing waits for close.
  def test_write_buffer_streams_entry_by_entry_into_a_seekable_io
    io = StringIO.new
    positions = []
    Ziperu::OutputStream.write_buffer(io) do |zos|
      ENTRIES.each do |name|
        zos.put_next_entry(name)
        zos.write(File.binread(fixture("text/#{name}")))
        positions << io.pos
      end
    end
    assert_equal positions, positions.sort
    assert_equal positions.size, positions.uniq.size
    assert_operator positions.first, :>, 0
    assert_operator io.pos, :>, positions.last, "the central directory follows the entries"
    assert_equal io.pos, io.string.bytesize
    assert_test_zip_contents(StringIO.new(io.string))
  end

  def test_write_buffer_round_trips_a_string_io_file_and_tempfile
    string_io = StringIO.new
    Ziperu::OutputStream.write_buffer(string_io) { |zos| write_test_zip(zos) }
    Ziperu::File.open_buffer(string_io) { |zf| assert_equal ENTRIES, zf.entries.map(&:name) }

    Tempfile.create(["ziperu", ".zip"]) do |tmp|
      Ziperu::OutputStream.write_buffer(tmp) { |zos| write_test_zip(zos) }
      Ziperu::File.open_buffer(tmp) do |zf|
        assert_equal ENTRIES, zf.entries.map(&:name)
        assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
      end
    end

    File.open(@zip, "w+b") do |f|
      Ziperu::OutputStream.write_buffer(f) { |zos| write_test_zip(zos) }
      f.rewind
      Ziperu::File.open_buffer(f) { |zf| assert_equal ENTRIES, zf.entries.map(&:name) }
    end
    assert_test_zip_contents(@zip)
  end

  def test_write_buffer_starts_at_the_beginning_of_the_io
    io = StringIO.new(+"stale bytes that a previous archive left behind" * 100)
    io.seek(0, IO::SEEK_END)
    Ziperu::OutputStream.write_buffer(io) do |zos|
      zos.put_next_entry("a.txt")
      zos.write("a")
    end
    assert_equal "PK\x03\x04".b, io.string.byteslice(0, 4)
    Ziperu::File.open_buffer(io) { |zf| assert_equal "a", zf.read("a.txt") }
  end

  class FailingWriteIO < StringIO
    class Boom < StandardError; end

    def write(*)
      raise Boom, "disk full"
    end
  end

  def test_an_exception_raised_by_the_io_write_propagates_unchanged
    assert_raises(FailingWriteIO::Boom) do
      Ziperu::OutputStream.write_buffer(FailingWriteIO.new) do |zos|
        zos.put_next_entry("a.txt")
        zos.write("a" * 100_000)
        zos.put_next_entry("b.txt")
      end
    end
  end

  def test_write_buffer_with_a_pipe_hands_over_the_archive_on_close
    rd, wr = IO.pipe
    reader = Thread.new { rd.binmode; rd.read }
    Ziperu::OutputStream.write_buffer(wr) { |zos| write_test_zip(zos) }
    wr.close
    bytes = reader.value
    assert_test_zip_contents(StringIO.new(bytes))
  ensure
    rd&.close
    wr&.close unless wr&.closed?
  end

  private

  def assert_io_error_in_closed_stream
    assert_raises(IOError) do
      zos = Ziperu::OutputStream.new(File.join(@tmp, "closed.zip"))
      zos.close
      yield zos
    end
  end
end
