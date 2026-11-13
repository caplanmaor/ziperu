# frozen_string_literal: true

# Loops a workload that crosses the native boundary every way the gem
# offers, sampling the process's resident size, and fails if it keeps
# growing once warmed up. A leak in the Rust core (a Box never freed, a
# Ruby value never released) shows as a slope; the GC's own churn does
# not, since the sample is taken after a full collection.
#
#   ruby -Ilib test/mem/growth.rb            # ITERATIONS=200 by default
#   ITERATIONS=1000 ruby -Ilib test/mem/growth.rb

require "ziperu"
require "tmpdir"
require "stringio"
require "fileutils"

ITERATIONS = Integer(ENV.fetch("ITERATIONS", 200))
# Growth tolerated between the middle and the last samples, in MiB: the
# heap fragments a little, and the first samples include lazily loaded
# code and buffers. Medians, not single samples, because RSS after a GC
# still jumps by 10-20 MiB from one sample to the next.
ALLOWED_MIB = Float(ENV.fetch("ALLOWED_MIB", 8))

def rss_mib
  if File.readable?("/proc/self/statm")
    pages = File.read("/proc/self/statm").split[1].to_i
    pages * 4096 / 1024.0 / 1024
  elsif RUBY_PLATFORM.include?("darwin") || RUBY_PLATFORM.include?("bsd")
    `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
  else
    `powershell -NoProfile -Command "(Get-Process -Id #{Process.pid}).WorkingSet64"`.to_i / 1024.0 / 1024
  end
end

Dir.mktmpdir("ziperu-growth") do |dir|
  zip = File.join(dir, "a.zip")
  src = File.join(dir, "src")
  FileUtils.mkdir_p(src)
  20.times { |i| File.binwrite(File.join(src, "f#{i}.bin"), Random.new(i).bytes(30_000)) }
  big = Random.new(99).bytes(2 * 1024 * 1024)

  workload = lambda do |i|
    # Write: files from disk (sequential and parallel), data, a directory,
    # AES, ZipCrypto, then append in place.
    Ziperu::OutputStream.open(zip, encrypter: Ziperu::AESEncrypter.new("pw")) do |z|
      z.put_next_entry("secret.txt")
      z.write("secret #{i}")
    end
    Ziperu::File.open(zip, threads: 2) do |zf|
      10.times { |k| zf.add("in/f#{k}.bin", File.join(src, "f#{k}.bin")) }
      zf.mkdir("d")
      zf.get_output_stream("big.bin") { |o| o.write(big) }
    end
    zc = StringIO.new
    Ziperu::OutputStream.write_buffer(zc, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("zc.txt")
      z.write("zipcrypto")
    end
    # Read: list, read, verify, foreach, InputStream, open_buffer, a stream
    # to a write-only IO, extract on threads, a raw copy.
    Ziperu::File.open(zip, password: "pw") do |zf|
      zf.entries.each do |e|
        e.time
        e.extra
      end
      zf.read("in/f3.bin")
      zf.read("secret.txt")
      zf.read("big.bin")
      zf.verify
      out = File.join(dir, "out")
      FileUtils.rm_rf(out)
      zf.extract_all(out, threads: 2)
    end
    Ziperu::File.foreach(zip, &:name)
    Ziperu::InputStream.open(zip, password: "pw") { |is| is.read while is.get_next_entry }
    Ziperu::File.open_buffer(File.binread(zip)) { |zf| zf.read("in/f1.bin") }
    Ziperu::File.open_buffer(zc.string, password: "pw") { |zf| zf.read("zc.txt") }
    sink = Object.new
    def sink.write(d) = d.bytesize
    Ziperu::File.open(zip) do |zf|
      Ziperu::OutputStream.write_buffer(sink) do |zos|
        zos.copy_raw_entry(zf.get_entry("in/f2.bin"))
        zos.put_next_entry("x")
        zos.write("x")
      end
    end
    Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("b")
      zos.write("b")
    end.each { |_| }
  end

  samples = []
  ITERATIONS.times do |i|
    workload.call(i)
    next unless (i % 20).zero?

    GC.start(full_mark: true, immediate_sweep: true)
    samples << rss_mib.round(1)
    puts format("iteration %4d: rss %7.1f MiB", i, samples.last)
  end
  # The first third is warm-up: the allocator keeps taking memory for a
  # while before it settles, and on a busy CI machine that can run well
  # past the first few samples (one run rose from 74 to 103 MiB and came
  # back to 89). A leak grows steadily, so it shows as the middle third's
  # median against the last third's; a plateau does not.
  median = ->(xs) { xs.sort[xs.size / 2] }
  third = [samples.size / 3, 1].max
  middle = samples[third, third]
  last = samples.last(third)
  growth = median.call(last) - median.call(middle)
  puts format("growth (last third - middle third, medians): %.1f MiB over %d iterations (allowed %.1f)",
              growth, ITERATIONS, ALLOWED_MIB)
  abort "memory keeps growing" if growth > ALLOWED_MIB
end
