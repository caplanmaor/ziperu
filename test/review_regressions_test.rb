# frozen_string_literal: true

# Behaviour pinned down by a code review: closed streams, hostile sizes,
# threads, name encodings, and edits that must survive a commit.

require_relative "test_helper"
require "tmpdir"
require "delegate"

class ReviewRegressionsTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "a.zip")
    Ziperu::OutputStream.open(@zip) do |zos|
      zos.put_next_entry("x/y.txt")
      zos.write("hello\nworld\n")
      zos.put_next_entry("dir/")
    end
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_closed_input_stream_behaves_like_a_closed_io
    zis = Ziperu::InputStream.new(@zip)
    zis.get_next_entry
    zis.close
    refute_predicate zis, :eof?
    assert_raises(IOError) { zis.read }
    assert_raises(IOError) { zis.gets }
    assert_raises(IOError) { zis.rewind }
    assert_raises(IOError) { zis.get_next_entry }
  end

  def test_negative_read_length_is_an_argument_error
    Ziperu::InputStream.open(@zip) do |zis|
      zis.get_next_entry
      assert_raises(ArgumentError) { zis.read(-1) }
    end
  end

  def test_nothing_to_read_after_the_last_entry
    Ziperu::InputStream.open(@zip) do |zis|
      nil while zis.get_next_entry
      assert_equal "", zis.read
    end
  end

  def test_reading_a_directory_entry_gives_an_empty_string
    Ziperu::File.open(@zip) do |zf|
      assert_equal "", zf.read("dir/")
      assert_equal "", zf.get_entry("dir/").get_input_stream(&:read)
    end
  end

  def test_duplicate_entry_names_are_refused_by_name
    error = assert_raises(Ziperu::Error) do
      Ziperu::OutputStream.write_buffer do |zos|
        zos.put_next_entry("twice.txt")
        zos.write("1")
        zos.put_next_entry("twice.txt")
      end
    end
    assert_includes error.message, '"twice.txt"'
  end

  def test_an_output_stream_over_an_io_writes_the_archive_on_close
    io = StringIO.new
    zos = Ziperu::OutputStream.new(io, stream: true)
    zos.put_next_entry("a.txt")
    zos.write("x")
    zos.close
    assert_predicate io, :closed?
    Ziperu::File.open_buffer(io.string) { |zf| assert_equal "x", zf.read("a.txt") }
  end

  def test_an_oversized_archive_comment_is_refused_up_front
    assert_raises(ArgumentError) do
      Ziperu::OutputStream.write_buffer { |zos| zos.comment = "x" * 65_536 }
    end
  end

  def test_mutators_return_the_entry
    src = File.join(@tmp, "src.txt")
    File.write(src, "s")
    Ziperu::File.open(@zip) do |zf|
      assert_kind_of Ziperu::Entry, zf.add("s.txt", src)
      assert_kind_of Ziperu::Entry, zf.rename("s.txt", "t.txt")
      assert_kind_of Ziperu::Entry, zf.mkdir("made")
    end
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

  def test_exceptions_from_a_ruby_io_keep_their_class_and_jumps_work
    # Not a StringIO subclass: those are read from their string directly.
    exploding = Class.new(SimpleDelegator) do
      attr_accessor :fail_with

      def read(*args)
        raise fail_with if fail_with

        __getobj__.read(*args)
      end
    end
    io = exploding.new(StringIO.new(File.binread(@zip)))
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
    big = File.join(@tmp, "big.zip")
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
    zis = Ziperu::InputStream.new(@zip)
    zis.get_next_entry
    zis.read(2)
    zis.close
    GC.disable
    File.rename(@zip, "#{@zip}.moved")
    assert File.exist?("#{@zip}.moved")
  ensure
    GC.enable
  end
end
