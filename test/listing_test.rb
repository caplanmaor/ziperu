# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Listing archives with many entries: the lazy walk and what the eager
# listing keeps per entry.
class ListingTest < Minitest::Test
  include TestHelper

  COUNT = 300 # more than InputStream fetches in one batch

  def setup
    @dir = Dir.mktmpdir("ziperu-listing")
    @path = File.join(@dir, "many.zip")
    Ziperu::OutputStream.open(@path) do |z|
      COUNT.times do |i|
        z.put_next_entry("d#{i % 7}/f#{i}.txt")
        z.write("entry #{i}")
      end
    end
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_foreach_yields_every_entry_in_order_and_each_is_readable
    seen = []
    Ziperu::File.foreach(@path) do |e|
      seen << e.name
      assert_equal "entry #{seen.size - 1}", e.get_input_stream(&:read) if seen.size % 50 == 1
    end
    assert_equal COUNT, seen.size
    assert_equal "d0/f0.txt", seen.first
    assert_equal "d#{(COUNT - 1) % 7}/f#{COUNT - 1}.txt", seen.last
  end

  def test_foreach_without_a_block_is_a_lazy_enumerator
    enum = Ziperu::File.foreach(@path)
    assert_kind_of Enumerator, enum
    assert_equal "d0/f0.txt", enum.first.name
    assert_equal 5, enum.first(5).size
    assert_equal COUNT, enum.count
    found = enum.find { |e| e.name == "d3/f3.txt" }
    assert_equal "d3/f3.txt", found.name
  end

  def test_foreach_stops_early_and_closes_the_archive
    n = 0
    Ziperu::File.foreach(@path) do |_e|
      n += 1
      break if n == 10
    end
    assert_equal 10, n
    # The file is closed: on Windows it could not be deleted otherwise.
    assert File.delete(@path)
  end

  def test_foreach_accepts_an_io
    File.open(@path, "rb") do |io|
      assert_equal COUNT, Ziperu::File.foreach(io).count
    end
  end

  def test_input_stream_walks_past_a_batch_boundary
    names = []
    Ziperu::InputStream.open(@path) do |is|
      while (e = is.get_next_entry)
        names << e.name
        assert_equal "entry #{names.size - 1}", is.read if (names.size % 64).between?(63, 65)
      end
    end
    assert_equal COUNT, names.size
    assert_equal names, names.uniq
  end

  def test_listing_parses_extra_fields_and_times_only_when_asked
    Ziperu::File.open(@path) do |zf|
      e = zf.entries.first
      assert_nil e.instance_variable_get(:@extra), "extra fields are parsed on first use"
      assert_nil e.instance_variable_get(:@time), "the timestamp is parsed on first use"
      assert_in_delta Time.now, e.time, 24 * 3600
      assert_kind_of Ziperu::ExtraField, e.extra
      # An entry built by hand is unaffected.
      fresh = Ziperu::Entry.new("", "x.txt")
      assert_kind_of Ziperu::ExtraField, fresh.extra
    end
  end

  def test_entries_without_comments_share_one_empty_string
    Ziperu::File.open(@path) do |zf|
      a, b = zf.entries.first(2)
      assert a.comment.equal?(b.comment)
      assert a.comment.frozen?
      a.comment = "mine"
      assert_equal "", b.comment
    end
  end
end
