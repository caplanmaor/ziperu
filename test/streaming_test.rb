# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Writing an archive to an IO that cannot seek (a pipe, a socket, a
# response body): entries go out as they are written, with their sizes in
# data descriptors, and nothing is buffered to the end.
class StreamingTest < Minitest::Test
  include TestHelper

  # A write-only sink with no seek or tell, like a Rack response body or
  # a socket; records how many separate writes it saw.
  class Sink
    attr_reader :chunks

    def initialize
      @chunks = []
    end

    def write(data)
      @chunks << data.dup
      data.bytesize
    end

    def string
      @chunks.join
    end
  end

  def setup
    @dir = Dir.mktmpdir("ziperu-streaming")
    @big = Random.new(11).bytes(3 * 1024 * 1024)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_sample(zos)
    zos.put_next_entry("a.txt")
    zos.write("alpha " * 100)
    zos.put_next_entry("dir/")
    zos.put_next_entry("dir/big.bin")
    zos.write(@big[0, 1 << 20])
    zos.write(@big[1 << 20, 2 << 20])
    zos.put_next_entry("stored.bin", "", Ziperu::ExtraField.new, Ziperu::Entry::STORED)
    zos.write("stored" * 10)
    zos.comment = "streamed"
  end

  def assert_sample(bytes)
    Ziperu::File.open_buffer(bytes) do |zf|
      assert_equal %w[a.txt dir/ dir/big.bin stored.bin], zf.entries.map(&:name)
      assert_equal "alpha " * 100, zf.read("a.txt")
      assert_equal @big, zf.read("dir/big.bin")
      assert_equal "stored" * 10, zf.read("stored.bin")
      assert_equal "streamed", zf.comment
      assert zf.get_entry("a.txt").gp_flags & 8 != 0, "streamed entries announce a data descriptor"
      assert_equal 0, zf.get_entry("dir/").gp_flags & 8
      assert_equal Ziperu::Entry::STORED, zf.get_entry("stored.bin").compression_method
      assert_empty zf.verify
      yield zf if block_given?
    end
  end

  def test_write_buffer_to_a_write_only_sink_streams_entries
    sink = Sink.new
    written = []
    Ziperu::OutputStream.write_buffer(sink) do |zos|
      write_sample(zos)
      written = zos.instance_variable_get(:@written).dup
      assert_operator sink.string.bytesize, :>, 1 << 20, "data went out before close"
    end
    assert_sample(sink.string) do |zf|
      # The entries learnt their sizes and CRCs even though nothing was read back.
      written.each do |e|
        in_archive = zf.get_entry(e.name)
        assert_equal in_archive.size, e.size, e.name
        assert_equal in_archive.crc, e.crc, e.name
        assert_equal in_archive.compressed_size, e.compressed_size, e.name
        assert_equal in_archive.local_header_offset, e.local_header_offset, e.name
      end
    end
  end

  def test_write_buffer_to_a_pipe
    r, w = IO.pipe
    r.binmode
    reader = Thread.new { r.read }
    Ziperu::OutputStream.write_buffer(w) { |zos| write_sample(zos) }
    w.close
    bytes = reader.value
    assert_sample(bytes)
    # The descriptor sits right after the data: signature, CRC, sizes. The
    # size was not known up front, so the entry is zip64-ready and the
    # descriptor carries 64-bit sizes, as rubyzip would write it.
    Ziperu::File.open_buffer(bytes) do |zf|
      e = zf.get_entry("a.txt")
      hdr = bytes.byteslice(e.local_header_offset, 30).unpack("VvvvvvVVVvv")
      nlen = hdr[9]
      xlen = hdr[10]
      assert_equal 45, hdr[1], "version needed: zip64"
      after = bytes.byteslice(e.local_header_offset + 30 + nlen + xlen + e.compressed_size, 24)
      sig, crc, csize, usize = after.unpack("VVQ<Q<")
      assert_equal 0x08074b50, sig
      assert_equal [e.crc, e.compressed_size, e.size], [crc, csize, usize]
    end
  end

  def test_aes_to_a_stream
    sink = Sink.new
    Ziperu::OutputStream.write_buffer(sink, encrypter: Ziperu::AESEncrypter.new("pw")) do |zos|
      zos.put_next_entry("secret.txt")
      zos.write("top secret " * 50)
    end
    Ziperu::File.open_buffer(sink.string, password: "pw") do |zf|
      assert_equal "top secret " * 50, zf.read("secret.txt")
      assert_empty zf.verify
    end
  end

  def test_zipcrypto_to_a_stream_is_built_in_memory_and_still_correct
    sink = Sink.new
    Ziperu::OutputStream.write_buffer(sink, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |zos|
      zos.put_next_entry("secret.txt")
      zos.write("top secret " * 50)
      assert_equal 0, sink.string.bytesize, "nothing can go out before the headers are final"
    end
    Ziperu::File.open_buffer(sink.string, password: "pw") do |zf|
      assert_equal "top secret " * 50, zf.read("secret.txt")
    end
  end

  def test_copy_raw_entry_into_a_stream
    src = path("src.zip")
    Ziperu::File.open(src, create: true) do |zf|
      zf.get_output_stream("one.txt") { |o| o.write "one" }
      zf.get_output_stream("two.bin") { |o| o.write @big[0, 100_000] }
    end
    zc = path("zc.zip")
    Ziperu::OutputStream.open(zc, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("locked.txt")
      z.write("locked")
    end
    sink = Sink.new
    Ziperu::File.open(src) do |zf|
      Ziperu::OutputStream.write_buffer(sink) do |zos|
        zos.copy_raw_entry(zf.get_entry("one.txt"))
        zos.copy_raw_entry(zf.get_entry("two.bin"), "renamed.bin")
        Ziperu::File.open(zc) do |locked|
          e = assert_raises(ArgumentError) { zos.copy_raw_entry(locked.get_entry("locked.txt")) }
          assert_match(/cannot be written to a stream/, e.message)
        end
      end
    end
    Ziperu::File.open_buffer(sink.string) do |zf|
      assert_equal "one", zf.read("one.txt")
      assert_equal @big[0, 100_000], zf.read("renamed.bin")
      assert_empty zf.verify
    end
  end

  def test_file_write_buffer_to_a_pipe
    src = path("src.zip")
    Ziperu::File.open(src, create: true) do |zf|
      zf.get_output_stream("one.txt") { |o| o.write "one" }
      zf.mkdir("d")
    end
    r, w = IO.pipe
    r.binmode
    reader = Thread.new { r.read }
    Ziperu::File.open(src) do |zf|
      zf.get_output_stream("added.txt") { |o| o.write "added" }
      zf.write_buffer(w)
    end
    w.close
    Ziperu::File.open_buffer(reader.value) do |zf|
      assert_equal %w[one.txt d/ added.txt], zf.entries.map(&:name)
      assert_equal "added", zf.read("added.txt")
    end
  end

  def test_file_write_buffer_of_a_zipcrypto_archive_to_a_pipe_falls_back_to_memory
    zc = path("zc.zip")
    Ziperu::OutputStream.open(zc, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("locked.txt")
      z.write("locked")
    end
    r, w = IO.pipe
    r.binmode
    reader = Thread.new { r.read }
    Ziperu::File.open(zc) do |zf|
      zf.get_output_stream("plain.txt") { |o| o.write "plain" }
      zf.write_buffer(w)
    end
    w.close
    Ziperu::File.open_buffer(reader.value, password: "pw") do |zf|
      assert_equal "locked", zf.read("locked.txt")
      assert_equal "plain", zf.read("plain.txt")
    end
  end

  def test_body_is_an_enumerator_of_the_archive_in_chunks
    ran = false
    body = Ziperu::OutputStream.body do |zos|
      ran = true
      write_sample(zos)
    end
    assert_kind_of Enumerator, body
    refute ran, "nothing is written until the chunks are asked for"
    chunks = body.map { |c| c } # what Rack does
    assert ran
    assert_operator chunks.size, :>, 1, "the archive comes out in pieces"
    assert_sample(chunks.join)
  end

  def test_body_chunks_can_be_pulled_one_at_a_time
    body = Ziperu::OutputStream.body { |zos| write_sample(zos) }
    first = body.next
    assert_equal "PK\x03\x04".b, first.byteslice(0, 4)
    rest = []
    loop { rest << body.next }
    assert_sample(first + rest.join)
  end

  def test_body_with_encryption_and_errors
    body = Ziperu::OutputStream.body(encrypter: Ziperu::AESEncrypter.new("pw")) do |zos|
      zos.put_next_entry("secret.txt")
      zos.write("top secret")
    end
    Ziperu::File.open_buffer(body.to_a.join, password: "pw") do |zf|
      assert_equal "top secret", zf.read("secret.txt")
    end

    boom = Class.new(StandardError)
    body = Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("a.txt")
      zos.write("partial")
      raise boom, "source went away"
    end
    assert_raises(boom) { body.each { |_c| } }
    assert_raises(ArgumentError) { Ziperu::OutputStream.body }
  end

  def test_large_entry_streams_with_zip64_sizes_in_the_descriptor
    sink = Sink.new
    Ziperu::OutputStream.write_buffer(sink) do |zos|
      e = Ziperu::Entry.new("", "big.bin")
      zos.put_next_entry(e) # size unknown up front: written zip64-ready
      zos.write(@big)
    end
    Ziperu::File.open_buffer(sink.string) do |zf|
      e = zf.get_entry("big.bin")
      assert_equal @big.bytesize, e.size
      assert_equal @big, zf.read("big.bin")
    end
  end

  private

  def path(name)
    File.join(@dir, name)
  end
end
