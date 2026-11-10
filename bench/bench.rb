# frozen_string_literal: true

# ziperu against rubyzip on the operations that matter in practice. Both
# gems load into one process (rubyzip as Zip, this gem as Ziperu):
#
#   ruby -I tmp/rubyzip/lib -I lib bench/bench.rb [--runs N] [--quick]
#
# or `rake bench`, which fetches rubyzip first. Each scenario runs N times
# per gem (alternating, so neither gets a warm cache the other lacks) and
# the median is reported.

require 'zip'
require 'ziperu'
require 'fileutils'
require 'optparse'
require 'stringio'
require 'tmpdir'

raise 'Zip resolved to ziperu; put rubyzip/lib before lib on the load path' if Zip.equal?(Ziperu)

options = { runs: 5, quick: false }
OptionParser.new do |o|
  o.on('--runs N', Integer) { |v| options[:runs] = v }
  o.on('--quick') { options[:quick] = true }
end.parse!

SCALE = options[:quick] ? 0.1 : 1.0
MANY = (10_000 * SCALE).to_i
SOME = (1_000 * SCALE).to_i
BIG = (64 * 1024 * 1024 * SCALE).to_i

LIBS = { 'rubyzip' => Zip, 'ziperu' => Ziperu }.freeze

def time
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

def median(values)
  sorted = values.sort
  sorted[sorted.size / 2]
end

def fmt(seconds)
  seconds >= 1 ? format('%.2f s', seconds) : format('%.0f ms', seconds * 1000)
end

# Fixtures are written once, by ziperu, into a scratch directory.
class Fixtures
  attr_reader :dir, :many_entries, :some_entries, :big_entry, :small_payload, :big_payload, :source_files

  def initialize(dir)
    @dir = dir
    @small_payload = ("The quick brown fox jumps over the lazy dog. #{'0123456789' * 3}\n" * 100).b # ~8 KB
    @big_payload = (Random.new(1).bytes(1024) * 2 + ("lorem ipsum dolor sit amet " * 100).b).b
    @big_payload *= (BIG / @big_payload.bytesize) + 1
    @big_payload = @big_payload.byteslice(0, BIG)

    @many_entries = File.join(dir, 'many.zip')
    Ziperu::OutputStream.open(@many_entries) do |zos|
      MANY.times do |i|
        zos.put_next_entry("dir#{i % 100}/file#{i}.txt", nil, nil, Ziperu::Entry::STORED)
        zos.write("entry #{i}\n")
      end
    end

    @some_entries = File.join(dir, 'some.zip')
    Ziperu::OutputStream.open(@some_entries) do |zos|
      SOME.times do |i|
        zos.put_next_entry("file#{i}.txt")
        zos.write(@small_payload)
      end
    end

    # Distinct files, so compressing them is real work on every thread.
    @source_files = Array.new(SOME) do |i|
      path = File.join(dir, "src-#{i}.txt")
      File.binwrite(path, @small_payload * 8 + i.to_s)
      path
    end

    @big_entry = File.join(dir, 'big.zip')
    Ziperu::OutputStream.open(@big_entry) do |zos|
      zos.put_next_entry('big.bin')
      zos.write(@big_payload)
    end
  end
end

SCENARIOS = {
  "open and list #{MANY} entries" => lambda do |lib, fx|
    lib::File.open(fx.many_entries) { |zf| zf.entries.size }
  end,
  "read #{SOME} x 8 KB deflated entries" => lambda do |lib, fx|
    lib::File.open(fx.some_entries) { |zf| zf.each { |e| zf.read(e) } }
  end,
  "InputStream over #{SOME} entries" => lambda do |lib, fx|
    lib::InputStream.open(fx.some_entries) do |zis|
      zis.read while zis.get_next_entry
    end
  end,
  "inflate one #{BIG / 1024 / 1024} MB entry" => lambda do |lib, fx|
    lib::File.open(fx.big_entry) { |zf| zf.read('big.bin') }
  end,
  "extract_all #{SOME} entries" => lambda do |lib, fx|
    dest = File.join(fx.dir, "extract-#{lib.name.downcase}")
    FileUtils.rm_rf(dest)
    lib::File.open(fx.some_entries) { |zf| zf.extract_all(dest) }
  end,
  "write #{SOME} x 8 KB entries (OutputStream)" => lambda do |lib, fx|
    out = File.join(fx.dir, "out-#{lib.name.downcase}.zip")
    lib::OutputStream.open(out) do |zos|
      SOME.times do |i|
        zos.put_next_entry("file#{i}.txt")
        zos.write(fx.small_payload)
      end
    end
  end,
  "deflate one #{BIG / 1024 / 1024} MB entry (OutputStream)" => lambda do |lib, fx|
    out = File.join(fx.dir, "big-#{lib.name.downcase}.zip")
    lib::OutputStream.open(out) do |zos|
      zos.put_next_entry('big.bin')
      zos.write(fx.big_payload)
    end
  end,
  "open_buffer(String) and read #{SOME} entries" => lambda do |lib, fx|
    lib::File.open_buffer(File.binread(fx.some_entries)) { |zf| zf.each { |e| zf.read(e) } }
  end,
  "Zip::File add #{SOME / 10} files and commit" => lambda do |lib, fx|
    out = File.join(fx.dir, "add-#{lib.name.downcase}.zip")
    FileUtils.rm_f(out)
    src = File.join(fx.dir, 'src.txt')
    File.binwrite(src, fx.small_payload) unless File.exist?(src)
    lib::File.open(out, create: true) do |zf|
      (SOME / 10).times { |i| zf.add("file#{i}.txt", src) }
    end
  end,
  # ziperu only: the same work on four threads, against rubyzip's one.
  "extract_all #{SOME} entries (ziperu: threads: 4)" => lambda do |lib, fx|
    dest = File.join(fx.dir, "extract4-#{lib.name.downcase}")
    FileUtils.rm_rf(dest)
    opts = lib.equal?(Ziperu) ? { threads: 4 } : {}
    lib::File.open(fx.some_entries) { |zf| zf.extract_all(dest, **opts) }
  end,
  "add #{SOME} files from disk and commit (ziperu: threads: 4)" => lambda do |lib, fx|
    out = File.join(fx.dir, "add4-#{lib.name.downcase}.zip")
    FileUtils.rm_f(out)
    srcs = fx.source_files
    opts = lib.equal?(Ziperu) ? { threads: 4 } : {}
    lib::File.open(out, create: true, **opts) do |zf|
      srcs.each_with_index { |src, i| zf.add("file#{i}.txt", src) }
    end
  end
}.freeze

Dir.mktmpdir('ziperu-bench') do |dir|
  print 'preparing fixtures... '
  fx = Fixtures.new(dir)
  puts 'done'
  puts
  puts "| scenario | rubyzip #{Zip::VERSION} | ziperu #{Ziperu::VERSION} | speedup |"
  puts '|---|---:|---:|---:|'
  SCENARIOS.each do |name, body|
    results = Hash.new { |h, k| h[k] = [] }
    options[:runs].times do
      LIBS.each { |label, lib| results[label] << time { body.call(lib, fx) } }
    end
    ours = median(results['ziperu'])
    theirs = median(results['rubyzip'])
    puts "| #{name} | #{fmt(theirs)} | #{fmt(ours)} | #{format('%.1fx', theirs / ours)} |"
  end
  puts
  puts "median of #{options[:runs]} runs; #{RUBY_DESCRIPTION}"
end
