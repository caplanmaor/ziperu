# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# `write:` on Ziperu::File: where changes go on commit, if anywhere.
class NonDestructiveTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-nondestructive")
    @path = File.join(@dir, "a.zip")
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("one.txt")
      z.write("one")
      z.comment = "original"
    end
    @before = File.binread(@path)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_read_only_refuses_every_change_and_never_writes
    Ziperu::File.open(@path, write: false) do |zf|
      assert zf.read_only?
      assert_equal "one", zf.read("one.txt")
      %w[comment= get_output_stream add remove rename replace mkdir].each do |m|
        args = { "comment=" => ["x"], "get_output_stream" => ["two.txt"], "add" => ["two.txt", __FILE__],
                 "remove" => ["one.txt"], "rename" => ["one.txt", "uno.txt"], "replace" => ["one.txt", __FILE__],
                 "mkdir" => ["d"] }[m]
        e = assert_raises(Ziperu::Error, m) { zf.public_send(m, *args) }
        assert_match(/read-only/, e.message)
      end
      refute zf.commit_required?
    end
    assert_equal @before, File.binread(@path)
    assert_raises(ArgumentError) { Ziperu::File.open(File.join(@dir, "new.zip"), create: true, write: false) }
    assert_raises(ArgumentError) { Ziperu::File.open(@path, write: 3) }
  end

  def test_changes_can_be_written_to_another_archive
    other = File.join(@dir, "b.zip")
    Ziperu::File.open(@path, write: other) do |zf|
      assert_equal other, zf.write_to
      zf.get_output_stream("two.txt") { |o| o.write "two" }
      zf.rename("one.txt", "uno.txt")
      zf.comment = "changed"
    end
    assert_equal @before, File.binread(@path), "the archive opened is untouched"
    Ziperu::File.open(other) do |zf|
      assert_equal %w[two.txt uno.txt], zf.entries.map(&:name) # a rename re-adds, as in rubyzip
      assert_equal "one", zf.read("uno.txt")
      assert_equal "changed", zf.comment
      assert_empty zf.verify
    end
    # After the commit the object works on the archive it wrote, so what
    # it lists is what is on disk there, and a later commit builds on it.
    Ziperu::File.open(@path, write: other) do |zf|
      zf.remove("one.txt")
      zf.commit
      assert_equal other, zf.name
      assert_nil zf.write_to
      assert_empty zf.entries
    end
    Ziperu::File.open(other) { |zf| assert_empty zf.entries }
    assert_equal @before, File.binread(@path), "the archive opened is still untouched"
  end

  def test_write_to_accepts_a_pathname
    other = Pathname.new(@dir) + "c.zip"
    Ziperu::File.open(@path, write: other) { |zf| zf.get_output_stream("x") { |o| o.write "x" } }
    assert File.exist?(other)
    assert_equal @before, File.binread(@path)
  end

  def test_open_buffer_read_only_leaves_the_buffer_alone
    io = StringIO.new(@before.dup)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal "one", zf.read("one.txt")
      assert_raises(Ziperu::Error) { zf.get_output_stream("x") { |o| o.write "x" } }
    end
    assert_equal @before, io.string
    assert_raises(ArgumentError) { Ziperu::File.open_buffer(io, write: File.join(@dir, "x.zip")) {} }
  end
end
