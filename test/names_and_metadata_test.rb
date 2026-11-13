# frozen_string_literal: true

# Entry names and metadata: duplicates, separators, encodings, DOS
# dates, times, and what survives a commit.
# Each test pins down a bug found in a review or testing round.

require_relative "test_helper"
require_relative "support/archive_scratch"
require "tmpdir"
require "timeout"
require "delegate"

class NamesAndMetadataTest < Minitest::Test
  include TestHelper
  include ArchiveScratch

  def test_duplicate_entry_names_are_refused_by_name
    error = assert_raises(Ziperu::EntryExistsError) do
      Ziperu::OutputStream.write_buffer do |zos|
        zos.put_next_entry("twice.txt")
        zos.write("1")
        zos.put_next_entry("twice.txt")
      end
    end
    assert_includes error.message, "twice.txt"
  end

  def test_backslashes_in_stored_names_are_normalised
    archive = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("dir\\file.txt")
      zos.write("x")
    end.string
    Ziperu::File.open_buffer(archive) do |zf|
      assert_equal "dir/file.txt", zf.entries.first.name
      assert_equal "x", zf.read("dir/file.txt")
    end
  end

  def test_names_follow_the_utf8_flag_and_lookups_take_any_encoding
    archive = Ziperu::OutputStream.write_buffer do |zos|
      entry = Ziperu::Entry.new("", "日本/ファイル.txt")
      entry.comment = "コメント"
      zos.put_next_entry(entry)
      zos.write("x")
    end.string
    Ziperu::File.open_buffer(archive) do |zf|
      entry = zf.entries.first
      assert_equal Encoding::UTF_8, entry.name.encoding
      assert_equal "日本/ファイル.txt", entry.name
      assert_equal "コメント", entry.comment
      assert_equal "x", zf.read("日本/ファイル.txt")
      assert_equal "x", zf.read("日本/ファイル.txt".b)
    end
    Ziperu.force_entry_names_encoding = "Shift_JIS"
    Ziperu::File.open_buffer(archive) do |zf|
      assert_equal Encoding::Shift_JIS, zf.entries.first.name.encoding
    end
    Ziperu.force_entry_names_encoding = nil

    # Without the flag the bytes stay binary, as in rubyzip; with the flag
    # but invalid UTF-8 they stay binary too rather than becoming a broken
    # UTF-8 string.
    flagged = archive.dup
    flagged[archive.index("PK\x01\x02".b) + 8, 2] = [0].pack("v")
    Ziperu::File.open_buffer(flagged) do |zf|
      assert_equal Encoding::BINARY, zf.entries.first.name.encoding
      assert_equal "x", zf.read("日本/ファイル.txt")
    end
    bad = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("bad\xFF\xFE.txt".b)
      zos.write("x")
    end.string
    bad[bad.index("PK\x01\x02".b) + 8, 2] = [Ziperu::Entry::EFS].pack("v")
    Ziperu::File.open_buffer(bad) do |zf|
      assert_equal Encoding::BINARY, zf.entries.first.name.encoding
      assert_equal "x", zf.read("bad\xFF\xFE.txt".b)
    end
  ensure
    Ziperu.force_entry_names_encoding = nil
  end

  # A DOS date of 2021-02-29 is what some tools write; rubyzip rolls it
  # over to March 1st rather than discarding it.
  def test_a_rollover_dos_date_is_kept
    archive = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("d.txt")
      zos.write("x")
    end.string
    date = ((2021 - 1980) << 9) | (2 << 5) | 29
    central = archive.index("PK\x01\x02".b)
    archive[central + 14, 2] = [date].pack("v")
    time = nil
    _out, err = capture_io do
      Ziperu::File.open_buffer(archive) { |zf| time = zf.entries.first.time }
    end
    assert_equal "", err
    assert_equal [2021, 3, 1], [time.year, time.month, time.day]
  end

  def test_mutators_return_the_entry
    src = File.join(@dir, "src.txt")
    File.write(src, "s")
    Ziperu::File.open(sample_zip) do |zf|
      assert_kind_of Ziperu::Entry, zf.add("s.txt", src)
      assert_kind_of Ziperu::Entry, zf.rename("s.txt", "t.txt")
      assert_kind_of Ziperu::Entry, zf.mkdir("made")
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

  def test_directory_times_survive_the_files_written_into_them
    when_ = Time.utc(2001, 2, 3, 4, 5, 6)
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry(Ziperu::Entry.new("", "d/", time: when_))
      6.times do |i|
        zos.put_next_entry("d/f#{i}.txt")
        zos << ("x" * 1000)
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

  def test_time_setter_takes_a_component_named_with_or_without_the_equals_sign
    entry = Ziperu::Entry.new("a.zip", "a.txt")
    stamp = Time.at(1_700_000_000)
    entry.send(:time=, stamp, component: :atime)
    entry.send(:time=, stamp, component: :atime=)

    assert_equal stamp.to_i, entry.atime.to_i
  end
end
