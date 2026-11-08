# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

# An archive holding several records under one name. Python's zipfile
# writes one with a warning:
#
#   z.writestr("dup.txt", b"first"); z.writestr("dup.txt", b"second")
#   z.writestr("other.txt", b"third")
#
# rubyzip's InputStream walks every local header and so yields every
# record; the zip crate keys its central directory by name and keeps only
# the last. Every record is listed and readable here, and a lookup by name
# finds the last, as rubyzip's does.
class DuplicateNamesTest < Minitest::Test
  include TestHelper

  FIXTURE = "dup_names.zip"
  NAMES = %w[dup.txt dup.txt other.txt].freeze
  CONTENTS = %w[first second third].freeze

  def test_file_lists_every_record_in_order
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      assert_equal(3, zf.size)
      assert_equal(NAMES, zf.entries.map(&:name))
      assert_equal(NAMES, zf.map(&:name))
      assert_equal([false, true, true], zf.entries.map { |e| !e.index.nil? })
    end
  end

  def test_each_record_reads_its_own_data
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      assert_equal(CONTENTS, zf.entries.map { |e| e.get_input_stream(&:read) })
      # A lookup by name (even of an Entry) finds the last record, as in rubyzip.
      assert_equal("second", zf.get_input_stream(zf.entries[0], &:read))
      assert_equal(CONTENTS, zf.entries.map(&:get_raw_input_string))
      assert_equal(CONTENTS, zf.entries.map { |e| e.get_input_stream(&:read) }) # again, re-opened
    end
  end

  def test_lookup_by_name_finds_the_last_record
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      assert_equal("second", zf.read("dup.txt"))
      assert_same(zf.entries[1], zf.find_entry("dup.txt"))
      assert_equal("third", zf.read("other.txt"))
    end
  end

  def test_input_stream_yields_every_record
    seen = []
    Ziperu::InputStream.open(fixture(FIXTURE)) do |zis|
      while (entry = zis.get_next_entry)
        seen << [entry.name, zis.read]
      end
    end
    assert_equal(NAMES.zip(CONTENTS), seen)
  end

  def test_input_stream_from_an_offset
    offset = Ziperu::File.open(fixture(FIXTURE)) { |zf| zf.entries[1].local_header_offset }
    Ziperu::InputStream.open(fixture(FIXTURE), offset: offset) do |zis|
      assert_equal("dup.txt", zis.get_next_entry.name)
      assert_equal("second", zis.read)
      assert_equal("other.txt", zis.get_next_entry.name)
      assert_nil(zis.get_next_entry)
    end
  end

  def test_stream_over_a_record_without_index_rewinds_and_sizes
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      first = zf.entries[0]
      assert_nil(first.index)
      first.get_input_stream do |is|
        assert_equal(5, is.size)
        assert_equal("fi", is.read(2))
        is.rewind
        assert_equal("first", is.read)
        assert(is.eof?)
      end
      # The local header's extra field is merged in by offset.
      assert_kind_of(Ziperu::ExtraField, first.extra)
    end
  end

  def test_extract_each_record
    Dir.mktmpdir do |dir|
      Ziperu::File.open(fixture(FIXTURE)) do |zf|
        zf.entries[0].extract("a.txt", destination_directory: dir)
        zf.entries[1].extract("b.txt", destination_directory: dir)
        zf.extract_all(dir)
      end
      assert_equal("first", File.read(File.join(dir, "a.txt")))
      assert_equal("second", File.read(File.join(dir, "b.txt")))
      # extract_all writes the last record of a name, as rubyzip would.
      assert_equal("second", File.read(File.join(dir, "dup.txt")))
      assert_equal("third", File.read(File.join(dir, "other.txt")))
    end
  end

  def test_verify_is_clean
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      assert_empty(zf.verify)
    end
  end

  def test_verify_reports_a_corrupt_shadowed_record
    bytes = File.binread(fixture(FIXTURE))
    offset = Ziperu::File.open(fixture(FIXTURE)) { |zf| zf.entries[0].local_header_offset }
    # The first record's compressed data follows its 30-byte local header
    # and 7-byte name; flip a byte of it.
    data_at = offset + 30 + 7
    bytes.setbyte(data_at, bytes.getbyte(data_at) ^ 0xFF)
    zf = Ziperu::File.new(StringIO.new(bytes), buffer: true)
    failures = zf.verify
    assert_equal(["dup.txt"], failures.keys.map(&:name))
    assert_same(zf.entries[0], failures.keys.first)
    assert_equal("second", zf.read("dup.txt"))
  end

  def test_commit_with_a_rename_keeps_the_last_of_a_name
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dup.zip")
      FileUtils.cp(fixture(FIXTURE), path)
      Ziperu::File.open(path) do |zf|
        zf.rename("other.txt", "renamed.txt")
      end
      Ziperu::File.open(path) do |zf|
        assert_equal(%w[dup.txt renamed.txt], zf.entries.map(&:name))
        assert_equal(%w[second third], zf.entries.map(&:get_raw_input_string))
        assert_empty(zf.verify)
      end
    end
  end

  def test_renaming_the_shadowed_record_writes_it_afresh
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dup.zip")
      FileUtils.cp(fixture(FIXTURE), path)
      Ziperu::File.open(path) do |zf|
        zf.entries[0].name = "first.txt"
      end
      Ziperu::File.open(path) do |zf|
        assert_equal(%w[first.txt dup.txt other.txt], zf.entries.map(&:name))
        assert_equal(CONTENTS, zf.entries.map(&:get_raw_input_string))
        assert_empty(zf.verify)
      end
    end
  end

  def test_removing_the_last_record_uncovers_the_earlier_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dup.zip")
      FileUtils.cp(fixture(FIXTURE), path)
      Ziperu::File.open(path) do |zf|
        zf.remove("dup.txt")
        assert_equal(%w[dup.txt other.txt], zf.entries.map(&:name))
        assert_equal("first", zf.read("dup.txt"))
      end
      Ziperu::File.open(path) do |zf|
        assert_equal(%w[dup.txt other.txt], zf.entries.map(&:name))
        assert_equal("first", zf.read("dup.txt"))
        assert_empty(zf.verify)
      end
    end
  end

  def test_copy_raw_entry_refuses_a_record_without_index
    Ziperu::File.open(fixture(FIXTURE)) do |zf|
      error = assert_raises(Ziperu::Error) do
        Ziperu::OutputStream.write_buffer { |zos| zos.copy_raw_entry(zf.entries[0]) }
      end
      assert_match(/shares its name/, error.message)
    end
  end

  def test_entries_survive_close_of_the_file
    zf = Ziperu::File.open(fixture(FIXTURE))
    first, second, = zf.entries
    zf.close
    assert_equal("first", first.get_input_stream(&:read))
    assert_equal("second", second.get_input_stream(&:read))
  end
end
