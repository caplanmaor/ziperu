# frozen_string_literal: true

# What is left when something fails part-way: a stream, an append,
# an extraction, an IO that raises, a timeout, a second thread.
# Each test pins down a bug found in a review or testing round.

require_relative "test_helper"
require_relative "support/archive_scratch"
require "tmpdir"
require "timeout"
require "delegate"

class FailureRecoveryTest < Minitest::Test
  include TestHelper
  include ArchiveScratch

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
      Ziperu::File.open_buffer(bytes, &:entries)
    end

    io = StringIO.new
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.write_buffer(io) do |z|
        z.put_next_entry("a")
        z.write("aaa")
        raise "boom"
      end
    end
    assert_raises(Ziperu::Error) { Ziperu::File.open_buffer(io.string, &:entries) }
  end

  def test_an_archive_at_a_path_is_still_closed_on_failure_as_rubyzip_does
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(@path) do |z|
        z.put_next_entry("a")
        z.write("a")
        raise "boom"
      end
    end
    Ziperu::File.open(@path) { |zf| assert_equal %w[a], zf.entries.map(&:name) }
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
      assert_interrupted("read") { zf.read("zeros.bin") }
      # How far the native reader says it got: all the way, had the read
      # run to its end before the timeout was raised.
      reached = nil
      size = zf.get_entry("zeros.bin").size
      assert_interrupted("stream", cut_short: -> { reached < size }) do
        zf.get_input_stream("zeros.bin") do |is|
          is.read
        ensure
          reached = is.instance_variable_get(:@reader).pos
        end
      end
      # An extraction that is stopped takes its unfinished file away.
      outs = 0
      unfinished = -> { !File.exist?(File.join(@dir, "out#{outs}", "zeros.bin")) }
      assert_interrupted("extract_all", cut_short: unfinished) do
        zf.extract_all(File.join(@dir, "out#{outs += 1}"))
      end
      assert_equal "small", zf.read("small.txt"), "nothing is left locked"
    end
  end

  # Checks that Timeout stops `work` part-way through one call, not only
  # between calls. `work` is timed warm (the fastest of three runs: the
  # first pays for fresh memory), then repeated under a timeout of a fifth
  # of that, so the timeout always fires however fast the machine is. A
  # fixed timeout did not do: on a fast runner the work finished before
  # it fired.
  #
  # `cut_short`, where the work leaves evidence of having been stopped
  # part-way, is the proof. Without it the clock is: the timeout must take
  # effect well within one more call. The clock is the weaker proof, since
  # tidying up after an interrupt (closing and deleting a large unfinished
  # file, say) takes time of its own that varies with the machine.
  def assert_interrupted(label, cut_short: nil, &work)
    skip "timings mean nothing with a GC per allocation" if GC.stress
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    once = Array.new(3) do
      started = clock.call
      work.call
      clock.call - started
    end.min
    skip "#{label} took #{once}s, too quick to interrupt measurably" if once < 0.02

    limit = once / 5
    started = clock.call
    assert_raises(Timeout::Error, label) { Timeout.timeout(limit) { loop(&work) } }
    late = clock.call - started - limit
    # Valgrind runs one thread at a time, and the thread that raises the
    # timeout can wait a whole read for its turn. The interrupted paths
    # have been run for it to check; how promptly is not its business.
    return if ENV["RUBY_MEMCHECK_RUNNING"]
    return assert(cut_short.call, "#{label} is stopped part-way") if cut_short

    assert_operator late, :<, [once / 2, 3].min, "#{label} stops within a chunk of the interrupt"
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
      poker = Thread.new do
        30.times do
          sleep(0.002)
          begin
            reader.raise(poke)
          rescue StandardError
            nil
          end
        end
      end
      poker.join
      reader.join
      assert_equal data.bytesize, delivered, "the reader reached the end having handed out every byte"
    end
  end

  # A read of a whole entry goes straight into the String it returns. One
  # that is interrupted keeps that String, and the next read starts with it.
  def test_an_interrupted_read_of_a_whole_entry_loses_nothing
    data = Array.new(128) { |i| [i].pack("N") * (1 << 18) }.join
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("big.bin")
      zos << data
    end
    Ziperu::File.open(@path) do |zf|
      zf.get_input_stream("big.bin") do |is|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        is.read
        once = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        is.rewind
        begin
          Timeout.timeout(once / 5) { is.read }
          skip "the read finished before the timeout fired"
        rescue Timeout::Error
          nil
        end
        # The timeout can also land in Ruby code once the native read has
        # returned everything; the String is then the caller's loss.
        if is.instance_variable_get(:@reader).pos == data.bytesize
          skip "the timeout fired after the native read had finished"
        end
        rest = is.read
        assert_equal data.bytesize, rest.bytesize
        assert rest == data, "what was read before the interrupt comes first, then the rest"
        assert_predicate is, :eof?
      end
    end
  end

  def test_after_its_io_fails_a_stream_takes_nothing_more
    big = Random.new(6).bytes(300_000)
    (1..10).each do |k|
      sink = FailingSink.new(k)
      zos = Ziperu::OutputStream.new(sink, stream: true)
      raised = false
      [%w[first hello], ["big", big], %w[after after]].each do |name, data|
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

  def test_exceptions_from_a_ruby_io_keep_their_class_and_jumps_work
    # Not a StringIO subclass: those are read from their string directly.
    exploding = Class.new(SimpleDelegator) do
      attr_accessor :fail_with

      def read(*args)
        raise fail_with if fail_with

        __getobj__.read(*args)
      end
    end
    io = exploding.new(StringIO.new(File.binread(sample_zip)))
    Ziperu::File.open_buffer(io) do |zf|
      io.fail_with = ArgumentError.new("from the io")
      error = assert_raises(ArgumentError) { zf.read("x/y.txt") }
      assert_equal "from the io", error.message
      io.fail_with = nil
      caught = catch(:out) do
        io.define_singleton_method(:read) { |*| throw :out, :jumped }
        zf.read("x/y.txt")
        :not_jumped
      end
      assert_equal :jumped, caught
    end
  end

  def test_concurrent_use_of_one_reader_raises_instead_of_crashing
    big = File.join(@dir, "big.zip")
    Ziperu::OutputStream.open(big) do |zos|
      zos.put_next_entry("big.bin")
      zos.write(Random.new(1).bytes(1 << 20) * 8)
    end
    outcomes = Hash.new(0)
    Ziperu::InputStream.open(big) do |zis|
      zis.get_next_entry
      threads = Array.new(4) do
        Thread.new do
          20.times do
            zis.read(1 << 16)
            outcomes[:ok] += 1
          rescue ThreadError
            outcomes[:busy] += 1
          end
        end
      end
      threads.each(&:join)
    end
    assert_operator outcomes[:ok], :>, 0
  end

  def test_closing_a_stream_releases_the_file
    zis = Ziperu::InputStream.new(sample_zip)
    zis.get_next_entry
    zis.read(2)
    zis.close
    GC.disable
    File.rename(sample_zip, "#{sample_zip}.moved")
    assert File.exist?("#{sample_zip}.moved")
  ensure
    GC.enable
  end

  # Taking back "the last entry" with none added took back one the archive
  # already had, and the central directory was written over its header.
  def test_an_append_that_fails_before_adding_anything_leaves_the_archive_alone
    before = File.binread(two_entry_zip)
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(two_entry_zip, append: true) { raise "boom" }
    end

    assert_equal before, File.binread(two_entry_zip)
    Ziperu::File.open(two_entry_zip) { |zf| assert_equal "second", zf.read("b.txt") }
  end

  def test_an_append_that_fails_after_adding_an_entry_leaves_the_archive_alone
    before = File.binread(two_entry_zip)
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(two_entry_zip, append: true) do |zos|
        zos.put_next_entry("c.txt")
        zos.write("third")
        raise "boom"
      end
    end

    assert_equal before, File.binread(two_entry_zip)
  end
end
