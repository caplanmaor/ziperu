# frozen_string_literal: true

# Differential fuzzing of ziperu against Python's zipfile (and rubyzip, when
# `rake compat:fetch` has put a checkout in tmp/rubyzip):
#
#   ruby fuzz/differential.rb [--seed N] [--iterations N] [--time SECONDS]
#
# Every iteration draws a random archive spec and runs one of four cases:
#
#   read     the oracle writes the archive, ziperu reads it every way it can
#   write    ziperu writes the archive, the oracles read it back
#   modify   ziperu opens an oracle-written archive, mutates it through the
#            Zip::File API and commits; the oracles check the result
#   mutate   an archive's bytes are corrupted; ziperu must fail with one of
#            its own error classes and agree with the oracle on whatever
#            both still accept
#
# A failing case is saved under tmp/fuzz/failures/ with its spec, and the
# run exits non-zero. Reproduce one with the printed --seed.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ziperu'
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

module Fuzz
  ROOT = File.expand_path('..', __dir__)
  OUT = File.join(ROOT, 'tmp', 'fuzz')

  # Errors ziperu is allowed to raise on hostile input. Anything else (a
  # NoMethodError, a TypeError, a RangeError) is a bug.
  ACCEPTABLE = [Ziperu::Error, IOError, SystemCallError, Zlib::Error].freeze

  class Failure < StandardError; end

  # Runs an oracle script in a subprocess, talking through files.
  class Oracle
    attr_reader :name

    def initialize(name, command, dir)
      @name = name
      @command = command
      @dir = dir
    end

    def write(spec)
      spec_path = File.join(@dir, "#{name}-spec.json")
      out = File.join(@dir, "#{name}-out.zip")
      File.write(spec_path, JSON.generate(spec))
      run('write', spec_path, out)
      File.binread(out)
    end

    def read(bytes, password: nil, encryption: nil)
      zip = File.join(@dir, "#{name}-in.zip")
      out = File.join(@dir, "#{name}-read.json")
      File.binwrite(zip, bytes)
      extra = password ? [password, encryption.to_s] : []
      run('read', zip, out, *extra)
      JSON.parse(File.read(out))
    end

    private

    def run(*args)
      stdout, stderr, status = Open3.capture3(*@command, *args)
      return if status.success?

      raise Failure, "#{name} oracle failed: #{stderr}#{stdout}"
    end
  end

  # Draws archive specs from a seeded RNG.
  class Generator
    WORDS = %w[readme notes data image index main lib src test build alpha beta].freeze
    EXTS = %w[.txt .bin .json .rb .md .dat].freeze
    UNICODE = ['日本語', 'файл', 'résumé', 'emoji🎉', 'Ünïcödé', '中文目录'].freeze
    METHODS = %w[stored deflated deflated deflated].freeze

    attr_reader :rng

    def initialize(rng)
      @rng = rng
    end

    def chance(probability)
      rng.rand < probability
    end

    def name(depth: rng.rand(3))
      parts = Array.new(depth) { segment }
      parts << "#{segment}#{EXTS.sample(random: rng)}"
      parts.join('/')
    end

    def segment
      case rng.rand(10)
      when 0 then UNICODE.sample(random: rng)
      when 1 then "#{WORDS.sample(random: rng)} #{rng.rand(100)}"
      when 2 then WORDS.sample(random: rng) * rng.rand(2..12)
      else WORDS.sample(random: rng)
      end
    end

    def data
      case rng.rand(10)
      when 0 then ''.b
      when 1, 2 then rng.bytes(rng.rand(1..64))
      when 3, 4 then (WORDS.sample(random: rng) * rng.rand(1..2000)).b
      when 5 then rng.bytes(rng.rand(1..300_000))
      when 6 then ("line #{rng.rand(1000)}\n" * rng.rand(1..20_000)).b
      when 7 then (rng.bytes(64) * rng.rand(1..4000)).b
      else rng.bytes(rng.rand(1..4096))
      end
    end

    def mtime
      [rng.rand(1980..2099), rng.rand(1..12), rng.rand(1..28), rng.rand(0..23), rng.rand(0..59), rng.rand(0..29) * 2]
    end

    def spec(count: rng.rand(1..8), bzip2: true, streaming: true, zip64: true)
      used = {}
      entries = []
      count.times do
        n = name
        next if used[n] || used["#{n}/"]

        if chance(0.15)
          used["#{n}/"] = true
          entries << { 'name' => "#{n}/", 'dir' => true, 'mtime' => mtime, 'comment' => chance(0.2) ? segment : '' }
        else
          used[n] = true
          method = METHODS.sample(random: rng)
          method = 'bzip2' if bzip2 && chance(0.1)
          entries << { 'name' => n, 'data' => Base64.strict_encode64(data), 'method' => method,
                       'mtime' => mtime, 'comment' => chance(0.2) ? segment : '' }
        end
      end
      entries << { 'name' => name, 'data' => Base64.strict_encode64(data), 'method' => 'deflated', 'mtime' => mtime, 'comment' => '' } if entries.empty?
      {
        'entries' => entries,
        'comment' => chance(0.3) ? "#{segment} #{rng.rand(1000)}" : '',
        'level' => chance(0.5) ? rng.rand(0..9) : nil,
        'streaming' => streaming && chance(0.25),
        'zip64' => zip64 && chance(0.1)
      }
    end

    # Corrupts `bytes` in 1-4 random ways and describes what it did.
    def mutate(bytes)
      bytes = bytes.dup
      log = []
      [1, 1, 1, 2, 3, 4].sample(random: rng).times do
        break if bytes.empty?

        case rng.rand(7)
        when 0
          i = rng.rand(bytes.bytesize)
          bytes.setbyte(i, bytes.getbyte(i) ^ (1 << rng.rand(8)))
          log << "flip bit at #{i}"
        when 1
          at = rng.rand(bytes.bytesize)
          bytes = bytes.byteslice(0, at)
          log << "truncate to #{at}"
        when 2
          at = rng.rand(bytes.bytesize)
          len = [rng.rand(1..64), bytes.bytesize - at].min
          bytes[at, len] = "\0".b * len
          log << "zero #{len} bytes at #{at}"
        when 3
          at = rng.rand(bytes.bytesize)
          bytes[at, 4] = [rng.rand(2**32)].pack('V') if at + 4 <= bytes.bytesize
          log << "random u32 at #{at}"
        when 4
          at = rng.rand(bytes.bytesize)
          len = rng.rand(1..256)
          chunk = bytes.byteslice(at, len)
          bytes = bytes.byteslice(0, at) + chunk + chunk + bytes.byteslice(at + len..).to_s
          log << "duplicate #{len} bytes at #{at}"
        when 5
          # Aim at a header field: signatures are easy to find.
          sig = [0x04034b50, 0x02014b50, 0x06054b50, 0x06064b50].sample(random: rng)
          idx = bytes.index([sig].pack('V'))
          if idx
            at = idx + rng.rand(4..30)
            if at + 2 <= bytes.bytesize
              bytes[at, 2] = [rng.rand(2**16)].pack('v')
              log << "random u16 at #{at} (after signature #{sig.to_s(16)})"
            end
          end
        when 6
          at = rng.rand(bytes.bytesize)
          len = rng.rand(1..128)
          bytes = bytes.byteslice(0, at) + bytes.byteslice(at + len..).to_s
          log << "delete #{len} bytes at #{at}"
        end
      end
      [bytes, log]
    end
  end

  class Runner
    attr_reader :stats

    CASES = %i[read write modify mutate].freeze

    def initialize(seed:, python:, rubyzip_lib:, dir:)
      @seed = seed
      @rng = Random.new(seed)
      @gen = Generator.new(@rng)
      @dir = dir
      @python = Oracle.new('python', [*python, '-I', File.join(ROOT, 'fuzz', 'oracle.py')], dir)
      @rubyzip = rubyzip_lib && Oracle.new('rubyzip', [RbConfig.ruby, '-I', rubyzip_lib, File.join(ROOT, 'fuzz', 'rubyzip_oracle.rb')], dir)
      @stats = Hash.new(0)
      @failures = []
      @corpus = []
    end

    def run_one(iteration, only: nil)
      kind = only || (iteration < 4 ? CASES[iteration] : CASES.sample(random: @rng))
      kind = :read if kind == :mutate && @corpus.empty?
      send("case_#{kind}")
      @stats[kind] += 1
    rescue StandardError => e
      record_failure(iteration, kind, e)
    end

    def failures?
      !@failures.empty?
    end

    # ---- cases ---------------------------------------------------------

    def case_read
      if @rubyzip && @gen.chance(0.25)
        spec = @gen.spec(bzip2: false, streaming: false, zip64: false)
        if @gen.chance(0.6)
          spec['password'] = "pw#{@rng.rand(1000)}"
          spec['encryption'] = @gen.chance(0.5) ? 'aes' : 'traditional'
        end
        bytes = @rubyzip.write(spec)
      else
        spec = @gen.spec
        bytes = @python.write(spec)
      end
      @current = { 'case' => 'read', 'spec' => spec }
      expected = model_from_spec(spec)
      # rubyzip writes AES entries as AE-2, whose header CRC is zero by design.
      check_ziperu_reads(bytes, expected, spec['comment'], decrypter: decrypter_for(spec), crc: spec['encryption'] != 'aes')
      remember(bytes)
    end

    def case_write
      spec = @gen.spec(bzip2: false, streaming: false, zip64: false)
      @current = { 'case' => 'write', 'spec' => spec }
      path = File.join(@dir, 'ziperu-out.zip')
      File.delete(path) if File.exist?(path)
      use_buffer = @gen.chance(0.3)
      writer = lambda do |zos|
        zos.comment = spec['comment'] unless spec['comment'].empty?
        spec['entries'].each do |e|
          method = e['method'] == 'stored' ? Ziperu::Entry::STORED : Ziperu::Entry::DEFLATED
          level = spec['level'] || Zlib::DEFAULT_COMPRESSION
          entry = Ziperu::Entry.new('', e['name'], comment: e['comment'], compression_method: method)
          entry.time = Ziperu::DOSTime.new(*e['mtime'])
          zos.put_next_entry(entry, nil, nil, method, level)
          zos.write(Base64.decode64(e['data'])) unless e['dir']
        end
      end
      bytes = if use_buffer
                Ziperu::OutputStream.write_buffer(&writer).string
              else
                Ziperu::OutputStream.open(path, &writer)
                File.binread(path)
              end
      expected = model_from_spec(spec)
      check_oracles_read(bytes, expected, spec['comment'])
      check_ziperu_reads(bytes, expected, spec['comment'])
      remember(bytes)
    end

    def case_modify
      spec = @gen.spec(zip64: false)
      bytes = @python.write(spec)
      expected = model_from_spec(spec)
      ops = []
      @current = { 'case' => 'modify', 'spec' => spec, 'ops' => ops }
      path = File.join(@dir, 'ziperu-modify.zip')
      File.binwrite(path, bytes)
      comment = spec['comment']
      # add/replace read their source when the archive is committed, so
      # each op needs its own file.
      sources = 0
      src = -> { File.join(@dir, "src#{sources += 1}.bin") }
      # The model is keyed by name bytes; the API takes UTF-8 names.
      utf8 = ->(name) { name.dup.force_encoding(Encoding::UTF_8) }
      Ziperu::File.open(path) do |zf|
        @rng.rand(1..6).times do
          names = expected.keys.map(&utf8)
          files = names.reject { |k| expected[k.b]['dir'] }
          case @rng.rand(7)
          when 0
            n = fresh_name(expected)
            d = @gen.data
            zf.get_output_stream(n) { |os| os.write(d) }
            expected[n.b] = { 'data' => d, 'dir' => false }
            ops << "get_output_stream #{n} (#{d.bytesize} bytes)"
          when 1
            n = names.sample(random: @rng)
            zf.remove(n)
            expected.delete(n.b)
            ops << "remove #{n}"
          when 2
            n = files.sample(random: @rng) or next
            new_name = fresh_name(expected)
            zf.rename(n, new_name)
            expected[new_name.b] = expected.delete(n.b)
            ops << "rename #{n} -> #{new_name}"
          when 3
            n = files.sample(random: @rng) or next
            d = @gen.data
            src_path = src.call
            File.binwrite(src_path, d)
            zf.replace(n, src_path)
            expected[n.b]['data'] = d
            ops << "replace #{n} (#{d.bytesize} bytes)"
          when 4
            n = fresh_name(expected)
            d = @gen.data
            src_path = src.call
            File.binwrite(src_path, d)
            zf.add(n, src_path)
            expected[n.b] = { 'data' => d, 'dir' => false }
            ops << "add #{n} (#{d.bytesize} bytes)"
          when 5
            n = "#{@gen.segment}#{@rng.rand(1000)}"
            next if expected.key?("#{n}/".b) || expected.key?(n.b)

            zf.mkdir(n)
            expected["#{n}/".b] = { 'data' => ''.b, 'dir' => true }
            ops << "mkdir #{n}"
          when 6
            comment = "changed #{@rng.rand(1000)}"
            zf.comment = comment
            ops << "comment= #{comment}"
          end
        end
      end
      result = File.binread(path)
      # rubyzip cannot read the bzip2 entries python wrote and ziperu raw-copied.
      rubyzip = spec['entries'].none? { |e| e['method'] == 'bzip2' }
      check_oracles_read(result, expected, comment, rubyzip: rubyzip)
      check_ziperu_reads(result, expected, comment)
      remember(result)
    end

    def case_mutate
      original = @corpus.sample(random: @rng)
      bytes, log = @gen.mutate(original)
      @current = { 'case' => 'mutate', 'mutations' => log, 'original_sha' => Digest::SHA256.hexdigest(original) }
      ours = ziperu_read_leniently(bytes)
      theirs = @python.read(bytes)
      @stats[ours[:open_error] ? :mutate_rejected : :mutate_accepted] += 1
      @stats[:mutate_acceptance_differs] += 1 if ours[:open_error].nil? != theirs['ok']
      return unless theirs['ok']

      theirs['entries'].each do |t|
        o = ours[:entries][t['name'].b] or next
        next unless o[:data] && t['data']

        oracle = Base64.decode64(t['data'])
        next if o[:data] == oracle

        raise Failure, "entry #{t['name'].inspect}: ziperu and python both read it but the bytes differ " \
                       "(#{o[:data].bytesize} vs #{oracle.bytesize})"
      end
    end

    # ---- checks --------------------------------------------------------

    # Ziperu::File, InputStream, open_buffer and extract_all all agree
    # with the model.
    def check_ziperu_reads(bytes, expected, comment, decrypter: nil, crc: true)
      path = File.join(@dir, 'ziperu-in.zip')
      File.binwrite(path, bytes)
      opts = decrypter ? { decrypter: decrypter } : {}

      Ziperu::File.open(path) do |zf|
        compare_comment(zf.comment, comment, 'Ziperu::File')
        compare_names(zf.entries.map { |e| e.name.b }, expected.keys, 'Ziperu::File')
        zf.entries.each do |entry|
          want = expected.fetch(entry.name.b)
          assert_eq(entry.directory?, want['dir'], "#{entry.name}: directory?")
          next if want['dir']

          assert_eq(entry.size, want['data'].bytesize, "#{entry.name}: size")
          assert_eq(entry.crc, Zlib.crc32(want['data']), "#{entry.name}: crc") if crc
          assert_eq(zf.read(entry).b, want['data'], "#{entry.name}: Ziperu::File#read") unless decrypter
          assert_eq(entry.get_input_stream(**opts, &:read).to_s.b, want['data'], "#{entry.name}: get_input_stream")
        end
      end

      seen = []
      Ziperu::InputStream.open(path, **opts) do |zis|
        while (entry = zis.get_next_entry)
          seen << entry.name.b
          next if entry.directory?

          assert_eq(zis.read.to_s.b, expected.fetch(entry.name.b)['data'], "#{entry.name}: InputStream#read")
        end
      end
      compare_names(seen, expected.keys, 'Ziperu::InputStream')

      Ziperu::File.open_buffer(bytes.dup) do |zf|
        zf.entries.each do |entry|
          next if entry.directory?

          assert_eq(entry.get_input_stream(**opts, &:read).to_s.b, expected.fetch(entry.name.b)['data'], "#{entry.name}: open_buffer read")
        end
      end

      return if decrypter # extract has no decrypter argument in rubyzip's API

      dest = File.join(@dir, 'extracted')
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      Ziperu::File.open(path) { |zf| zf.extract_all(dest) }
      expected.each do |name, want|
        on_disk = File.join(dest, name)
        if want['dir']
          raise Failure, "#{name}: directory not extracted" unless File.directory?(on_disk)
        else
          raise Failure, "#{name}: not extracted" unless File.file?(on_disk)

          assert_eq(File.binread(on_disk), want['data'], "#{name}: extracted bytes")
        end
      end
    end

    def check_oracles_read(bytes, expected, comment, rubyzip: true)
      [@python, rubyzip ? @rubyzip : nil].compact.each do |oracle|
        result = oracle.read(bytes)
        raise Failure, "#{oracle.name} cannot open what ziperu wrote: #{result['error']}" unless result['ok']

        compare_comment(result['comment'], comment, oracle.name)
        compare_names(result['entries'].map { |e| e['name'].b }, expected.keys, oracle.name)
        result['entries'].each do |e|
          want = expected.fetch(e['name'].b)
          assert_eq(e['dir'], want['dir'], "#{oracle.name}: #{e['name']} directory?")
          next if want['dir']

          raise Failure, "#{oracle.name} cannot read #{e['name']}: #{e['error']}" if e['error']

          assert_eq(Base64.decode64(e['data']), want['data'], "#{oracle.name}: #{e['name']} bytes")
          assert_eq(e['crc'], Zlib.crc32(want['data']), "#{oracle.name}: #{e['name']} crc")
        end
      end
    end

    def ziperu_read_leniently(bytes)
      out = { entries: {} }
      begin
        Ziperu::File.open_buffer(bytes.dup) do |zf|
          zf.entries.each do |entry|
            record = {}
            begin
              record[:data] = entry.directory? ? ''.b : zf.read(entry).b
            rescue *ACCEPTABLE => e
              record[:error] = e
            end
            out[:entries][entry.name.b] = record
          end
        end
        path = File.join(@dir, 'ziperu-mut.zip')
        File.binwrite(path, bytes)
        Ziperu::InputStream.open(path) do |zis|
          zis.read while zis.get_next_entry
        end
      rescue *ACCEPTABLE => e
        out[:open_error] = e
      end
      out
    end

    # ---- helpers -------------------------------------------------------

    def decrypter_for(spec)
      password = spec['password'] or return nil

      if spec['encryption'] == 'aes'
        Ziperu::AESDecrypter.new(password, Ziperu::AESEncryption::STRENGTH_256_BIT)
      else
        Ziperu::TraditionalDecrypter.new(password)
      end
    end

    def model_from_spec(spec)
      spec['entries'].to_h do |e|
        [e['name'].b, { 'data' => e['dir'] ? ''.b : Base64.decode64(e['data']), 'dir' => e['dir'] ? true : false }]
      end
    end

    def fresh_name(expected)
      loop do
        n = @gen.name
        return n unless expected.key?(n.b) || expected.key?("#{n}/".b)
      end
    end

    def compare_names(got, want, who)
      return if got.sort == want.sort

      raise Failure, "#{who}: entry names differ\n  got:  #{got.sort.inspect}\n  want: #{want.sort.inspect}"
    end

    def compare_comment(got, want, who)
      assert_eq(got.to_s.b, want.to_s.b, "#{who}: archive comment")
    end

    def assert_eq(got, want, what)
      return if got == want

      raise Failure, "#{what}: got #{describe(got)}, want #{describe(want)}"
    end

    def describe(value)
      return value.inspect unless value.is_a?(String) && value.bytesize > 80

      "#{value.bytesize} bytes, sha #{Digest::SHA256.hexdigest(value)[0, 12]}"
    end

    def remember(bytes)
      @corpus << bytes
      @corpus.shift if @corpus.size > 64
    end

    def record_failure(iteration, kind, error)
      @failures << [iteration, kind, error]
      dir = File.join(OUT, 'failures')
      FileUtils.mkdir_p(dir)
      base = File.join(dir, "seed#{@seed}-iter#{iteration}-#{kind}")
      %w[ziperu-in.zip ziperu-out.zip ziperu-modify.zip ziperu-mut.zip python-out.zip rubyzip-out.zip].each do |f|
        src = File.join(@dir, f)
        FileUtils.cp(src, "#{base}-#{f}") if File.exist?(src)
      end
      File.write("#{base}.json", JSON.pretty_generate((@current || {}).merge(
        'error' => "#{error.class}: #{error.message}".dup.force_encoding(Encoding::UTF_8).scrub,
        'backtrace' => error.backtrace&.first(8)
      )))
      warn "FAIL iteration #{iteration} (#{kind}): #{error.class}: #{error.message.lines.first&.chomp}"
      warn "     saved to #{base}.*; rerun with --seed #{@seed} --iterations #{iteration + 1}"
    end
  end

  def self.find_python
    [ENV['PYTHON'], 'python3', 'python'].compact.each do |candidate|
      out, status = Open3.capture2e(candidate, '-c', 'import zipfile, sys; print(sys.version_info[:2])')
      return [candidate] if status.success? && out.include?('(3')
    rescue Errno::ENOENT
      next
    end
    abort 'python 3 is needed as the oracle (set PYTHON=...)'
  end

  def self.main(argv)
    options = { seed: Random.new_seed % (2**31), iterations: nil, time: nil, only: nil }
    OptionParser.new do |o|
      o.on('--seed N', Integer) { |v| options[:seed] = v }
      o.on('--iterations N', Integer) { |v| options[:iterations] = v }
      o.on('--time SECONDS', Float) { |v| options[:time] = v }
      o.on('--only CASE', %w[read write modify mutate]) { |v| options[:only] = v.to_sym }
    end.parse!(argv)
    options[:iterations] ||= 200 unless options[:time]

    rubyzip_lib = ENV['RUBYZIP_LIB'] || File.join(ROOT, 'tmp', 'rubyzip', 'lib')
    rubyzip_lib = nil unless File.exist?(File.join(rubyzip_lib, 'zip.rb'))
    puts "seed #{options[:seed]}; oracles: python#{rubyzip_lib ? ', rubyzip' : ''}"

    FileUtils.mkdir_p(OUT)
    Dir.mktmpdir('ziperu-fuzz', OUT) do |dir|
      runner = Runner.new(seed: options[:seed], python: find_python, rubyzip_lib: rubyzip_lib, dir: dir)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      i = 0
      loop do
        break if options[:iterations] && i >= options[:iterations]
        break if options[:time] && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > options[:time]

        runner.run_one(i, only: options[:only])
        i += 1
        $stderr.print '.' if (i % 10).zero?
      end
      $stderr.puts
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "#{i} iterations in #{elapsed.round(1)}s: #{runner.stats.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
      if runner.failures?
        puts 'FAILED'
        exit 1
      end
      puts 'ok'
    end
  end
end

Fuzz.main(ARGV) if $PROGRAM_NAME == __FILE__
