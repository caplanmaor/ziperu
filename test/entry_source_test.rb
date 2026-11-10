# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Entry::Source: the one object that says where an entry's data is.
class EntrySourceTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-source")
    @path = File.join(@dir, "a.zip")
    @file = File.join(@dir, "f.txt")
    File.binwrite(@file, "from disk")
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a.txt"); z.write("stored") }
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_new_entry_has_no_source
    e = Ziperu::Entry.new("", "n.txt")
    assert_same Ziperu::Entry::Source::NONE, e.source
    refute e.pending_data?
    assert_nil e.index
    assert_nil e.archive
    assert_nil e.filepath
    assert_nil e.source_io
  end

  def test_an_entry_read_from_an_archive
    Ziperu::File.open(@path) do |zf|
      e = zf.get_entry("a.txt")
      assert_kind_of Ziperu::Entry::Source::Archive, e.source
      assert_equal 0, e.index
      assert e.backed_by?(zf.native_archive)
      refute e.pending_data?
    end
  end

  def test_added_entries_are_pending_and_read_from_their_source
    Ziperu::File.open(@path) do |zf|
      zf.add("f.txt", @file)
      zf.add("io.txt", StringIO.new("from io"))
      f = zf.get_entry("f.txt")
      io = zf.get_entry("io.txt")
      assert_kind_of Ziperu::Entry::Source::Path, f.source
      assert_kind_of Ziperu::Entry::Source::IO, io.source
      assert_equal @file, f.filepath
      assert f.pending_data? && io.pending_data?
      assert_equal "from disk", zf.read("f.txt")
      assert_equal "from io", zf.read("io.txt")
      assert_equal "from io", zf.read("io.txt"), "a seekable IO is read from the top each time"
    end
    Ziperu::File.open(@path) { |zf| assert_equal ["stored", "from disk", "from io"], zf.entries.map { |e| zf.read(e) } }
  end

  def test_data_replaced_on_an_archive_entry_keeps_the_record_behind_it
    Ziperu::File.open(@path) do |zf|
      e = zf.get_entry("a.txt")
      e.gather_fileinfo_from_srcpath(@file)
      assert e.pending_data?
      assert_equal 0, e.index, "the header still comes from the record"
      refute e.backed_by?(zf.native_archive), "but the bytes no longer do"
      assert_equal "from disk", e.get_input_stream(&:read)
    end
  end

  def test_marshal_drops_the_handles
    Ziperu::File.open(@path) do |zf|
      loaded = Marshal.load(Marshal.dump(zf.get_entry("a.txt")))
      assert_equal "a.txt", loaded.name
      assert_same Ziperu::Entry::Source::NONE.class, loaded.source.class
      assert_raises(Ziperu::Error) { loaded.get_input_stream(&:read) }

      zf.add("f.txt", @file)
      loaded = Marshal.load(Marshal.dump(zf.get_entry("f.txt")))
      assert_equal @file, loaded.filepath
    end
  end
end
