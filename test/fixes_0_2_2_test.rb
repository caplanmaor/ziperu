# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "timeout"

# The bugs found in the testing round after 0.2.1, each as it was
# reproduced.
class Fixes022Test < Minitest::Test
  include TestHelper

  def setup
    Ziperu.reset!
    @dir = Dir.mktmpdir("ziperu-022")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@dir)
  end

  # An archive whose entries all end up named `name`: written under
  # distinct names of the same length, then renamed in place in every
  # local and central header.
  def duplicate_named(entries, name = "dup")
    bytes = Ziperu::OutputStream.write_buffer do |zos|
      entries.each_with_index do |data, i|
        zos.put_next_entry(format("%0#{name.size}d", i)[-name.size..])
        zos << data
      end
    end.string.b
    entries.each_index do |i|
      old = format("%0#{name.size}d", i)[-name.size..].b
      [[0x04034b50, 30], [0x02014b50, 46]].each do |sig, fixed|
        at = 0
        while (at = bytes.index([sig].pack("V"), at))
          len = bytes.byteslice(at + (fixed == 30 ? 26 : 28), 2).unpack1("v")
          bytes[at + fixed, len] = name.b if bytes.byteslice(at + fixed, len) == old
          at += 4
        end
      end
    end
    bytes
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

  def test_an_interrupted_read_loses_nothing
    data = Random.new(5).bytes(12_000_000)
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("big.bin")
      zos << data
    end
    poke = Class.new(StandardError)
    Ziperu::File.open(@path) do |zf|
      delivered = nil
      reader = Thread.new do
        zf.get_input_stream("big.bin") do |is|
          loop do
            break if is.read(2 * 1024 * 1024).nil?
          rescue poke
            nil
          end
          # What the native reader handed out. A poke can also land in
          # the loop's own Ruby code and drop a chunk there; that is the
          # caller's loss, not the reader's, so the chunks themselves are
          # not what is counted.
          delivered = is.instance_variable_get(:@reader).pos
        end
      rescue poke
        retry
      end
      poker = Thread.new { 30.times { sleep(0.002); reader.raise(poke) rescue nil } } # rubocop:disable Style/RescueModifier
      poker.join
      reader.join
      assert_equal data.bytesize, delivered, "the reader reached the end having handed out every byte"
    end
  end

  # A sink that raises on its `k`th write.
  class FailingSink < StringIO
    def initialize(k)
      super(+"".b)
      @k = k
      @n = 0
    end

    def write(s)
      @n += 1
      raise IOError, "sink failed at write #{@n}" if @n == @k

      super
    end
  end

  def test_after_its_io_fails_a_stream_takes_nothing_more
    big = Random.new(6).bytes(300_000)
    (1..10).each do |k|
      sink = FailingSink.new(k)
      zos = Ziperu::OutputStream.new(sink, stream: true)
      raised = false
      [["first", "hello"], ["big", big], ["after", "after"]].each do |name, data|
        zos.put_next_entry(name)
        zos << data
      rescue IOError, Ziperu::Error
        raised = true
      end
      begin
        zos.close_buffer
      rescue IOError, Ziperu::Error
        raised = true
      end
      next unless raised

      # Whatever reached the sink is never a complete-looking archive with
      # an entry corrupt in it.
      begin
        Ziperu::File.open_buffer(sink.string) { |zf| assert_empty zf.verify, "k=#{k}" }
      rescue Ziperu::Error
        nil
      end
    end
  end

  def test_a_pathname_is_a_path
    src = File.join(@dir, "src.txt")
    File.write(src, "from a pathname")
    Ziperu::File.open(@path, create: true) do |zf|
      zf.add("p.txt", Pathname(src))
      zf.add_stored("s.txt", Pathname(src))
    end
    Ziperu::File.open(@path) do |zf|
      zf.replace("p.txt", Pathname(src))
      assert_equal "from a pathname", zf.read("s.txt")
    end
    Ziperu::File.open(@path) { |zf| assert_equal "from a pathname", zf.read("p.txt") }
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
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a"); z << "a" }
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
        zos << Random.new(method).bytes(50_000) * 2
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

  def test_an_entry_kept_across_a_commit_keeps_its_metadata
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("a.txt")
      zos << "a"
      zos.put_next_entry("b.txt")
      zos << "b"
    end
    removed = nil
    Ziperu::File.open(@path) { |zf| removed = zf.remove("a.txt") }
    assert_kind_of Time, removed.time
    assert_equal 1, removed.size
  end

  def test_open_messages
    error = assert_raises(Errno::ENOENT) { Ziperu::InputStream.open(File.join(@dir, "missing.zip")) }
    assert_includes error.message, "missing.zip"
    assert_raises(TypeError) { Ziperu::File.open(nil) }
    assert_raises(TypeError) { Ziperu::File.open(5) }
  end

  def test_an_interrupted_extract_leaves_no_partial_file
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("zeros.bin")
      chunk = "\0" * (1 << 20)
      512.times { zos << chunk }
    end
    dest = File.join(@dir, "out")
    Ziperu::File.open(@path) do |zf|
      assert_raises(Timeout::Error) { Timeout.timeout(0.05) { zf.extract_all(dest) } }
      out = File.join(dest, "zeros.bin")
      # Gone, unless the timeout landed after it was finished.
      assert !File.exist?(out) || File.size(out) == 512 << 20, "no half-written file is left"
      FileUtils.rm_f(out)
      zf.extract_all(dest)
    end
    assert_equal 512 << 20, File.size(File.join(dest, "zeros.bin"))
  end

  def test_directory_times_survive_the_files_written_into_them
    when_ = Time.utc(2001, 2, 3, 4, 5, 6)
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "d/", time: when_))
      6.times do |i|
        zos.put_next_entry("d/f#{i}.txt")
        zos << "x" * 1000
      end
      zos.put_next_entry(Ziperu::Entry.new("", "late/", time: when_))
      zos.put_next_entry("late/g.txt")
      zos << "g"
    end
    stored = Ziperu::File.open(@path) { |zf| zf.get_entry("d/").time.to_i }
    [1, 4].each do |threads|
      dest = File.join(@dir, "x#{threads}")
      Ziperu::File.open(@path, threads: threads, restore_times: true) { |zf| zf.extract_all(dest, threads: threads) }
      %w[d late].each do |dir|
        assert_equal stored, File.mtime(File.join(dest, dir)).to_i, "#{dir} with #{threads} threads"
      end
    end
  end
end
