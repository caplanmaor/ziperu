# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# rubyzip 2.x's call forms. `Zip::VERSION` is ziperu's own, so a library
# that branches on it takes its 2.x path with ziperu; every form 3.0
# replaced with keywords (or removed) still works here.
class LegacyFormsTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-legacy")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def read_back(bytes, name, **opts)
    Ziperu::File.open_buffer(bytes, **opts) { |z| return z.read(name) }
  end

  def test_file_new_and_open_with_positional_create_buffer_and_options
    Ziperu::File.open(@path, Ziperu::File::CREATE, { restore_times: false }) do |zf|
      zf.get_output_stream("a.txt") { |o| o.write "a" }
      refute zf.restore_times
    end
    zf = Ziperu::File.new(@path, false, false, { restore_permissions: false })
    assert_equal %w[a.txt], zf.entries.map(&:name)
    refute zf.restore_permissions
    zf.close

    io = StringIO.new
    zf = Ziperu::File.new(io, true, true) # (io, create, buffer)
    zf.get_output_stream("b.txt") { |o| o.write "b" }
    zf.write_buffer(io)
    assert_equal "b", read_back(io.string, "b.txt")
  end

  def test_add_buffer_returns_the_written_string_io
    io = Ziperu::File.add_buffer do |zf|
      zf.get_output_stream("hello.txt") { |o| o.write "hello" }
    end
    assert_kind_of StringIO, io
    assert_equal "hello", read_back(io.string, "hello.txt")
  end

  def test_get_output_stream_with_positional_permissions_and_comment
    Ziperu::File.open(@path, create: true) do |zf|
      zf.get_output_stream("x.sh", 0o755, "runs things") { |o| o.write "#!/bin/sh" }
    end
    Ziperu::File.open(@path) do |zf|
      e = zf.get_entry("x.sh")
      assert_equal 0o755, e.unix_perms
      assert_equal "runs things", e.comment
    end
  end

  def test_entry_new_with_positional_arguments
    e = Ziperu::Entry.new("", "n.txt", "a comment", "", 0, 0, Ziperu::Entry::STORED, 42)
    assert_equal "a comment", e.comment
    assert_equal Ziperu::Entry::STORED, e.compression_method
    assert_equal 42, e.size
  end

  def test_input_stream_with_positional_offset_and_decrypter
    Ziperu::OutputStream.open(@path, Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("s.txt")
      z.write("secret")
    end
    Ziperu::InputStream.open(@path, 0, Ziperu::TraditionalDecrypter.new("pw")) do |is|
      assert_equal "s.txt", is.get_next_entry.name
      assert_equal "secret", is.read
    end
    is = Ziperu::InputStream.new(File.open(@path, "rb"), 0, Ziperu::TraditionalDecrypter.new("pw"))
    is.get_next_entry
    assert_equal "secret", is.read
    is.close
  end

  def test_output_stream_with_positional_stream_and_encrypter
    io = StringIO.new
    zos = Ziperu::OutputStream.new(io, true) # (io, stream)
    zos.put_next_entry("a.txt")
    zos.write("a")
    zos.close_buffer
    assert_equal "a", read_back(io.string, "a.txt")

    enc = Ziperu::AESEncrypter.new("pw")
    buf = Ziperu::OutputStream.write_buffer(StringIO.new, enc) do |z|
      z.put_next_entry("e.txt")
      z.write("e")
    end
    assert_equal "e", read_back(buf.string, "e.txt", password: "pw")

    zos = Ziperu::OutputStream.new(StringIO.new, true, enc) # (io, stream, encrypter)
    assert_kind_of Ziperu::OutputStream, zos
    zos.abort
  end

  def test_rubyzip_1_error_names_still_resolve
    assert_equal Ziperu::Error, Ziperu::ZipError
    assert_equal Ziperu::EntryExistsError, Ziperu::ZipEntryExistsError
    assert_equal Ziperu::DestinationExistsError, Ziperu::ZipDestinationFileExistsError
    assert_equal Ziperu::CompressionMethodError, Ziperu::ZipCompressionMethodError
    assert_equal Ziperu::EntryNameError, Ziperu::ZipEntryNameError
    assert_equal Ziperu::InternalError, Ziperu::ZipInternalError
    assert_raises(Zip::ZipError) { Zip::File.open(File.join(@dir, "missing.zip")) }
  end
end
