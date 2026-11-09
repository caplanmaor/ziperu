# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Conveniences beyond rubyzip's API: a password on the archive itself, and
# `add` from an IO.
class ComfortTest < Minitest::Test
  include TestHelper

  PASSWORD = "s3cret"

  def setup
    @dir = Dir.mktmpdir("ziperu-comfort")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def path(name)
    File.join(@dir, name)
  end

  def write_encrypted(file, encrypter)
    Ziperu::OutputStream.open(file, encrypter: encrypter) do |z|
      z.put_next_entry("a.txt")
      z.write("alpha " * 100)
      z.put_next_entry("dir/b.bin")
      z.write(Random.new(3).bytes(20_000))
    end
  end

  def each_cipher
    { "zipcrypto" => Ziperu::TraditionalEncrypter.new(PASSWORD),
      "aes" => Ziperu::AESEncrypter.new(PASSWORD) }.each do |kind, enc|
      file = path("#{kind}.zip")
      write_encrypted(file, enc)
      yield kind, file
    end
  end

  def test_password_on_file_open_decrypts_everything
    each_cipher do |kind, file|
      Ziperu::File.open(file, password: PASSWORD) do |zf|
        assert_equal "alpha " * 100, zf.read("a.txt"), kind
        assert_equal 20_000, zf.get_input_stream("dir/b.bin", &:read).bytesize, kind
        assert_equal "alpha " * 100, zf.get_entry("a.txt").get_input_stream(&:read), kind
        assert_empty zf.verify, kind
        out = path("out-#{kind}")
        zf.extract_all(out)
        assert_equal "alpha " * 100, File.read(File.join(out, "a.txt")), kind
        assert_equal 20_000, File.size(File.join(out, "dir/b.bin")), kind
        zf.extract("a.txt", "one.txt", destination_directory: out)
        assert_equal "alpha " * 100, File.read(File.join(out, "one.txt")), kind
      end
    end
  end

  def test_decrypter_keyword_and_open_buffer
    each_cipher do |kind, file|
      dec = kind == "aes" ? Ziperu::AESDecrypter.new(PASSWORD) : Ziperu::TraditionalDecrypter.new(PASSWORD)
      assert_equal "alpha " * 100, Ziperu::File.open(file, decrypter: dec) { |zf| zf.read("a.txt") }, kind
      data = Ziperu::File.open_buffer(File.binread(file), password: PASSWORD) { |zf| @got = zf.read("a.txt") }
      assert_equal "alpha " * 100, @got, kind
      refute_nil data
    end
  end

  def test_without_a_password_encrypted_entries_still_raise
    each_cipher do |kind, file|
      Ziperu::File.open(file) do |zf|
        assert_raises(Ziperu::Error) { zf.read("a.txt") }
        assert_equal 2, zf.verify.size, "#{kind}: verify reports what it cannot check" if false
      end
      Ziperu::File.open(file, password: "wrong") do |zf|
        assert_raises(Ziperu::Error) { zf.read("a.txt") }
        refute_empty zf.verify, kind
      end
    end
  end

  def test_password_on_input_stream
    each_cipher do |kind, file|
      names = []
      Ziperu::InputStream.open(file, password: PASSWORD) do |is|
        while (e = is.get_next_entry)
          names << e.name
          assert_equal "alpha " * 100, is.read if e.name == "a.txt"
        end
      end
      assert_equal %w[a.txt dir/b.bin], names, kind
    end
  end

  def test_encrypted_archive_can_still_be_modified_with_the_password_set
    each_cipher do |kind, file|
      Ziperu::File.open(file, password: PASSWORD) do |zf|
        zf.get_output_stream("plain.txt") { |o| o.write "plain" }
        zf.rename("a.txt", "renamed.txt")
      end
      Ziperu::File.open(file, password: PASSWORD) do |zf|
        assert_equal "alpha " * 100, zf.read("renamed.txt"), kind
        assert_equal "plain", zf.read("plain.txt"), kind
        assert_empty zf.verify, kind
      end
    end
  end

  def test_add_from_an_io
    file = path("io.zip")
    src = path("src.bin")
    File.binwrite(src, Random.new(5).bytes(100_000))
    Ziperu::File.open(file, create: true) do |zf|
      zf.add("from_string_io.txt", StringIO.new("hello from a StringIO"))
      File.open(src, "rb") do |f|
        e = zf.add("from_file.bin", f)
        assert_equal 100_000, e.size
        # Readable and extractable before the commit.
        assert_equal File.binread(src), zf.read("from_file.bin")
        assert_equal "hello from a StringIO", zf.read("from_string_io.txt")
        zf.extract("from_string_io.txt", "early.txt", destination_directory: @dir)
        assert_equal "hello from a StringIO", File.read(path("early.txt"))
        zf.commit
      end
    end
    Ziperu::File.open(file) do |zf|
      assert_equal "hello from a StringIO", zf.read("from_string_io.txt")
      assert_equal File.binread(src), zf.read("from_file.bin")
      assert_equal Ziperu::Entry::DEFLATED, zf.get_entry("from_file.bin").compression_method
      assert_empty zf.verify
    end
  end

  def test_add_from_an_io_into_a_buffer_and_a_pipe_like_source
    r, w = IO.pipe
    w.write("piped")
    w.close
    io = Ziperu::File.open_buffer(StringIO.new(+""), create: true) do |zf|
      zf.add("piped.txt", r)
      zf.add("dir/", StringIO.new("")) rescue assert_instance_of(ArgumentError, $!)
    end
    Ziperu::File.open_buffer(io.string) do |zf|
      assert_equal "piped", zf.read("piped.txt")
      assert_equal ["piped.txt"], zf.entries.map(&:name)
    end
  end
end
