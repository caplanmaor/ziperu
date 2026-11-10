# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "timeout"

# The bugs found in the review after 0.2.0, each as it was reproduced.
class Fixes021Test < Minitest::Test
  include TestHelper

  def setup
    Ziperu.reset!
    @dir = Dir.mktmpdir("ziperu-021")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@dir)
  end

  def test_a_stream_that_fails_is_left_unfinished
    body = Ziperu::OutputStream.body do |z|
      z.put_next_entry("a")
      z.write("a" * 100_000)
      z.put_next_entry("b")
      z.write("partial")
      raise "boom"
    end
    bytes = +""
    assert_raises(RuntimeError) { body.each { |c| bytes << c } }
    assert_raises(Ziperu::Error, "a failed stream must not read as a complete archive") do
      Ziperu::File.open_buffer(bytes) { |zf| zf.entries }
    end

    io = StringIO.new
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.write_buffer(io) { |z| z.put_next_entry("a"); z.write("aaa"); raise "boom" }
    end
    assert_raises(Ziperu::Error) { Ziperu::File.open_buffer(io.string) { |zf| zf.entries } }
  end

  def test_an_archive_at_a_path_is_still_closed_on_failure_as_rubyzip_does
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a"); z.write("a"); raise "boom" }
    end
    Ziperu::File.open(@path) { |zf| assert_equal %w[a], zf.entries.map(&:name) }
  end

  def test_write_to_a_path_keeps_every_commit
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a"); z.write("a") }
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

  def test_a_zero_length_read_reads_nothing
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("x"); z.write("hello world") }
    Ziperu::InputStream.open(@path) do |is|
      is.get_next_entry
      assert_equal "hello", is.read(5)
      assert_equal "", is.sysread(0)
      assert_equal "", is.read(0)
      refute is.eof?
      assert_equal " world", is.read
    end
  end

  def test_a_zipcrypto_copy_that_fails_is_taken_back_out
    src = File.join(@dir, "zc.zip")
    Ziperu::OutputStream.open(src, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("secret.txt", nil, nil, Ziperu::Entry::STORED)
      z.write("s" * 1000)
    end
    # Declare far more data than the archive holds, so the copy runs dry.
    bytes = File.binread(src)
    central = bytes.rindex("PK\x01\x02".b)
    bytes[central + 20, 4] = [5_000_000].pack("V")
    File.binwrite(src, bytes)
    entry = begin
      Ziperu::File.open(src) { |zf| zf.get_entry("secret.txt") }
    rescue Ziperu::Error
      skip "the archive is refused on open, before any copy"
    end

    Ziperu::OutputStream.open(@path) do |z|
      assert_raises(Ziperu::Error) { z.copy_encrypted_entry(entry) }
      z.put_next_entry("ok.txt")
      z.write("fine")
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[ok.txt], zf.entries.map(&:name), "no half-copied encrypted entry is left behind"
      assert_equal "fine", zf.read("ok.txt")
      assert_empty zf.verify
    end
  end

  def test_timeout_interrupts_native_work_and_leaves_the_archive_usable
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("zeros.bin")
      chunk = "\0" * (1 << 20)
      768.times { z.write(chunk) }
      z.put_next_entry("small.txt")
      z.write("small")
    end
    Ziperu::File.open(@path) do |zf|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) { Timeout.timeout(0.1) { zf.read("zeros.bin") } }
      assert_raises(Timeout::Error) do
        Timeout.timeout(0.1) { zf.get_input_stream("zeros.bin") { |is| is.read } }
      end
      assert_raises(Timeout::Error) { Timeout.timeout(0.1) { zf.extract_all(File.join(@dir, "out")) } }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 3, "each call stops within a chunk of the interrupt"
      assert_equal "small", zf.read("small.txt"), "nothing is left locked"
    end
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
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a"); z.write(Random.new(1).bytes(50_000)) }
    bytes = File.binread(@path)
    pipe = lambda do
      r, w = IO.pipe
      w.binmode
      writer = Thread.new { w.write(bytes) rescue nil; w.close }
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
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a"); z.write("a") }
    assert_raises(ArgumentError) { Ziperu::File.foreach(@path, max_entrys: 1) { nil } }
  end
end
