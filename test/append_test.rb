# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Adding entries to an existing archive appends them in place.
class AppendTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-append")
    @path = File.join(@dir, "a.zip")
    @big = Random.new(5).bytes(600_000)
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("one.txt")
      z.write("one")
      z.put_next_entry("big.bin")
      z.write(@big)
      z.comment = "kept"
    end
    @before = File.binread(@path)
    @cdir_start = @before.index("PK\x01\x02".b)
  end

  def teardown
    Ziperu.append_in_place = true
    FileUtils.rm_rf(@dir)
  end

  def test_adding_entries_appends_after_the_existing_ones
    Ziperu::File.open(@path) do |zf|
      zf.get_output_stream("two.txt") { |o| o.write "two" }
      zf.add("three.txt", StringIO.new("three"))
      zf.mkdir("d")
    end
    after = File.binread(@path)
    assert_equal @before.byteslice(0, @cdir_start), after.byteslice(0, @cdir_start),
                 "the existing entries are untouched"
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[one.txt big.bin two.txt three.txt d/], zf.entries.map(&:name)
      assert_equal "kept", zf.comment
      assert_equal "one", zf.read("one.txt")
      assert_equal @big, zf.read("big.bin")
      assert_equal "two", zf.read("two.txt")
      assert_equal "three", zf.read("three.txt")
      assert_equal @cdir_start, zf.get_entry("two.txt").local_header_offset,
                   "the first new entry starts where the old central directory was"
      assert_empty zf.verify
    end
  end

  def test_entries_learn_their_offsets_from_the_append
    Ziperu::File.open(@path) do |zf|
      zf.get_output_stream("two.txt") { |o| o.write "two" }
      zf.commit
      e = zf.get_entry("two.txt")
      assert_equal @cdir_start, e.local_header_offset
      assert_equal 3, e.size
      assert_equal Zlib.crc32("two"), e.crc
    end
  end

  def test_anything_but_an_addition_rewrites_the_archive
    Ziperu::File.open(@path) do |zf|
      zf.remove("one.txt")
      zf.get_output_stream("two.txt") { |o| o.write "two" }
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[big.bin two.txt], zf.entries.map(&:name)
      assert_equal 0, zf.get_entry("big.bin").local_header_offset
    end

    Ziperu::File.open(@path) do |zf|
      zf.rename("two.txt", "deux.txt")
      zf.get_output_stream("three.txt") { |o| o.write "3" }
    end
    Ziperu::File.open(@path) { |zf| assert_equal %w[big.bin deux.txt three.txt], zf.entries.map(&:name) }

    Ziperu::File.open(@path) do |zf|
      zf.comment = "changed"
      zf.get_output_stream("four.txt") { |o| o.write "4" }
    end
    Ziperu::File.open(@path) { |zf| assert_equal "changed", zf.comment }

    # Replacing an entry keeps its place, so the archive is rewritten.
    Ziperu::File.open(@path) do |zf|
      zf.get_output_stream("deux.txt") { |o| o.write "zwei" }
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[big.bin deux.txt three.txt four.txt], zf.entries.map(&:name)
      assert_equal "zwei", zf.read("deux.txt")
    end
  end

  def test_append_in_place_can_be_turned_off
    Ziperu.append_in_place = false
    Ziperu::File.open(@path) do |zf|
      zf.get_output_stream("two.txt") { |o| o.write "two" }
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[one.txt big.bin two.txt], zf.entries.map(&:name)
      assert_equal "kept", zf.comment
    end
  end

  def test_a_failed_append_leaves_the_archive_as_it_was
    src = File.join(@dir, "gone.txt")
    File.write(src, "gone")
    Ziperu::File.open(@path) do |zf|
      zf.get_output_stream("two.txt") { |o| o.write "two" }
      zf.add("gone.txt", src)
      File.delete(src)
      assert_raises(Errno::ENOENT) { zf.commit }
      assert_equal @before, File.binread(@path), "put back byte for byte"
      # The archive is still usable, and the commit can be retried.
      assert_equal "one", zf.read("one.txt")
      File.write(src, "back")
      zf.commit
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[one.txt big.bin two.txt gone.txt], zf.entries.map(&:name)
      assert_equal "back", zf.read("gone.txt")
      assert_empty zf.verify
    end
  end

  def test_appending_to_an_archive_with_zipcrypto_entries
    zc = File.join(@dir, "zc.zip")
    Ziperu::OutputStream.open(zc, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("locked.txt")
      z.write("locked")
    end
    Ziperu::File.open(zc) { |zf| zf.get_output_stream("plain.txt") { |o| o.write "plain" } }
    Ziperu::File.open(zc, password: "pw") do |zf|
      assert_equal "locked", zf.read("locked.txt")
      assert_equal "plain", zf.read("plain.txt")
      assert_empty zf.verify
    end
  end

  def test_output_stream_append_option
    Ziperu::OutputStream.open(@path, append: true) do |z|
      z.put_next_entry("two.txt")
      z.write("two")
    end
    Ziperu::File.open(@path) do |zf|
      assert_equal %w[one.txt big.bin two.txt], zf.entries.map(&:name)
      assert_equal "kept", zf.comment
    end
    Ziperu::OutputStream.open(@path, append: true) do |z|
      z.comment = "new comment"
      e = assert_raises(Ziperu::EntryExistsError) { z.put_next_entry("one.txt") }
      assert_match(/one\.txt/, e.message)
    end
    Ziperu::File.open(@path) { |zf| assert_equal "new comment", zf.comment }
    assert_raises(ArgumentError) { Ziperu::OutputStream.new(StringIO.new, stream: true, append: true) }
  end

  def test_appending_to_a_zip64_ready_archive_and_reading_with_input_stream
    Ziperu::File.open(@path) { |zf| zf.get_output_stream("two.txt") { |o| o.write "two" } }
    names = []
    Ziperu::InputStream.open(@path) do |is|
      while (e = is.get_next_entry)
        names << [e.name, is.read.bytesize]
      end
    end
    assert_equal [["one.txt", 3], ["big.bin", @big.bytesize], ["two.txt", 3]], names
  end
end
