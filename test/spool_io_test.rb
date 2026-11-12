# frozen_string_literal: true

require_relative "test_helper"

# `get_output_stream` keeps small entries in memory and moves to a
# tempfile once the archive's pending entries pass the budget.
class SpoolIOTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ziperu-spool")
    @zip = File.join(@dir, "out.zip")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_small_entries_stay_in_memory_and_round_trip
    Ziperu::File.open(@zip, create: true) do |zf|
      zf.get_output_stream("a.txt") do |os|
        assert_same os, (os << "one ")
        os.print "two "
        os.puts "three"
        os.printf("%03d", 7)
        os.write("!", "?")
        assert_kind_of StringIO, os.__getobj__
      end
      assert_equal "one two three\n007!?", zf.read("a.txt")
    end
    Ziperu::File.open(@zip) { |zf| assert_equal "one two three\n007!?", zf.read("a.txt") }
  end

  def test_spills_to_a_tempfile_past_the_budget
    big = Random.new(1).bytes(Ziperu::SpoolIO::BUDGET / 3 + 1)
    streams = []
    Ziperu::File.open(@zip, create: true) do |zf|
      4.times do |i|
        zf.get_output_stream("e#{i}") do |os|
          os.write(big.byteslice(0, 100))
          os.write(big.byteslice(100..))
          streams << os.__getobj__.class
        end
      end
      os = zf.get_output_stream("open")
      os.write("x")
      assert File.exist?(os.path), "path gives a real file"
      os.write("y")
      os.close
    end
    assert_equal [StringIO, StringIO, Tempfile, Tempfile], streams
    Ziperu::File.open(@zip) do |zf|
      4.times { |i| assert_equal big, zf.read("e#{i}") }
      assert_equal "xy", zf.read("open")
    end
  end

  def test_budget_is_given_back_at_commit
    big = "z" * (Ziperu::SpoolIO::BUDGET / 2 + 1)
    kinds = []
    Ziperu::File.open(@zip, create: true) do |zf|
      2.times do |round|
        zf.get_output_stream("r#{round}") do |os|
          os.write(big)
          kinds << os.__getobj__.class
        end
        zf.commit
      end
    end
    assert_equal [StringIO, StringIO], kinds
    Ziperu::File.open(@zip) { |zf| assert_equal big, zf.read("r1") }
  end

  def test_reading_while_open_for_writing_still_raises
    Ziperu::File.open(@zip, create: true) do |zf|
      zf.get_output_stream("w").write("data")
      assert_raises(StandardError) { zf.read("w") }
      zf.get_entry("w").get_output_stream.close
    end
  end
end
