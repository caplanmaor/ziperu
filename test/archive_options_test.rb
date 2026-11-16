# frozen_string_literal: true

# Opening and writing archives under options and limits: `write:`
# paths, compression, size limits, read-only files, corrupt data.
# Each test pins down a bug found in a review or testing round.

require_relative "test_helper"
require_relative "support/archive_scratch"
require "tmpdir"
require "timeout"
require "delegate"

class ArchiveOptionsTest < Minitest::Test
  include TestHelper
  include ArchiveScratch

  def test_write_to_a_path_keeps_every_commit
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a")
      z.write("a")
    end
    original = File.binread(@path)
    out = File.join(@dir, "out.zip")
    Ziperu::File.open(@path, write: out) do |zf|
      zf.get_output_stream("b") { |o| o << "b" }
      zf.commit
      assert_equal out, zf.name, "after the first commit the object works on the new archive"
      zf.get_output_stream("c") { |o| o << "c" }
    end
    Ziperu::File.open(out) { |zf| assert_equal %w[a b c], zf.entries.map(&:name) }
    assert_equal original, File.binread(@path), "the original is untouched"

    fresh = File.join(@dir, "fresh.zip")
    Ziperu::File.open(File.join(@dir, "new.zip"), create: true, write: fresh) do |zf|
      zf.get_output_stream("x") { |o| o << "x" }
      zf.commit
    end
    Ziperu::File.open(fresh) { |zf| assert_equal %w[x], zf.entries.map(&:name) }
  end

  def test_default_compression_per_archive
    Ziperu::File.open(@path, create: true, default_compression: 0) do |zf|
      zf.get_output_stream("a.txt") { |o| o << ("a" * 1000) }
    end
    Ziperu::File.open(@path) { |zf| assert_equal Ziperu::Entry::STORED, zf.get_entry("a.txt").compression_method }
    other = File.join(@dir, "b.zip")
    Ziperu::File.open(other, create: true) { |zf| zf.get_output_stream("a.txt") { |o| o << ("a" * 1000) } }
    Ziperu::File.open(other) { |zf| assert_equal Ziperu::Entry::DEFLATED, zf.get_entry("a.txt").compression_method }
  end

  def test_max_archive_size_bounds_what_is_read_from_a_pipe
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a")
      z.write(Random.new(1).bytes(50_000))
    end
    bytes = File.binread(@path)
    pipe = lambda do
      r, w = IO.pipe
      w.binmode
      writer = Thread.new do
        begin
          w.write(bytes)
        rescue StandardError
          nil
        end
        w.close
      end
      [r, writer]
    end

    r, writer = pipe.call
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(r, max_archive_size: 10_000) { nil } }
    r.close
    writer.join

    r, writer = pipe.call
    Ziperu::InputStream.open(r, max_archive_size: 1_000_000) do |is|
      assert_equal "a", is.get_next_entry.name
    end
    writer.join
  end

  def test_estimated_size_takes_the_stream_settings
    data = "x" * 4321
    opts = { write_extended_timestamps: true }
    estimate = Ziperu::OutputStream.estimated_size(**opts) { |e| e.add_stored("a.txt", data.bytesize) }
    actual = Ziperu::OutputStream.body(**opts) do |z|
      z.put_next_entry(Ziperu::Entry.new("", "a.txt", size: data.bytesize, compression_method: Ziperu::Entry::STORED))
      z.write(data)
    end.to_a.join.bytesize
    assert_equal actual, estimate
    assert_raises(ArgumentError) { Ziperu::OutputStream.estimated_size(write_extended_timestamp: true) { nil } }
  end

  def test_foreach_rejects_an_unknown_keyword
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a")
      z.write("a")
    end
    assert_raises(ArgumentError) { Ziperu::File.foreach(@path, max_entrys: 1) { nil } }
  end

  def test_duplicate_names_count_against_every_limit
    many = duplicate_named(["x"] * 20)
    Ziperu::File.open_buffer(many) { |zf| assert_equal 20, zf.entries.size }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(many, max_entries: 5) }
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(StringIO.new(many), max_entries: 5) }

    bomb = duplicate_named(["\0" * 5_000_000, "ok"])
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(bomb, max_entry_size: 1000) }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(bomb, max_total_size: 1000) }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(bomb, max_compression_ratio: 10) }
  end

  def test_a_directory_at_the_archive_path_is_left_alone
    target = File.join(@dir, "d.zip")
    FileUtils.mkdir_p(File.join(target, "inner"))
    File.write(File.join(target, "precious.txt"), "keep")
    assert_raises(SystemCallError) do
      Ziperu::File.open(target, create: true) { |zf| zf.get_output_stream("x") { |o| o << "x" } }
    end
    assert File.directory?(target)
    assert_equal "keep", File.read(File.join(target, "precious.txt"))
    assert_empty Dir.glob(File.join(@dir, "*.old"))
  end

  def test_a_read_only_archive_can_still_be_added_to
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a")
      z << "a"
    end
    File.chmod(0o444, @path)
    Ziperu::File.open(@path) { |zf| zf.get_output_stream("b") { |o| o << "b" } }
    Ziperu::File.open(@path) { |zf| assert_equal %w[a b], zf.entries.map(&:name) }
  ensure
    File.chmod(0o644, @path) if File.exist?(@path)
  end

  def test_corrupt_data_of_every_method_is_a_decompression_error
    [Ziperu::Entry::ZSTD, Ziperu::Entry::BZIP2, Ziperu::Entry::DEFLATED].each do |method|
      bytes = Ziperu::OutputStream.write_buffer do |zos|
        zos.put_next_entry("x", nil, nil, method)
        zos << (Random.new(method).bytes(50_000) * 2)
      end.string.b
      data_at = 30 + 1 + bytes.byteslice(28, 2).unpack1("v")
      bytes[data_at + 100, 64] = "\xAA".b * 64
      error = assert_raises(Ziperu::Error) { Ziperu::File.open_buffer(bytes) { |zf| zf.read("x") } }
      assert_kind_of Ziperu::Error, error, "method #{method}"
    end
  end

  def test_a_local_header_that_disagrees_on_the_method_is_refused
    bytes = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("x")
      zos << ("compressible " * 100)
    end.string.b
    central = bytes.rindex("PK\x01\x02".b)
    bytes[central + 10, 2] = [0].pack("v") # the central record says Stored
    Ziperu::File.open_buffer(bytes, validate_entry_sizes: false) do |zf|
      assert_raises(Ziperu::Error) { zf.read("x") }
    end
  end

  def test_open_messages
    error = assert_raises(Errno::ENOENT) { Ziperu::InputStream.open(File.join(@dir, "missing.zip")) }
    assert_includes error.message, "missing.zip"
    assert_raises(TypeError) { Ziperu::File.open(nil) }
    assert_raises(TypeError) { Ziperu::File.open(5) }
  end

  def test_an_oversized_archive_comment_is_refused_up_front
    assert_raises(ArgumentError) do
      Ziperu::OutputStream.write_buffer { |zos| zos.comment = "x" * 65_536 }
    end
  end

  # rubyzip's compressor classes are kept for code that names them; they
  # pass their output through the encrypter.
  def test_the_rubyzip_compressors_work_with_the_null_encrypter
    out = +"".b
    stored = Ziperu::PassThruCompressor.new(out)
    stored << "abc"

    assert_equal "abc", out
    assert_equal 3, stored.size

    out = +"".b
    deflater = Ziperu::Deflater.new(out)
    deflater << "hello hello hello"
    deflater.finish

    assert_equal "hello hello hello", Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(out)
  end

  def encrypted_zip
    Ziperu::OutputStream.open(@path, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("secret.txt")
      z.write("secret")
    end
    @path
  end

  def test_the_extract_all_one_liner_takes_what_open_takes
    out = File.join(@dir, "out")
    Ziperu::File.extract_all(encrypted_zip, out, password: "pw", on_exists: :overwrite)
    assert_equal "secret", File.read(File.join(out, "secret.txt"))
    assert_raises(Ziperu::LimitError) { Ziperu::File.extract_all(@path, out, max_entries: 0) }
    assert_raises(ArgumentError) { Ziperu::File.extract_all(@path, out, no_such_option: 1) }
  end

  def test_foreach_takes_a_password
    entry = Ziperu::File.foreach(encrypted_zip, password: "pw").first
    assert_equal "secret", entry.get_input_stream(&:read)
    Ziperu::File.foreach(@path, password: "pw") { |e| assert_equal "secret", e.get_input_stream(&:read) }
    File.open(@path, "rb") do |io|
      Ziperu::File.foreach(io, password: "pw") { |e| assert_equal "secret", e.get_input_stream(&:read) }
    end
    error = assert_raises(Ziperu::Error) { Ziperu::File.foreach(@path).first.get_input_stream(&:read) }
    assert_match(/password/i, error.message)
  end

  def test_an_unknown_metadata_encoding_raises
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a") }
    [
      -> { Ziperu::File.open(@path, metadata_encoding: "NoSuchEnc") { nil } },
      -> { Ziperu::File.foreach(@path, metadata_encoding: "NoSuchEnc") { nil } },
      -> { Ziperu::InputStream.open(@path, metadata_encoding: "NoSuchEnc") { nil } }
    ].each do |open|
      error = assert_raises(ArgumentError, &open)
      assert_match(/unknown metadata_encoding: "NoSuchEnc"/, error.message)
    end
    Ziperu::File.open(@path, metadata_encoding: Encoding::Shift_JIS) { |zf| assert_equal 1, zf.size }
  end

  def test_a_file_inspects_in_a_line_however_many_entries_it_has
    Ziperu::OutputStream.open(@path) { |z| 500.times { |i| z.put_next_entry("f#{i}") } }
    Ziperu::File.open(@path) do |zf|
      assert_equal "#<Ziperu::File:#{@path} entries=500>", zf.inspect
      zf.get_output_stream("new.txt") { |os| os.write("x") }
      assert_equal "#<Ziperu::File:#{@path} entries=501 (uncommitted changes)>", zf.inspect
    end
    Ziperu::File.open(@path, write: false) { |zf| assert_match(/entries=501 \(read-only\)>\z/, zf.inspect) }
  end

  def test_a_cut_short_archive_is_described_without_rust_type_names
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("a")
      z.write("hello")
    end
    File.binwrite(@path, File.binread(@path)[0..-11])
    error = assert_raises(Ziperu::Error) { Ziperu::File.open(@path) { nil } }
    refute_match(/::|Block/, error.message)
    assert_match(/end of central directory record is cut short/, error.message)
  end
end
