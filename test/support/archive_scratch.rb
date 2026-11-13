# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A scratch directory per test, with the settings reset around it: `@dir`,
# and `@path` for an archive not yet written. `sample_zip` and
# `two_entry_zip` write small archives there on first use.
module ArchiveScratch
  def setup
    Ziperu.reset!
    @dir = Dir.mktmpdir("ziperu")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@dir)
  end

  # `x/y.txt` holding two lines, and the directory `dir/`.
  def sample_zip
    @sample_zip ||= write_scratch("sample.zip") do |zos|
      zos.put_next_entry("x/y.txt")
      zos.write("hello\nworld\n")
      zos.put_next_entry("dir/")
    end
  end

  # `a.txt` ("first") and `b.txt` ("second").
  def two_entry_zip
    @two_entry_zip ||= write_scratch("two.zip") do |zos|
      zos.put_next_entry("a.txt")
      zos.write("first")
      zos.put_next_entry("b.txt")
      zos.write("second")
    end
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

  private

  def write_scratch(name, &block)
    path = File.join(@dir, name)
    Ziperu::OutputStream.open(path, &block)
    path
  end
end
