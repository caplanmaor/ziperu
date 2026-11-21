# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Ziperu::Tar.extract_all and Ziperu.extract: the fixtures under
# test/data/tar, and archives built here header by header for what no
# well-behaved writer produces.
class TarExtractTest < Minitest::Test
  include TestHelper

  WINDOWS = Ziperu::RUNNING_ON_WINDOWS
  LONG = "n" * 150
  STAMP = Time.utc(2024, 1, 2, 3, 4, 5)

  def setup
    @tmp = Dir.mktmpdir("ziperu-tar")
    @out = File.join(@tmp, "out")
  end

  def teardown
    FileUtils.chmod_R(0o755, @tmp, force: true)
    FileUtils.rm_rf(@tmp)
  end

  def tar(name)
    fixture(File.join("tar", name))
  end

  # One entry of a ustar archive: its header, data and padding.
  def entry(name, data = "", type: "0", mode: 0o644, link: "", mtime: STAMP.to_i)
    fields = [name, format("%07o", mode), "0000000", "0000000", format("%011o", data.bytesize),
              format("%011o", mtime), " " * 8, type, link, "ustar", "00", "", "", "", "", ""]
    header = fields.pack("a100a8a8a8a12a12a8a1a100a6a2a32a32a8a8a155") + ("\0" * 12)
    header[148, 8] = format("%06o\0 ", header.sum)
    header + data.b + ("\0" * (-data.bytesize % 512))
  end

  def directory(name, **options)
    entry(name, type: "5", mode: 0o755, **options)
  end

  def archive(*entries)
    StringIO.new(entries.join + ("\0" * 1024))
  end

  # Extracts and returns what was warned.
  def extract(source, dest = @out, **options)
    _, err = capture_io { Ziperu::Tar.extract_all(source, dest, **options) }
    err
  end

  # Every path under `dir`, relative, directories with a trailing slash.
  def tree(dir = @out)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |path| path.end_with?("/.", "/..") || path == "." }
       .map { |path| File.directory?(File.join(dir, path)) && !File.symlink?(File.join(dir, path)) ? "#{path}/" : path }
       .sort
  end

  def read(path)
    File.binread(File.join(@out, path))
  end

  def symlinks_supported?
    probe = File.join(@tmp, "probe-link")
    File.symlink("probe-target", probe)
    true
  rescue NotImplementedError, SystemCallError
    false
  ensure
    FileUtils.rm_f(probe)
  end

  def gzip(bytes)
    out = StringIO.new(+"".b)
    Zlib::GzipWriter.wrap(out) { |gz| gz.write(bytes) }
    out.string
  end

  def piped(bytes)
    reader, writer = IO.pipe
    writer.binmode
    reader.binmode
    thread = Thread.new do
      writer.write(bytes)
    rescue IOError, SystemCallError
      nil
    ensure
      writer.close
    end
    yield reader
  ensure
    reader.close
    thread.join
  end

  def assert_whole_tree(without_long: false)
    assert_equal "z" * 70_000, read("tree/big.txt")
    assert_equal "nested\n", read("tree/dir/nested.txt")
    assert_equal "", read("tree/empty")
    assert_equal "unicode\n", read("tree/héllo.txt")
    assert_equal "hello\n", read("tree/hard")
    assert_equal "hello\n", read("tree/hello.txt")
    assert_equal "deep\n", read("tree/#{LONG}/#{LONG}.txt") unless without_long
  end

  # ---- well-formed archives ----

  def test_extracts_what_gnu_tar_writes
    err = extract(tar("gnu.tar"))

    assert_whole_tree
    assert_match(%r{\AWARNING: skipped symlink 'tree/link' during extract_all\.\n\z}, err)
    refute File.symlink?(File.join(@out, "tree/link"))
    assert_equal STAMP, File.mtime(File.join(@out, "tree/dir/nested.txt"))
    assert_equal STAMP, File.mtime(File.join(@out, "tree/dir"))
  end

  def test_extracts_every_format_and_compression
    %w[pax.tar bsdtar.tar python.tar gnu.tar.gz gnu.tar.zst gnu.tar.xz gnu.tar.bz2].each do |name|
      @out = File.join(@tmp, name)
      extract(tar(name))

      assert_whole_tree
    end
    %w[ustar.tar v7.tar].each do |name|
      @out = File.join(@tmp, name)
      extract(tar(name))

      assert_whole_tree(without_long: true)
    end
  end

  def test_a_hard_link_is_a_link_to_the_file_extracted
    extract(tar("gnu.tar"))

    assert File.identical?(File.join(@out, "tree/hard"), File.join(@out, "tree/hello.txt"))
  end

  def test_returns_nil_and_takes_pathnames
    assert_nil Ziperu::Tar.extract_all(Pathname(tar("ustar.tar")), Pathname(@out), exclude: "tree/link")
    assert_equal "nested\n", read("tree/dir/nested.txt")
  end

  def test_reads_from_an_io_and_a_pipe
    File.open(tar("gnu.tar.zst"), "rb") { |io| extract(io) }

    assert_whole_tree

    @out = File.join(@tmp, "piped")
    piped(File.binread(tar("gnu.tar.xz"))) { |io| extract(io) }

    assert_whole_tree
  end

  def test_fractional_times_are_restored
    extract(tar("pax.tar"))
    seen = nil
    Ziperu::Tar.foreach(tar("pax.tar")) { |e| seen = e.mtime if e.name == "tree/dir/nested.txt" }

    assert_equal seen.to_i, File.mtime(File.join(@out, "tree/dir/nested.txt")).to_i
  end

  def test_permissions_are_restored_without_setuid
    skip "Windows has no permission bits" if WINDOWS
    err = extract(archive(directory("d/", mode: 0o500),
                          entry("d/run", "x", mode: 0o4755),
                          entry("d/secret", "y", mode: 0o600)))

    assert_empty err
    assert_equal 0o755, File.stat(File.join(@out, "d/run")).mode & 0o7777
    assert_equal 0o600, File.stat(File.join(@out, "d/secret")).mode & 0o7777
    assert_equal 0o500, File.stat(File.join(@out, "d")).mode & 0o7777
  end

  def test_the_archive_root_is_the_destination
    err = extract(archive(directory("./"), entry("./a.txt", "a"), directory("./d/"), entry("./d/b.txt", "b")))

    assert_empty err
    assert_equal ["a.txt", "d/", "d/b.txt"], tree
  end

  def test_a_long_name_whose_first_hundred_bytes_end_in_a_slash_is_a_file
    # Found by the fuzzer: the header holds "ddd.../" and the long-name
    # record the rest, which is what says it is a file.
    name = "#{"d" * 99}/file.txt"
    long = entry("././@LongLink", "#{name}\0", type: "L")
    err = extract(archive(long, entry(name[0, 100], "contents"), entry("after", "a")))

    assert_empty err
    assert_equal "contents", read(name)
    assert_equal "a", read("after")
  end

  def test_an_absolute_name_goes_under_the_destination
    err = extract(archive(entry("/etc/passwd", "root")))

    assert_empty err
    assert_equal "root", read("etc/passwd")
  end

  # ---- options ----

  def test_exclude_leaves_entries_out
    extract(tar("gnu.tar"), exclude: ["*.txt", %r{\Atree/link\z}])

    assert_equal ["tree/", "tree/dir/", "tree/empty", "tree/hard", "tree/#{LONG}/"].sort, tree
  end

  def test_strip_components_drops_leading_directories
    err = extract(tar("gnu.tar"), strip_components: 1, exclude: "tree/link")

    assert_empty err
    assert_equal "nested\n", read("dir/nested.txt")
    assert File.identical?(File.join(@out, "hard"), File.join(@out, "hello.txt"))
    refute_path_exists File.join(@out, "tree")

    @out = File.join(@tmp, "two")
    extract(tar("gnu.tar"), strip_components: 2)

    assert_equal ["#{LONG}.txt", "nested.txt"].sort, tree
  end

  def test_sanitize_rewrites_names_windows_refuses
    err = extract(archive(entry("a:b/con.txt", "1"), entry("what?.txt ", "2")), sanitize: :windows)

    assert_empty err
    assert_equal ["a_b/", "a_b/_con.txt", "what_.txt"], tree
  end

  def test_progress_is_told_after_each_entry
    seen = []
    extract(archive(directory("d/"), entry("d/a", "1"), entry("d/b", "2")),
            progress: ->(entry, done, total) { seen << [entry.name, done, total] })

    assert_equal [["d/", 1, nil], ["d/a", 2, nil], ["d/b", 3, nil]], seen
  end

  def test_options_are_checked
    assert_raises(ArgumentError) { Ziperu::Tar.extract_all(tar("gnu.tar"), @out, symlinks: :follow) }
    assert_raises(ArgumentError) { Ziperu::Tar.extract_all(tar("gnu.tar"), @out, sanitize: :linux) }
    assert_raises(ArgumentError) { Ziperu::Tar.extract_all(tar("gnu.tar"), @out, strip_components: -1) }
    assert_raises(ArgumentError) { Ziperu::Tar.extract_all(tar("gnu.tar"), @out, on_exists: :ask) }
    assert_raises(ArgumentError) { Ziperu::Tar.extract_all(tar("gnu.tar"), @out, threads: 2) }
    refute_path_exists @out
  end

  # ---- what is already there, and names given twice ----

  def test_an_existing_file_raises_by_default
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "a"), "mine")

    assert_raises(Ziperu::DestinationExistsError) { extract(archive(entry("a", "theirs"))) }
    assert_equal "mine", read("a")
  end

  def test_on_exists_overwrite_and_skip
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "a"), "mine")
    extract(archive(entry("a", "theirs"), entry("b", "new")), on_exists: :skip)

    assert_equal %w[mine new], [read("a"), read("b")]

    extract(archive(entry("a", "theirs")), on_exists: :overwrite)

    assert_equal "theirs", read("a")
  end

  def test_on_exists_follows_the_setting
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "a"), "mine")
    extract(archive(entry("a", "theirs")), on_exists_proc: true)

    assert_equal "theirs", read("a")
  end

  def test_the_last_entry_of_a_name_wins
    err = extract(archive(entry("a", "first"), entry("b", "b"), entry("a", "second")))

    assert_empty err
    assert_equal "second", read("a")
  end

  def test_a_read_only_file_gives_way_to_a_later_entry_of_its_name
    err = extract(archive(entry("a", "first", mode: 0o444), entry("a", "second", mode: 0o444)))

    assert_empty err
    assert_equal "second", read("a")
    refute File.writable?(File.join(@out, "a")) unless Process.respond_to?(:uid) && Process.uid.zero?
  end

  def test_an_archive_of_nothing_extracts_nothing
    assert_empty extract(StringIO.new("\0" * 10_240))
    assert_nil Ziperu.extract(StringIO.new("\0" * 10_240), @out)
    refute_path_exists @out
  end

  def test_a_name_given_twice_does_not_excuse_a_file_already_there
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "a"), "mine")
    extract(archive(entry("a", "first"), entry("a", "second")), on_exists: :skip)

    assert_equal "mine", read("a")
  end

  # ---- names that lead outside ----

  def test_names_that_resolve_outside_are_skipped
    err = extract(archive(entry("../evil", "x"), entry("a/../../evil", "x"), entry("ok", "fine")))

    assert_equal 2, err.scan("as unsafe.").size
    assert_match(%r{skipped extracting '\.\./evil' to '.*/evil' as unsafe\.}, err)
    assert_equal ["ok"], tree
    assert_equal ["out"], Dir.children(@tmp)
  end

  def test_nothing_is_written_through_a_link_on_disk
    skip "needs symlink support" unless symlinks_supported?
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p([outside, @out])
    File.symlink(outside, File.join(@out, "d"))
    File.write(File.join(outside, "f"), "mine")
    File.symlink(File.join(outside, "f"), File.join(@out, "leaf"))

    err = extract(archive(entry("d/x", "x"), entry("leaf", "theirs")), on_exists: :overwrite)

    assert_equal 2, err.scan("through the link").size
    assert_equal ["f"], Dir.children(outside)
    assert_equal "mine", File.read(File.join(outside, "f"))
  end

  # ---- links ----

  def test_symlinks_are_created_when_asked
    skip "needs symlink support" unless symlinks_supported?
    err = extract(tar("gnu.tar"), symlinks: :create)

    assert_empty err
    assert_equal "hello.txt", File.readlink(File.join(@out, "tree/link"))
    assert_equal "hello\n", read("tree/link")
  end

  def test_symlinks_that_point_outside_are_refused
    skip "needs symlink support" unless symlinks_supported?
    err = extract(archive(entry("up", type: "2", link: "../outside"),
                          entry("abs", type: "2", link: "/etc/passwd"),
                          entry("d/sly", type: "2", link: "x/../y"),
                          entry("d/fine", type: "2", link: "../target"),
                          entry("target", "t")),
                  symlinks: :create)

    assert_equal 2, err.scan("as it points outside the destination.").size
    assert_match(%r{skipped symlink 'd/sly' to 'x/\.\./y' as a '\.\.' after a name}, err)
    assert_equal ["d/", "d/fine", "target"], tree
    assert_equal "t", read("d/fine")
  end

  def test_an_entry_under_a_symlink_of_the_same_archive_does_not_go_through_it
    skip "needs symlink support" unless symlinks_supported?
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(outside)
    extract(archive(entry("d", type: "2", link: outside), entry("d/x", "x")), symlinks: :create)

    assert_empty Dir.children(outside)
    assert_equal "x", read("d/x")
    refute File.symlink?(File.join(@out, "d"))
  end

  def test_a_chain_of_links_cannot_climb_out
    skip "needs symlink support" unless symlinks_supported?
    # Each link is harmless on its own terms; together `c/x` would be
    # the destination's parent if `b/..` were allowed after a name.
    err = extract(archive(directory("d/"),
                          entry("d/a", type: "2", link: "."),
                          entry("d/b", type: "2", link: "a/.."),
                          entry("d/c", type: "2", link: "b/.."),
                          entry("d/c/escaped", "x")),
                  symlinks: :create)

    assert_equal 2, err.scan("as a '..' after a name could lead through a link.").size
    assert_equal ["out"], Dir.children(@tmp)
    refute_path_exists File.join(@tmp, "escaped")
  end

  def test_a_hard_link_is_not_made_through_a_link_on_disk
    skip "needs symlink support" unless symlinks_supported?
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p([outside, @out])
    File.symlink(outside, File.join(@out, "d"))

    err = extract(archive(entry("a", "data"), entry("d/b", type: "1", link: "a")))

    assert_match(%r{skipped extracting 'd/b' through the link '.*/out/d'}, err)
    assert_empty Dir.children(outside)
  end

  def test_a_later_file_takes_the_place_of_a_link_and_a_later_link_of_a_file
    skip "needs symlink support" unless symlinks_supported?
    err = extract(archive(entry("target", "t"),
                          entry("a", type: "2", link: "target"), entry("a", "file"),
                          entry("b", "file"), entry("b", type: "2", link: "target")),
                  symlinks: :create)

    assert_empty err
    refute File.symlink?(File.join(@out, "a"))
    assert_equal "file", read("a")
    assert_equal "target", File.readlink(File.join(@out, "b"))
  end

  def test_a_hard_link_may_come_before_its_target
    err = extract(archive(entry("b", type: "1", link: "a"), entry("a", "data")))

    assert_empty err
    assert_equal "data", read("b")
    assert File.identical?(File.join(@out, "a"), File.join(@out, "b"))
  end

  def test_a_hard_link_to_what_this_run_did_not_write_is_skipped
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "theirs"), "already here")
    File.write(File.join(@tmp, "secret"), "outside")

    err = extract(archive(entry("a", type: "1", link: "theirs"),
                          entry("b", type: "1", link: "../secret"),
                          entry("c", type: "1", link: File.join(@tmp, "secret")),
                          entry("d", type: "1", link: "missing")))

    assert_equal 4, err.scan("its target is not a file this extraction wrote.").size
    assert_equal ["theirs"], tree
  end

  def test_a_hard_link_follows_on_exists
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "b"), "mine")
    source = -> { archive(entry("a", "data"), entry("b", type: "1", link: "a")) }

    assert_raises(Ziperu::DestinationExistsError) { extract(source.call, on_exists: :raise) }
    FileUtils.rm_f(File.join(@out, "a"))

    assert_empty extract(source.call, on_exists: :skip)
    assert_equal "mine", read("b")

    FileUtils.rm_f(File.join(@out, "a"))
    extract(source.call, on_exists: :overwrite)

    assert_equal "data", read("b")
  end

  def test_a_hard_link_outside_is_skipped
    err = extract(archive(entry("a", "data"), entry("../b", type: "1", link: "a")))

    assert_match(%r{skipped extracting '\.\./b' to '.*/b' as unsafe\.}, err)
    assert_equal ["out"], Dir.children(@tmp)
  end

  def test_devices_and_fifos_are_skipped
    err = extract(archive(entry("null", type: "3"), entry("disk", type: "4"), entry("pipe", type: "6"),
                          entry("ok", "fine")))

    assert_match(/skipped 'null': a character device is not extracted\./, err)
    assert_match(/skipped 'disk': a block device is not extracted\./, err)
    assert_match(/skipped 'pipe': a fifo is not extracted\./, err)
    assert_equal ["ok"], tree
  end

  def test_a_name_that_is_not_utf8_is_skipped
    err = extract(archive(entry("caf\xE9.txt".b, "x"), entry("ok", "fine")))

    assert_match(/skipped 'caf\\xE9\.txt': its name is not valid UTF-8\./, err)
    assert_equal ["ok"], tree
  end

  # ---- limits and damage ----

  def test_limits_stop_the_extraction
    source = -> { archive(entry("a", "1"), entry("b", "22"), entry("c", "333")) }

    error = assert_raises(Ziperu::LimitError) { extract(source.call, max_entries: 2) }
    assert_match(/entry count/, error.message)
    assert_equal %w[a b], tree

    @out = File.join(@tmp, "size")
    assert_raises(Ziperu::LimitError) { extract(source.call, max_entry_size: 2) }
    assert_equal %w[a b], tree

    @out = File.join(@tmp, "total")
    assert_raises(Ziperu::LimitError) { extract(source.call, max_total_size: 3) }
    assert_equal %w[a b], tree
  end

  def test_a_bomb_is_stopped_while_it_is_written
    bomb = gzip(archive(entry("zeros", "\0" * (16 << 20))).string)

    assert_raises(Ziperu::LimitError) { extract(StringIO.new(bomb), max_compression_ratio: 100) }
    assert_empty tree
  end

  def test_an_extended_header_too_large_to_hold_is_refused
    record = "path=#{"p" * (2 << 20)}\n"
    huge = entry("PaxHeader", "#{record.bytesize + 9} #{record}", type: "x")

    error = assert_raises(Ziperu::Error) { extract(archive(entry("before", "b"), huge, entry("after", "a"))) }
    assert_match(/extended header of \d+ bytes is over/, error.message)
    assert_equal ["before"], tree
  end

  def test_a_truncated_archive_leaves_no_half_written_file
    bytes = archive(entry("whole", "w" * 2000), entry("cut", "c" * 200_000)).string[0, 100_000]

    error = assert_raises(Ziperu::Error) { extract(StringIO.new(bytes)) }
    assert_match(/cut short/, error.message)
    assert_equal ["whole"], tree
  end

  def test_directories_are_stamped_even_when_the_extraction_fails
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "taken"), "mine")

    assert_raises(Ziperu::DestinationExistsError) do
      extract(archive(directory("d/"), entry("d/a", "1"), entry("taken", "x")))
    end
    assert_equal STAMP, File.mtime(File.join(@out, "d"))
  end

  # ---- Ziperu.extract ----

  def test_extract_tells_a_tar_from_a_zip
    capture_io { assert_nil Ziperu.extract(tar("gnu.tar.gz"), @out) }

    assert_whole_tree

    @out = File.join(@tmp, "plain")
    capture_io { Ziperu.extract(tar("v7.tar"), @out) }

    assert_whole_tree(without_long: true)

    @out = File.join(@tmp, "zip")
    zip = File.join(@tmp, "a.zip")
    Ziperu::File.open(zip, create: true) { |z| z.get_output_stream("dir/a.txt") { |f| f.write("zipped") } }

    assert_nil Ziperu.extract(zip, @out)
    assert_equal "zipped", read("dir/a.txt")
  end

  def test_extract_takes_ios_of_either_kind
    zip = Ziperu::OutputStream.write_buffer { |z| z.put_next_entry("a.txt") && z.write("zipped") }.string

    Ziperu.extract(StringIO.new(zip), @out)

    assert_equal "zipped", read("a.txt")

    @out = File.join(@tmp, "tar")
    io = StringIO.new(gzip(archive(entry("b.txt", "tarred")).string))
    io.read(0)
    Ziperu.extract(io, @out)

    assert_equal "tarred", read("b.txt")

    @out = File.join(@tmp, "file")
    File.open(tar("gnu.tar.bz2"), "rb") { |f| capture_io { Ziperu.extract(f, @out) } }

    assert_whole_tree
  end

  def test_extract_reads_either_kind_from_a_pipe
    zip = Ziperu::OutputStream.write_buffer { |z| z.put_next_entry("a.txt") && z.write("zipped") }.string
    piped(zip) { |io| Ziperu.extract(io, @out) }

    assert_equal "zipped", read("a.txt")

    @out = File.join(@tmp, "tar")
    piped(File.binread(tar("gnu.tar.zst"))) { |io| capture_io { Ziperu.extract(io, @out) } }

    assert_whole_tree

    @out = File.join(@tmp, "limited")
    piped(zip) do |io|
      assert_raises(Ziperu::LimitError) { Ziperu.extract(io, @out, max_archive_size: 50) }
    end
  end

  def test_extract_passes_the_options_on
    capture_io { Ziperu.extract(tar("gnu.tar"), @out, strip_components: 1, exclude: "*.txt") }

    assert_equal ["dir/", "empty", "hard", "#{LONG}/"].sort, tree

    zip = Ziperu::OutputStream.write_buffer do |z|
      z.put_next_entry("a.txt")
      z.put_next_entry("b.log")
    end.string
    @out = File.join(@tmp, "zip")
    Ziperu.extract(StringIO.new(zip), @out, exclude: "*.log", max_entries: 10)

    assert_equal ["a.txt"], tree
    assert_raises(Ziperu::LimitError) { Ziperu.extract(StringIO.new(zip), File.join(@tmp, "no"), max_entries: 1) }
  end

  def test_extract_refuses_what_is_neither
    path = File.join(@tmp, "notes.txt")
    File.write(path, "just some text\n" * 100)

    assert_raises(Ziperu::Error) { Ziperu.extract(path, @out) }
    assert_raises(Ziperu::Error) { Ziperu.extract(StringIO.new(""), @out) }
  end

  # ---- what a header claims ----

  # An extended header for the entry that follows it.
  def pax(records)
    body = records.map do |key, value|
      rest = " #{key}=#{value}\n".b
      length = rest.bytesize + 1
      length += 1 until length.to_s.bytesize + rest.bytesize == length
      length.to_s.b + rest
    end.join
    entry("PaxHeader", body, type: "x")
  end

  def test_a_name_with_a_nul_is_an_invalid_archive
    [archive(pax("path" => "a\0b.txt"), entry("x", "data")),
     archive(pax("linkpath" => "a\0b"), entry("l", type: "2", link: "x")),
     archive(pax("linkpath" => "a\0b"), entry("l", type: "1", link: "x"))].each do |source|
      error = assert_raises(Ziperu::Error) { extract(source, symlinks: :create) }
      assert_match(/extended header's name is not valid/, error.message)
      assert_empty tree
    end
  end

  def test_reading_takes_memory_for_what_is_there_not_for_what_a_header_says
    # Sixteen terabytes, says the header; nine bytes follow.
    bytes = pax("size" => (1 << 44).to_s) + entry("big", "only this")
    error = assert_raises(Ziperu::Error) do
      Ziperu::Tar.foreach(StringIO.new(bytes)) { |e| e.read(e.size) }
    end
    assert_match(/cut short/, error.message)
    assert_raises(Ziperu::Error) { extract(StringIO.new(bytes)) }
  end

  def test_zeros_after_a_compressed_archive_are_padding
    plain = archive(entry("a.txt", "hello")).string
    packed = gzip(plain)
    extract(StringIO.new(packed + ("\0" * 4096)))
    assert_equal "hello", read("a.txt")

    error = assert_raises(Ziperu::Error) { Ziperu::Tar.foreach(StringIO.new("#{packed}\0\0#{"junk" * 9}")).to_a }
    assert_match(/gzip data is corrupt/, error.message)
  end

  def test_a_name_with_a_colon_is_not_written_into_another_files_stream
    skip "a colon is an ordinary character here" unless WINDOWS
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "a.txt"), "there before")
    source = archive(entry("a.txt:evil", "payload"), entry("d/b.txt:x/c", "payload"), entry("C:drive.txt", "payload"),
                     entry("ok.txt", "fine"))
    err = extract(source, symlinks: :create)

    assert_equal 3, err.scan("as unsafe").size, err
    assert_equal %w[a.txt ok.txt], tree
    assert_equal "there before", read("a.txt")
    streams = `powershell -NoProfile -Command "(Get-Item -LiteralPath '#{File.join(@out, "a.txt")}' -Stream *).Stream"`
    assert_equal [":$DATA"], streams.split
  end

  def test_a_name_with_a_colon_is_extracted_once_sanitized
    skip "a colon is an ordinary character here" unless WINDOWS
    extract(archive(entry("a.txt:evil", "payload")), sanitize: :windows)
    assert_equal %w[a.txt_evil], tree
  end
end
