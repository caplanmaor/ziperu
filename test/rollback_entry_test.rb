# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# OutputStream#rollback_entry: an entry whose data could not be had is
# left out, and the archive goes on.
class RollbackEntryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ziperu-rollback")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def names(bytes)
    found = nil
    Ziperu::File.open_buffer(bytes) do |zf|
      assert_empty zf.verify
      found = zf.entries.map(&:name)
    end
    found
  end

  def write_with_a_failure(zos)
    zos.put_next_entry("a.txt")
    zos << "a" * 1000
    zos.put_next_entry("broken.txt")
    zos.rollback_entry
    zos.put_next_entry("c.txt")
    zos << "c"
  end

  def test_a_file_on_disk
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("a.txt")
      zos << "a" * 1000
      zos.put_next_entry("broken.txt")
      zos << Random.new(1).bytes(300_000)
      assert_equal "broken.txt", zos.rollback_entry.name
      zos.put_next_entry("c.txt")
      zos << "c"
    end
    assert_equal %w[a.txt c.txt], names(File.binread(@path))
    Ziperu::File.open(@path) { |zf| assert_equal "c", zf.read("c.txt") }
    assert_operator File.size(@path), :<, 10_000, "nothing of the entry taken back is left behind"
  end

  def test_a_buffer_and_a_seekable_io
    buf = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry("a.txt")
      zos << "a"
      zos.put_next_entry("big.bin")
      zos << Random.new(2).bytes(100_000)
      zos.rollback_entry
    end
    assert_equal %w[a.txt], names(buf.string)
    assert_operator buf.string.bytesize, :<, 1000
  end

  def test_a_stream_before_any_data
    body = Ziperu::OutputStream.body do |zos|
      write_with_a_failure(zos)
    end
    assert_equal %w[a.txt c.txt], names(body.to_a.join)
  end

  def test_a_stream_after_data_has_gone_out
    body = Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("a.txt")
      zos << "a"
      assert_raises(Ziperu::Error) { zos.rollback_entry }
      zos.put_next_entry("b.txt")
    end
    assert_equal %w[a.txt b.txt], names(body.to_a.join)
  end

  def test_the_name_can_be_used_again
    body = Ziperu::OutputStream.body do |zos|
      zos.put_next_entry("x.txt")
      zos.rollback_entry
      zos.put_next_entry("x.txt")
      zos << "second try"
    end
    bytes = body.to_a.join
    Ziperu::File.open_buffer(bytes) { |zf| assert_equal "second try", zf.read("x.txt") }

    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("x.txt")
      zos << "first"
      zos.rollback_entry
      zos.put_next_entry("x.txt")
      zos << "second"
    end
    Ziperu::File.open(@path) { |zf| assert_equal "second", zf.read("x.txt") }
  end

  def test_a_duplicate_name_on_a_stream_still_raises_at_put_next_entry
    assert_raises(Ziperu::EntryExistsError) do
      Ziperu::OutputStream.body do |zos|
        zos.put_next_entry("x")
        zos.put_next_entry("x")
      end.to_a
    end
  end

  def test_nothing_to_take_back
    Ziperu::OutputStream.open(@path) do |zos|
      assert_raises(Ziperu::Error) { zos.rollback_entry }
      zos.put_next_entry("a")
      zos.rollback_entry
      assert_raises(Ziperu::Error) { zos.rollback_entry }
    end
    assert_equal [], names(File.binread(@path))
  end

  def test_a_directory_and_a_zipcrypto_entry
    Ziperu::OutputStream.open(@path, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |zos|
      zos.put_next_entry("keep.txt")
      zos << "keep"
      zos.put_next_entry("secret.txt")
      zos << "s" * 5000
      zos.rollback_entry
      zos.put_next_entry("dir/")
      zos.rollback_entry
      zos.put_next_entry("last.txt")
      zos << "last"
    end
    Ziperu::File.open(@path, password: "pw") do |zf|
      assert_equal %w[keep.txt last.txt], zf.entries.map(&:name)
      assert_equal "last", zf.read("last.txt")
      assert_empty zf.verify
    end
  end
end
