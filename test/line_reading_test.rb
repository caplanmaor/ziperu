# frozen_string_literal: true

require_relative "test_helper"

# Line and byte reads from an entry match the same calls on a StringIO of
# its data, across chunk boundaries, separators, limits and pushback.
class LineReadingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ziperu-lines")
    @zip = File.join(@dir, "t.zip")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def data_for(seed)
    r = Random.new(seed)
    lines = Array.new(r.rand(200..4000)) do
      len = [0, 1, 2, 10, 80, 200, 70_000].sample(random: r)
      ("x" * len) + ["\n", "\r\n", "\n\n", "--"].sample(random: r)
    end
    lines.join.b
  end

  def calls(seed)
    r = Random.new(seed * 7)
    Array.new(400) do
      case r.rand(9)
      when 0 then [:gets]
      when 1 then [:gets, "--"]
      when 2 then [:gets, "

"]
      when 3 then [:gets, "\n", r.rand(1..300)]
      when 4 then [:gets, { chomp: true }]
      when 5 then [:read, r.rand(0..100_000)]
      when 6 then [:getc]
      when 7 then [:ungetc, "u"]
      else [:readlines_some, r.rand(1..5)]
      end
    end
  end

  def apply(io, call)
    name, *args = call
    case name
    when :readlines_some then Array.new(args.first) { io.gets }
    when :gets
      kw = args.last.kind_of?(Hash) ? args.pop : {}
      io.gets(*args, **kw)
    else io.public_send(name, *args)
    end
  end

  def test_matches_stringio
    6.times do |seed|
      data = data_for(seed)
      Ziperu::OutputStream.open(@zip) do |z|
        z.put_next_entry("e")
        z.write(data)
      end
      Ziperu::File.open(@zip) do |zf|
        zf.get_input_stream("e") do |is|
          ref = StringIO.new(data.dup)
          calls(seed).each_with_index do |call, i|
            got = apply(is, call)
            want = apply(ref, call)
            got = got&.b if got.kind_of?(String)
            want = want&.b if want.kind_of?(String)
            got = got.map { |l| l&.b } if got.kind_of?(Array)
            want = want.map { |l| l&.b } if want.kind_of?(Array)
            if want.nil?
              assert_nil got, "seed #{seed}, call #{i}: #{call.inspect}"
            else
              assert_equal want, got, "seed #{seed}, call #{i}: #{call.inspect}"
            end
            assert_equal ref.eof?, is.eof?, "eof after seed #{seed}, call #{i}"
          end
          rest = is.read
          assert_equal ref.read.b, rest.b
        end
      end
    end
  end

  def test_each_line_over_many_chunks
    data = Array.new(50_000) { |i| "line #{i}\n" }.join.b
    Ziperu::OutputStream.open(@zip) do |z|
      z.put_next_entry("e")
      z.write(data)
    end
    Ziperu::File.open(@zip) do |zf|
      lines = zf.get_input_stream("e") { |is| is.each_line.to_a }
      assert_equal data.lines, lines
      bytes = zf.get_input_stream("e") { |is| is.each_byte.first(20_000) }
      assert_equal data.bytes.first(20_000), bytes
    end
  end
end
