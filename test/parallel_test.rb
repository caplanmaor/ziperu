# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Extracting on several threads gives the same tree as one.
class ParallelTest < Minitest::Test
  include TestHelper

  COUNT = 120

  def setup
    @dir = Dir.mktmpdir("ziperu-parallel")
    @path = File.join(@dir, "a.zip")
    @data = {}
    Ziperu::File.open(@path, create: true) do |zf|
      zf.mkdir("d1")
      zf.mkdir("d1/sub")
      COUNT.times do |i|
        name = "d#{i % 3}/f#{i}.bin"
        @data[name] = Random.new(i).bytes(1000 + (i * 997) % 50_000)
        zf.get_output_stream(name) { |o| o.write @data[name] }
      end
    end
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def tree(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.filter_map do |f|
      next if %w[. ..].include?(File.basename(f))

      p = File.join(root, f)
      [f, File.directory?(p) ? :dir : Digest::SHA256.file(p).hexdigest]
    end
  end

  def test_threads_give_the_same_tree_as_one
    one = File.join(@dir, "one")
    four = File.join(@dir, "four")
    Ziperu::File.open(@path) { |zf| zf.extract_all(one) }
    Ziperu::File.open(@path) { |zf| zf.extract_all(four, threads: 4) }
    assert_equal tree(one), tree(four)
    assert_equal @data.size + 4, tree(four).size # three data dirs, d1/sub, the files
    @data.each { |name, bytes| assert_equal bytes, File.binread(File.join(four, name)) }
  end

  def test_threads_report_progress_and_the_first_failure
    seen = []
    out = File.join(@dir, "out")
    Ziperu::File.open(@path) { |zf| zf.extract_all(out, threads: 3, progress: ->(e, n, t) { seen << [e.name, n, t] }) }
    assert_equal @data.size + 2, seen.size
    assert_equal seen.map { |_, n, _| n }, (1..seen.size).to_a

    FileUtils.rm_rf(out)
    FileUtils.mkdir_p(File.join(out, "d1"))
    File.write(File.join(out, "d1/f1.bin"), "in the way")
    e = assert_raises(Ziperu::DestinationExistsError) do
      Ziperu::File.open(@path) { |zf| zf.extract_all(out, threads: 4) }
    end
    assert_match(%r{d1[\\/]f1\.bin}, e.message)
  end

  def test_threads_fall_back_to_one_for_an_io_archive
    out = File.join(@dir, "io")
    File.open(@path, "rb") do |io|
      Ziperu::File.open_buffer(io) { |zf| zf.extract_all(out, threads: 4) }
    end
    @data.each { |name, bytes| assert_equal bytes, File.binread(File.join(out, name)) }
  end

  def test_output_stream_add_files_on_threads_writes_the_same_archive
    src = File.join(@dir, "src")
    FileUtils.mkdir_p(src)
    files = {}
    60.times do |i|
      File.binwrite(File.join(src, "f#{i}.bin"), Random.new(100 + i).bytes(20_000 + i * 1000))
      files["in/f#{i}.bin"] = File.join(src, "f#{i}.bin")
    end
    one = File.join(@dir, "one.zip")
    many = File.join(@dir, "many.zip")
    Ziperu::OutputStream.open(one) { |z| z.add_files(files, threads: 1) }
    Ziperu::OutputStream.open(many) { |z| z.add_files(files, threads: 4) }
    Ziperu::File.open(many) do |zf|
      assert_equal files.keys, zf.entries.map(&:name)
      assert_empty zf.verify
      files.each { |n, p| assert_equal File.binread(p), zf.read(n) }
      assert_equal 0, zf.get_entry("in/f3.bin").gp_flags & 8, "sizes known up front: no descriptor"
    end
    Ziperu::File.open(one) { |zf| assert_equal files.keys, zf.entries.map(&:name) }

    # A duplicate name fails as it would one by one.
    dup = File.join(@dir, "dup.zip")
    assert_raises(Ziperu::EntryExistsError) do
      Ziperu::OutputStream.open(dup) { |z| z.add_files(files.to_a + [files.to_a.first], threads: 4) }
    end
    # Encrypted: still correct, written one by one.
    enc = File.join(@dir, "enc.zip")
    Ziperu::OutputStream.open(enc, encrypter: Ziperu::AESEncrypter.new("pw")) { |z| z.add_files(files.first(5), threads: 4) }
    Ziperu::File.open(enc, password: "pw") { |zf| assert_equal File.binread(files.values[2]), zf.read(files.keys[2]) }
  end

  def test_file_commit_on_threads_keeps_the_entry_order
    src = File.join(@dir, "tree")
    FileUtils.mkdir_p(File.join(src, "a/b"))
    30.times { |i| File.binwrite(File.join(src, "a", "f#{i}.bin"), Random.new(i).bytes(10_000)) }
    File.write(File.join(src, "a/b/deep.txt"), "deep")
    zip = File.join(@dir, "tree.zip")
    Ziperu::File.add_recursive(zip, src, threads: 4)
    seq = File.join(@dir, "seq.zip")
    Ziperu::File.add_recursive(seq, src)
    names = Ziperu::File.open(seq) { |zf| zf.entries.map(&:name) }
    Ziperu::File.open(zip) do |zf|
      assert_equal names, zf.entries.map(&:name)
      assert_equal "deep", zf.read("a/b/deep.txt")
      assert_empty zf.verify
    end
    # Mixed additions on an existing archive, appended on threads.
    Ziperu::File.open(zip, threads: 4) do |zf|
      zf.get_output_stream("note.txt") { |o| o.write "n" }
      zf.add("x1.bin", File.join(src, "a/f1.bin"))
      zf.add("x2.bin", File.join(src, "a/f2.bin"))
      zf.mkdir("m")
    end
    Ziperu::File.open(zip) do |zf|
      assert_equal names + %w[note.txt x1.bin x2.bin m/], zf.entries.map(&:name)
      assert_empty zf.verify
    end
  end

  def test_class_extract_all_takes_threads
    out = File.join(@dir, "cls")
    Ziperu::File.extract_all(@path, out, threads: 2)
    assert_equal @data.size + 4, tree(out).size
  end
end
