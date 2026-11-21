# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Ziperu::Tar.create and Tar::Writer: what is written is read back by
# Ziperu::Tar's own reader here; test/interop/run.rb hands it to GNU tar,
# bsdtar, Python and 7-Zip.
class TarWriterTest < Minitest::Test
  include TestHelper

  STAMP = Time.utc(2024, 1, 2, 3, 4, 5)

  def setup
    Ziperu.reset!
    @tmp = Dir.mktmpdir("ziperu-tarw")
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@tmp)
  end

  def path(name)
    File.join(@tmp, name)
  end

  # The archive at `source` as [name, type, data or link target] rows.
  def rows(source)
    Ziperu::Tar.foreach(source).map do |entry|
      [entry.name, entry.type, entry.file? ? entry.read : entry.link_target]
    end
  end

  def entries(source)
    seen = []
    Ziperu::Tar.foreach(source) { |entry| seen << entry }
    seen
  end

  def written(**options, &block)
    io = StringIO.new(+"".b)
    Ziperu::Tar.create(io, **options, &block)
    io.string
  end

  def symlinks_supported?
    probe = path("probe-link")
    File.symlink("probe-target", probe)
    true
  rescue NotImplementedError, SystemCallError
    false
  ensure
    FileUtils.rm_f(probe)
  end

  # ---- what is written ----

  def test_writes_every_kind_of_entry
    File.write(path("on-disk.txt"), "from disk")
    bytes = written do |tar|
      tar.mkdir("dir")
      tar.add_data("dir/a.txt", "data")
      tar.add("b.txt", path("on-disk.txt"))
      tar.add("c.bin", StringIO.new("from an io"))
      tar.symlink("link", "dir/a.txt")
      tar.link("hard", "b.txt")
      tar.add_data("empty", "")
    end

    assert_equal [["dir/", :directory, nil], ["dir/a.txt", :file, "data"], ["b.txt", :file, "from disk"],
                  ["c.bin", :file, "from an io"], ["link", :symlink, "dir/a.txt"], ["hard", :hardlink, "b.txt"],
                  ["empty", :file, ""]], rows(StringIO.new(bytes))
    assert_equal 0, bytes.bytesize % 512
    assert_equal "\0" * 1024, bytes[-1024..]
  end

  def test_an_ordinary_archive_is_plain_ustar
    bytes = written { |tar| tar.add_data("a.txt", "x") }

    assert_equal 512 + 512 + 1024, bytes.bytesize
    assert_equal "ustar\x0000", bytes[257, 8]
    refute_includes bytes, "PaxHeader"
  end

  def test_names_that_do_not_fit_ustar_come_back_whole
    long = "#{"d" * 99}/#{"n" * 200}.txt"
    binary = "caf\xE9.txt".b
    bytes = written do |tar|
      tar.add_data(long, "long")
      tar.add_data("héllo/名前.txt", "unicode")
      tar.add_data(binary, "bytes")
      tar.symlink("link", "t" * 150)
      tar.mkdir("m" * 120)
    end

    assert_equal [[long, :file, "long"], ["héllo/名前.txt", :file, "unicode"], [binary, :file, "bytes"],
                  ["link", :symlink, "t" * 150], ["#{"m" * 120}/", :directory, nil]], rows(StringIO.new(bytes))
    assert_includes bytes, "PaxHeader"
  end

  def test_mode_and_time_are_what_was_asked
    bytes = written do |tar|
      tar.add_data("a", "x", mode: 0o600, mtime: STAMP)
      tar.add_data("old", "x", mtime: Time.utc(1960, 1, 1))
      tar.mkdir("d", mode: 0o700, mtime: STAMP.to_i)
    end
    a, old, dir = entries(StringIO.new(bytes))

    assert_equal [0o600, STAMP], [a.mode, a.mtime]
    assert_equal Time.utc(1960, 1, 1), old.mtime
    assert_equal [0o700, STAMP], [dir.mode, dir.mtime]
    assert_equal [0, 0, "", ""], [a.uid, a.gid, a.uname, a.gname]
  end

  def test_a_file_from_disk_keeps_its_mode_and_time
    File.write(path("f"), "x")
    File.utime(STAMP, STAMP, path("f"))
    Dir.mkdir(path("d"))
    File.utime(STAMP, STAMP, path("d"))
    bytes = written do |tar|
      tar.add("f", path("f"))
      tar.add("d", Pathname(path("d")))
      tar.add("g", path("f"), mode: 0o640, mtime: Time.at(0))
    end
    file, dir, given = entries(StringIO.new(bytes))

    assert_equal [STAMP, File.stat(path("f")).mode & 0o7777], [file.mtime, file.mode]
    assert_equal ["d/", :directory, STAMP], [dir.name, dir.type, dir.mtime]
    assert_equal [0o640, Time.at(0)], [given.mode, given.mtime]
  end

  def test_an_io_is_read_from_where_it_stands
    io = StringIO.new("skip this, keep that")
    io.read(11)
    File.binwrite(path("f"), "0123456789")

    bytes = written do |tar|
      tar.add("a", io)
      File.open(path("f"), "rb") do |file|
        file.read(4)
        tar.add("b", file)
      end
    end

    assert_equal [["a", :file, "keep that"], ["b", :file, "456789"]], rows(StringIO.new(bytes))
  end

  def test_an_io_that_cannot_say_its_size_is_spooled
    reader, writer = IO.pipe
    writer.binmode
    feeder = Thread.new do
      writer.write("p" * 200_000)
      writer.close
    end
    body = Object.new
    def body.read(*)
      return nil if @done

      @done = true
      "from a body"
    end

    bytes = written do |tar|
      tar.add("pipe", reader)
      tar.add("body", body)
    end
    feeder.join
    reader.close

    assert_equal [["pipe", :file, "p" * 200_000], ["body", :file, "from a body"]], rows(StringIO.new(bytes))
  end

  def test_large_data_goes_through_whole
    data = Random.new(3).bytes(3_000_000)
    File.binwrite(path("big"), data)
    Ziperu::Tar.create(path("big.tar.zst")) do |tar|
      tar.add("disk", path("big"))
      tar.add("io", StringIO.new(data))
      tar.add_data("string", data)
    end

    assert_equal [data] * 3, rows(path("big.tar.zst")).map(&:last)
  end

  # ---- compression ----

  def test_compression_follows_the_name_of_the_file
    { "a.tar" => :none, "a.tar.gz" => :gzip, "a.tgz" => :gzip, "a.tar.zst" => :zstd, "a.tzst" => :zstd,
      "a.tar.xz" => :xz, "a.txz" => :xz, "a.tar.bz2" => :bzip2, "A.TBZ2" => :bzip2,
      "plain" => :none }.each do |name, expected|
      Ziperu::Tar.create(path(name)) { |tar| tar.add_data("a", "x" * 5000) }

      Ziperu::Tar::Reader.open(path(name)) do |reader|
        assert_equal expected, reader.compression, name
        assert_equal "x" * 5000, reader.next_entry.read
      end
    end
  end

  def test_compression_can_be_said_outright
    Ziperu::Tar.create(path("odd.bin"), compression: :xz) { |tar| tar.add_data("a", "x") }

    assert_equal :xz, Ziperu::Tar::Reader.open(path("odd.bin"), &:compression)

    Ziperu::Tar.create(path("b.tar.gz"), compression: :none) { |tar| tar.add_data("a", "x") }

    assert_equal :none, Ziperu::Tar::Reader.open(path("b.tar.gz"), &:compression)

    %i[gzip zstd xz bzip2].each do |compression|
      bytes = written(compression: compression) { |tar| tar.add_data("a", "x" * 9000) }

      assert_operator bytes.bytesize, :<, 1000, compression
      assert_equal [["a", :file, "x" * 9000]], rows(StringIO.new(bytes))
    end
  end

  def test_an_io_is_not_compressed_unless_asked
    assert_equal "ustar", written { |tar| tar.add_data("a", "x") }[257, 5]
  end

  def test_the_level_changes_what_comes_out
    data = "some text that repeats. " * 20_000
    { gzip: [1, 9], zstd: [1, 19], xz: [0, 9], bzip2: [1, 9] }.each do |compression, (low, high)|
      fast = written(compression: compression, level: low) { |tar| tar.add_data("a", data) }
      small = written(compression: compression, level: high) { |tar| tar.add_data("a", data) }

      assert_equal [["a", :file, data]], rows(StringIO.new(fast)), compression
      assert_equal [["a", :file, data]], rows(StringIO.new(small)), compression
      refute_equal fast, small, compression
    end
  end

  def test_options_are_checked
    io = StringIO.new
    assert_raises(ArgumentError) { Ziperu::Tar.create(io, compression: :lz4) { |tar| tar } }
    assert_raises(ArgumentError) { Ziperu::Tar.create(io, compression: :gzip, level: 10) { |tar| tar } }
    assert_raises(ArgumentError) { Ziperu::Tar.create(io, compression: :zstd, level: 0) { |tar| tar } }
    assert_raises(ArgumentError) { Ziperu::Tar.create(io, level: 3) { |tar| tar } }
    assert_raises(ArgumentError) { Ziperu::Tar.create(io, threads: 2) { |tar| tar } }
    assert_raises(ArgumentError) { Ziperu::Tar.create(io) }
    assert_empty io.string
  end

  # ---- where it goes ----

  def test_returns_what_it_was_given_and_leaves_an_io_open
    io = StringIO.new(+"".b)

    assert_same io, Ziperu::Tar.create(io) { |tar| tar.add_data("a", "x") }
    refute_predicate io, :closed?
    assert_equal path("a.tar"), Ziperu::Tar.create(path("a.tar")) { |tar| tar.add_data("a", "x") }
    assert_equal [["a", :file, "x"]], rows(Pathname(path("a.tar")))
  end

  def test_writes_to_a_pipe
    reader, writer = IO.pipe
    reader.binmode
    writer.binmode
    seen = Thread.new { rows(reader) }
    Ziperu::Tar.create(writer, compression: :gzip) { |tar| tar.add_data("a", "through a pipe" * 10_000) }
    writer.close

    assert_equal [["a", :file, "through a pipe" * 10_000]], seen.value
  ensure
    reader.close
  end

  def test_body_yields_the_archive_as_it_is_made
    body = Ziperu::Tar.body(compression: :gzip) do |tar|
      tar.add_data("a.csv", "1,2\n")
      tar.add_data("big", Random.new(1).bytes(300_000))
    end
    chunks = body.to_a

    assert_operator chunks.size, :>, 1
    assert_equal ["a.csv", "big"], rows(StringIO.new(chunks.join)).map(&:first)
    assert_raises(ArgumentError) { Ziperu::Tar.body }
  end

  def test_a_failure_leaves_the_path_as_it_was
    File.write(path("a.tar"), "what was there")

    assert_raises(RuntimeError) do
      Ziperu::Tar.create(path("a.tar")) do |tar|
        tar.add_data("a", "x" * 100_000)
        raise "stop"
      end
    end
    assert_equal "what was there", File.read(path("a.tar"))
    assert_equal ["a.tar"], Dir.children(@tmp)

    assert_raises(Errno::ENOENT) { Ziperu::Tar.create(path("new.tar")) { |tar| tar.add("a", path("missing")) } }
    assert_equal ["a.tar"], Dir.children(@tmp)
  end

  def test_an_archive_in_place_is_replaced_when_the_new_one_is_whole
    Ziperu::Tar.create(path("a.tar")) { |tar| tar.add_data("old", "x") }
    Ziperu::Tar.create(path("a.tar")) do |tar|
      tar.add_data("new", "y")

      assert_equal ["old"], rows(path("a.tar")).map(&:first)
    end

    assert_equal ["new"], rows(path("a.tar")).map(&:first)
    assert_equal ["a.tar"], Dir.children(@tmp)
  end

  def test_a_writer_without_a_block_is_closed_or_abandoned
    writer = Ziperu::Tar::Writer.new(path("a.tar.gz"))
    writer.add_data("a", "x").mkdir("d")

    refute_predicate writer, :closed?
    refute_path_exists path("a.tar.gz")
    writer.close
    writer.close

    assert_predicate writer, :closed?
    assert_equal ["a", "d/"], rows(path("a.tar.gz")).map(&:first)
    assert_raises(IOError) { writer.add_data("b", "y") }

    other = Ziperu::Tar::Writer.new(path("b.tar"))
    other.add_data("a", "x")
    other.abandon

    assert_equal ["a.tar.gz"], Dir.children(@tmp)
  end

  def test_a_writer_dropped_unfinished_does_no_harm
    io = StringIO.new(+"".b)
    20.times do
      writer = Ziperu::Tar::Writer.new(io, compression: :gzip)
      writer.add_data("a", "x" * 100_000)
    end
    GC.start

    assert_kind_of String, io.string
  end

  # ---- misuse ----

  def test_names_are_checked
    io = StringIO.new
    Ziperu::Tar.create(io) do |tar|
      assert_raises(ArgumentError) { tar.add_data("", "x") }
      assert_raises(ArgumentError) { tar.add_data("/", "x") }
      assert_raises(ArgumentError) { tar.add_data("a\0b", "x") }
      assert_raises(ArgumentError) { tar.symlink("link", "") }
      assert_raises(ArgumentError) { tar.link("hard", "") }
      tar.add_data("dir-like/", "x")
    end

    assert_equal [["dir-like", :file, "x"]], rows(StringIO.new(io.string))
  end

  def test_an_io_that_gives_less_than_it_said_stops_the_archive
    liar = StringIO.new("short")
    def liar.size = 500

    error = assert_raises(Ziperu::Error) do
      Ziperu::Tar.create(path("a.tar")) do |tar|
        tar.add("a", liar)
        tar.add_data("b", "x")
      end
    end
    assert_match(/entry 'a' is 495 bytes short of the size its header gives/, error.message)
    assert_empty Dir.children(@tmp)
  end

  def test_what_is_neither_a_file_nor_a_directory_is_refused
    Ziperu::Tar.create(StringIO.new) do |tar|
      assert_raises(Errno::ENOENT) { tar.add("a", path("missing")) }
      assert_raises(TypeError) { tar.add("a", 12) }
    end
  end

  def test_a_file_that_shrank_is_made_up_with_zeros
    File.binwrite(path("f"), "abc")
    # What was true of the file when it was looked at.
    stat = Object.new
    def stat.size = 1000
    def stat.zero? = false
    def stat.mode = 0o644
    def stat.mtime = STAMP
    bytes = nil
    _, err = capture_io do
      bytes = written do |tar|
        tar.add_file("f", path("f"), stat)
        tar.add_data("after", "x")
      end
    end

    assert_match(/shrank from 1000 to 3 bytes while it was read; 'f' is made up with zeros/, err)
    assert_equal [["f", :file, "abc#{"\0" * 997}"], ["after", :file, "x"]], rows(StringIO.new(bytes))
  end

  # ---- reproducible ----

  def test_the_same_input_gives_the_same_bytes
    File.write(path("f"), "x")
    make = lambda do
      written(compression: :gzip, source_date_epoch: 1_700_000_000) do |tar|
        tar.add_data("a", "data")
        tar.add("f", path("f"))
        tar.mkdir("d")
      end
    end
    first = make.call
    File.utime(Time.now + 60, Time.now + 60, path("f"))
    sleep 1.1

    assert_equal first, make.call
    assert_equal [Time.at(1_700_000_000)] * 3, entries(StringIO.new(first)).map(&:mtime)
  end

  def test_the_epoch_leaves_earlier_times_alone_and_follows_the_global
    Ziperu.source_date_epoch = STAMP.to_i
    bytes = written do |tar|
      tar.add_data("early", "x", mtime: STAMP - 100)
      tar.add_data("late", "x", mtime: STAMP + 100)
      tar.add_data("now", "x")
    end

    assert_equal [STAMP - 100, STAMP, STAMP], entries(StringIO.new(bytes)).map(&:mtime)
  end

  # ---- add_recursive ----

  def tree
    src = path("src")
    FileUtils.mkdir_p(File.join(src, "sub/deep"))
    FileUtils.mkdir_p(File.join(src, "empty"))
    File.write(File.join(src, "b.txt"), "b")
    File.write(File.join(src, "a.log"), "log")
    File.write(File.join(src, "sub/c.txt"), "c")
    File.write(File.join(src, "sub/deep/d.txt"), "d")
    src
  end

  def test_add_recursive_adds_a_tree_in_name_order
    src = tree
    seen = []
    Ziperu::Tar.add_recursive(path("t.tar.gz"), src, progress: ->(name, done, total) { seen << [name, done, total] })

    names = ["a.log", "b.txt", "empty/", "sub/", "sub/c.txt", "sub/deep/", "sub/deep/d.txt"]

    assert_equal names, rows(path("t.tar.gz")).map(&:first)
    assert_equal names.map { |n| n.chomp("/") }, seen.map(&:first)
    assert_equal [(1..7).to_a, [nil]], [seen.map { |row| row[1] }, seen.map(&:last).uniq]
    assert_equal :gzip, Ziperu::Tar::Reader.open(path("t.tar.gz"), &:compression)
  end

  def test_add_recursive_takes_a_prefix_and_excludes
    src = tree
    bytes = written do |tar|
      tar.add_recursive(Pathname(src), prefix: "site/", exclude: ["*.log", %r{\Asite/sub/deep\z}])
    end

    assert_equal ["site/b.txt", "site/empty/", "site/sub/", "site/sub/c.txt"], rows(StringIO.new(bytes)).map(&:first)
  end

  def test_add_recursive_leaves_out_the_archive_it_is_writing
    src = tree
    Ziperu::Tar.add_recursive(File.join(src, "self.tar"), src)

    refute_includes rows(File.join(src, "self.tar")).map(&:first).join(" "), "self.tar"
  end

  def test_add_recursive_skips_or_stores_links
    skip "needs symlink support" unless symlinks_supported?
    src = tree
    File.symlink("b.txt", File.join(src, "link"))
    File.symlink("sub", File.join(src, "dirlink"))
    bytes = nil
    _, err = capture_io { bytes = written { |tar| tar.add_recursive(src) } }

    assert_equal 2, err.scan("WARNING: skipped symlink").size
    refute_includes rows(StringIO.new(bytes)).map(&:first), "link"

    bytes = written { |tar| tar.add_recursive(src, symlinks: :store) }
    stored = rows(StringIO.new(bytes)).select { |_, type, _| type == :symlink }

    assert_equal [["dirlink", :symlink, "sub"], ["link", :symlink, "b.txt"]], stored
    refute_includes rows(StringIO.new(bytes)).map(&:first), "dirlink/c.txt"
  end

  def test_add_recursive_checks_what_it_is_given
    Ziperu::Tar.create(StringIO.new) do |tar|
      assert_raises(ArgumentError) { tar.add_recursive(path("missing")) }
      assert_raises(ArgumentError) { tar.add_recursive(@tmp, symlinks: :follow) }
    end
  end

  # ---- round trip ----

  def test_what_is_written_extracts_to_what_was_archived
    src = tree
    File.utime(STAMP, STAMP, File.join(src, "sub/c.txt"))
    Ziperu::Tar.add_recursive(path("t.tar.xz"), src)
    Ziperu.extract(path("t.tar.xz"), path("out"))

    listing = ->(dir) { Dir.glob("**/*", base: dir).sort.map { |f| [f, File.file?(File.join(dir, f)) && File.read(File.join(dir, f))] } }

    assert_equal listing.call(src), listing.call(path("out"))
    assert_equal STAMP, File.mtime(path("out/sub/c.txt"))
  end

  # ---- failures that leave things as they were ----

  def test_a_file_that_cannot_be_opened_leaves_the_archive_to_go_on
    File.write(path("here"), "here")
    bytes = written do |tar|
      tar.add_data("before", "1")
      assert_raises(Errno::ENOENT) { tar.add("gone", path("gone")) }
      # Gone between being looked at and being read.
      assert_raises(Errno::ENOENT) { tar.add_file("gone", path("gone"), File.stat(path("here"))) }
      tar.add("here", path("here"))
    end
    assert_equal [["before", :file, "1"], ["here", :file, "here"]], rows(StringIO.new(bytes))
  end

  def test_an_archive_that_cannot_be_put_in_place_leaves_nothing_behind
    Dir.mkdir(path("taken.tar"))
    File.write(path("taken.tar/inside"), "x")
    assert_raises(SystemCallError) { Ziperu::Tar.create(path("taken.tar")) { |tar| tar.add_data("a", "b") } }
    assert_equal ["taken.tar"], Dir.children(@tmp)
    assert_equal "x", File.read(path("taken.tar/inside"))
  end

  def test_a_large_string_is_written_whole
    data = Random.new(3).bytes(3_500_000)
    bytes = written { |tar| tar.add_data("big", data).add_data("empty", "") }
    assert_equal [["big", :file, data], ["empty", :file, ""]], rows(StringIO.new(bytes))
  end

  # ---- the compressed stream ----

  def test_a_gzip_header_says_nothing_of_the_machine
    header = written(compression: :gzip) { |tar| tar.add_data("a", "b") }.bytes.first(10)
    assert_equal [0x1f, 0x8b, 8, 0], header[0, 4]
    assert_equal [0, 0, 0, 0], header[4, 4], "no time"
    assert_equal 255, header[9], "no operating system"
  end

  def test_a_zstd_archive_carries_a_checksum
    data = Random.new(4).bytes(50_000)
    bytes = written(compression: :zstd) { |tar| tar.add_data("a", data) }
    assert_equal 4, bytes.getbyte(4) & 4, "the frame says it has a checksum"

    # Random data is stored as it is, so a changed byte decodes: only the
    # checksum can tell.
    bytes.setbyte(20_000, bytes.getbyte(20_000) ^ 1)
    assert_raises(Ziperu::Error) { rows(StringIO.new(bytes)) }
  end
end
