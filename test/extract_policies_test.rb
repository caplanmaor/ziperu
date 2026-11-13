# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# unzip's policies on extract_all: on_exists, exclude, junk_paths, sanitize.
class ExtractPoliciesTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-policies")
    @path = File.join(@dir, "a.zip")
    @aes = File.join(@dir, "aes.zip")
    [[@path, nil], [@aes, Ziperu::AESEncrypter.new("pw")]].each do |path, enc|
      Ziperu::OutputStream.open(path, encrypter: enc) do |z|
        z.put_next_entry("d/")
        z.put_next_entry("d/a.txt")
        z.write("a")
        z.put_next_entry("d/b.log")
        z.write("b")
        z.put_next_entry("c.txt")
        z.write("c")
      end
    end
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def each_path(&block)
    # The plain archive takes the native path, the AES one the Ruby path.
    [[@path, {}], [@aes, { password: "pw" }]].each(&block)
  end

  def test_on_exists_overwrite_skip_and_raise
    each_path do |path, opts|
      out = File.join(@dir, "out")
      FileUtils.rm_rf(out)
      FileUtils.mkdir_p(File.join(out, "d"))
      File.write(File.join(out, "d/a.txt"), "old")
      File.write(File.join(out, "c.txt"), "old")

      Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, on_exists: :skip) }
      assert_equal "old", File.read(File.join(out, "d/a.txt"))
      assert_equal "b", File.read(File.join(out, "d/b.log"))

      Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, on_exists: :overwrite) }
      assert_equal "a", File.read(File.join(out, "d/a.txt"))
      assert_equal "c", File.read(File.join(out, "c.txt"))

      assert_raises(Ziperu::DestinationExistsError) do
        Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, on_exists: :raise) }
      end
      assert_raises(Ziperu::DestinationExistsError) do
        Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out) }
      end
      assert_raises(ArgumentError) { Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, on_exists: :merge) } }

      # Per entry too, and through File#extract.
      File.write(File.join(out, "c.txt"), "old")
      Ziperu::File.open(path, **opts) do |zf|
        zf.extract("c.txt", destination_directory: out, on_exists: :skip)
        assert_equal "old", File.read(File.join(out, "c.txt"))
        zf.get_entry("c.txt").extract("c.txt", destination_directory: out, on_exists: :overwrite)
        assert_equal "c", File.read(File.join(out, "c.txt"))
      end
    end
  end

  def test_a_file_in_a_directorys_place_is_not_overwritten_by_it
    out = File.join(@dir, "clash")
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "d"), "a file named d")
    assert_raises(Ziperu::DestinationExistsError) { Ziperu::File.open(@path) { |zf| zf.extract_all(out) } }
    Ziperu::File.open(@path) { |zf| zf.extract_all(out, on_exists: :skip) }
    assert_equal "a file named d", File.read(File.join(out, "d"))
    Ziperu::File.open(@path) { |zf| zf.extract_all(out, on_exists: :overwrite) }
    assert File.directory?(File.join(out, "d"))
    assert_equal "a", File.read(File.join(out, "d/a.txt"))
  end

  def test_exclude_globs_and_regexps
    each_path do |path, opts|
      out = File.join(@dir, "ex")
      FileUtils.rm_rf(out)
      Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, exclude: ["*.log"]) }
      assert File.exist?(File.join(out, "d/a.txt"))
      refute File.exist?(File.join(out, "d/b.log"))

      FileUtils.rm_rf(out)
      Ziperu::File.open(path, **opts) { |zf| zf.extract_all(out, exclude: [%r{\Ad/}, "nothing"]) }
      assert_equal %w[c.txt], Dir.children(out)
    end
  end

  def test_junk_paths
    each_path do |path, opts|
      out = File.join(@dir, "junk")
      FileUtils.rm_rf(out)
      seen = []
      Ziperu::File.open(path, **opts) do |zf|
        zf.extract_all(out, junk_paths: true, progress: ->(e, n, t) { seen << [e.name, n, t] })
      end
      assert_equal %w[a.txt b.log c.txt], Dir.children(out).sort
      assert_equal 3, seen.last[2]
    end
  end

  def test_sanitize_windows
    assert_equal "a_b/c_.txt", Ziperu::File.sanitize_windows_name("a:b/c?.txt")
    assert_equal "_con.txt", Ziperu::File.sanitize_windows_name("con.txt")
    assert_equal "_NUL/x", Ziperu::File.sanitize_windows_name("NUL/x")
    assert_equal "dir/", Ziperu::File.sanitize_windows_name("dir./")
    assert_equal "a_b", Ziperu::File.sanitize_windows_name("a\tb")
    assert_equal "_", Ziperu::File.sanitize_windows_name("...")

    zip = File.join(@dir, "odd.zip")
    Ziperu::OutputStream.open(zip) do |z|
      z.put_next_entry("odd:name?.txt")
      z.write("odd")
    end
    out = File.join(@dir, "san")
    Ziperu::File.open(zip) { |zf| zf.extract_all(out, sanitize: :windows) }
    assert_equal "odd", File.read(File.join(out, "odd_name_.txt"))
    assert_raises(ArgumentError) { Ziperu::File.open(zip) { |zf| zf.extract_all(out, sanitize: :mac) } }
  end
end
