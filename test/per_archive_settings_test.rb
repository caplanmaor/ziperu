# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Every `Ziperu.*` setting can be given to one archive as a keyword; the
# globals stay as they are for everything else.
class PerArchiveSettingsTest < Minitest::Test
  include TestHelper

  def setup
    Ziperu.reset!
    @dir = Dir.mktmpdir("ziperu-settings")
    @path = File.join(@dir, "a.zip")
    Ziperu::OutputStream.open(@path) do |z|
      %w[b.txt a.txt C.txt].each { |n| z.put_next_entry(n); z.write("x" * 1000) }
    end
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@dir)
  end

  def test_limits_for_one_archive
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path, max_entries: 2) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path, max_total_size: 2999) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path, max_entry_size: 999) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path, max_compression_ratio: 2) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::File.open_buffer(File.binread(@path), max_entries: 2) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::InputStream.open(@path, max_entries: 2) { nil } }
    assert_raises(Ziperu::LimitError) { Ziperu::File.foreach(@path, max_entries: 2) { nil } }
    Ziperu::File.open(@path, max_entries: 3) { |zf| assert_equal 3, zf.size }
    Ziperu::File.open(@path) { |zf| assert_equal 3, zf.size }
    assert_nil Ziperu.max_entries
  end

  def test_a_keyword_lifts_a_global_limit
    Ziperu.max_entries = 2
    assert_raises(Ziperu::LimitError) { Ziperu::File.open(@path) { nil } }
    Ziperu::File.open(@path, max_entries: nil) { |zf| assert_equal 3, zf.size }
    Ziperu::File.open(@path, max_entries: 3) do |zf|
      zf.close
      assert_equal "x" * 1000, zf.get_entry("a.txt").get_input_stream(&:read), "reopened under its own limit"
    end
  end

  def test_sorting_and_case_for_one_archive
    Ziperu::File.open(@path, sort_entries: true) { |zf| assert_equal %w[C.txt a.txt b.txt], zf.entries.map(&:name) }
    Ziperu::File.open(@path) { |zf| assert_equal %w[b.txt a.txt C.txt], zf.entries.map(&:name) }
    Ziperu::File.open(@path, case_insensitive_match: true) { |zf| assert zf.find_entry("c.TXT") }
    Ziperu::File.open(@path) { |zf| assert_nil zf.find_entry("c.TXT") }
  end

  def test_write_settings_for_one_archive
    timed = File.join(@dir, "timed.zip")
    Ziperu::OutputStream.open(timed, write_extended_timestamps: true, source_date_epoch: 978_307_200) do |z| # 2001-01-01 UTC
      z.put_next_entry("t.txt")
      z.write("t")
    end
    Ziperu::File.open(timed) do |zf|
      e = zf.get_entry("t.txt")
      assert e.extra.member?(:universaltime)
      assert_equal 2001, e.time.year
    end
    Ziperu::File.open(@path) { |zf| refute zf.get_entry("a.txt").extra.member?(:universaltime) }

    Ziperu::File.open(@path, write_extended_timestamps: true, append_in_place: false, unicode_names: true) do |zf|
      zf.get_output_stream("new.txt") { |o| o.write "n" }
    end
    Ziperu::File.open(@path) do |zf|
      assert zf.get_entry("new.txt").extra.member?(:universaltime), "the file's settings reach the stream it commits through"
      refute_equal 0, zf.get_entry("new.txt").gp_flags & Ziperu::Entry::EFS
      assert_equal 4, zf.size
    end
  end

  def test_zip64_always_for_one_stream
    forced = File.join(@dir, "z64.zip")
    Ziperu::OutputStream.open(forced, write_zip64_support: :always) do |z|
      z.put_next_entry(Ziperu::Entry.new("", "k.txt", size: 1))
      z.write("k")
    end
    Ziperu::File.open(forced) { |zf| assert zf.get_entry("k.txt").extra.member?(:zip64) }
  end

  def test_on_exists_for_one_archive
    out = File.join(@dir, "out")
    Ziperu::File.open(@path) { |zf| zf.extract_all(out) }
    Ziperu::File.open(@path) { |zf| assert_raises(Ziperu::DestinationExistsError) { zf.extract_all(out) } }
    Ziperu::File.open(@path, on_exists_proc: true) { |zf| zf.extract_all(out) }
    Ziperu::File.open(@path, continue_on_exists_proc: true) do |zf|
      zf.add("a.txt", StringIO.new("replaced"))
      assert_equal "replaced", zf.read("a.txt")
    end
  end

  def test_an_unknown_keyword_is_an_error
    assert_raises(ArgumentError) { Ziperu::File.open(@path, max_entrys: 2) { nil } }
  end

  def test_settings_object
    Ziperu::File.open(@path, max_entries: 5) do |zf|
      assert_equal 5, zf.settings.max_entries
      assert_equal true, zf.settings.validate_entry_sizes, "the rest follow the globals"
      Ziperu.validate_entry_sizes = false
      assert_equal false, zf.settings.validate_entry_sizes
    end
    Ziperu::File.open(@path) { |zf| assert_same Ziperu, zf.settings }
  end
end
