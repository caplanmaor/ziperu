# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Byte-identical archives from the same input: SOURCE_DATE_EPOCH.
class ReproducibleTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-repro")
    @src = File.join(@dir, "src")
    FileUtils.mkdir_p(File.join(@src, "sub"))
    File.write(File.join(@src, "a.txt"), "alpha")
    File.write(File.join(@src, "sub/b.txt"), "beta")
    @epoch = Time.utc(2020, 5, 6, 7, 8, 10).to_i
  end

  def teardown
    Ziperu.source_date_epoch = nil
    FileUtils.rm_rf(@dir)
  end

  def build(path)
    Ziperu::File.add_recursive(path, @src)
    Ziperu::File.open(path) do |zf|
      zf.get_output_stream("made.txt") { |o| o.write "made" }
      zf.add("io.txt", StringIO.new("io"))
      zf.mkdir("d")
    end
    File.binread(path)
  end

  def test_the_same_input_gives_the_same_bytes_with_an_epoch
    Ziperu.source_date_epoch = @epoch
    one = build(File.join(@dir, "one.zip"))
    sleep 2.1 # past the DOS time's 2-second resolution
    FileUtils.touch(Dir.glob(File.join(@src, "**", "*")), mtime: Time.now)
    two = build(File.join(@dir, "two.zip"))
    assert_equal one, two
    Ziperu::File.open_buffer(one) do |zf|
      assert_equal %w[a.txt sub/ sub/b.txt made.txt io.txt d/], zf.entries.map(&:name)
      zf.entries.each do |e|
        assert_equal Time.at(@epoch).utc.to_a[0, 6], e.time.to_a[0, 6], e.name
        assert_equal Ziperu::FSTYPE_UNIX, e.fstype, e.name
      end
    end
  end

  def test_an_earlier_mtime_wins_over_the_epoch
    Ziperu.source_date_epoch = @epoch
    old = Time.utc(2001, 2, 3, 4, 5, 6)
    FileUtils.touch(File.join(@src, "a.txt"), mtime: old)
    zip = File.join(@dir, "old.zip")
    Ziperu::File.add_recursive(zip, @src)
    Ziperu::File.open(zip) do |zf|
      assert_equal old.to_a[0, 6], zf.get_entry("a.txt").time.to_a[0, 6]
      assert_equal Time.at(@epoch).utc.to_a[0, 6], zf.get_entry("sub/b.txt").time.to_a[0, 6]
    end
  end

  def test_without_an_epoch_the_clock_and_the_mtime_are_used
    zip = File.join(@dir, "clock.zip")
    old = Time.utc(2001, 2, 3, 4, 5, 6)
    FileUtils.touch(File.join(@src, "a.txt"), mtime: old)
    Ziperu::File.add_recursive(zip, @src)
    Ziperu::File.open(zip) do |zf|
      # The DOS time keeps the local wall clock, as rubyzip has it.
      assert_equal old.localtime.to_a[0, 6], zf.get_entry("a.txt").time.to_a[0, 6]
      assert_in_delta Time.now.to_i, Ziperu::Entry.new("", "x").time.to_i, 5
    end
  end

  def test_the_variable_is_read_at_load
    out = `#{Gem.ruby} -Ilib -e "ENV['SOURCE_DATE_EPOCH'] = '#{@epoch}'; require 'ziperu'; puts Ziperu.source_date_epoch"`
    assert_equal @epoch.to_s, out.strip
  end
end
