# frozen_string_literal: true

# Ziperu::File's write side: add/remove/rename/replace/mkdir/get_output_stream,
# commit (with raw copies of untouched entries) and write_buffer. Scenarios
# follow rubyzip's file_test.rb against our fixtures.

require_relative "test_helper"
require "tmpdir"

class FileMutationTest < Minitest::Test
  include TestHelper

  def setup
    @tmp = Dir.mktmpdir("ziperu")
    @zip = File.join(@tmp, "work.zip")
    FileUtils.cp(fixture("text.zip"), @zip)
    @src = File.join(@tmp, "src.txt")
    File.binwrite(@src, "source file contents\n")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    Ziperu.reset!
  end

  def test_create_new_archive
    path = File.join(@tmp, "new.zip")
    Ziperu::File.open(path, create: true) do |zf|
      assert_predicate zf, :commit_required?
      zf.get_output_stream("first.txt") { |f| f.puts "Hello from Ziperu::File" }
      zf.mkdir("a_dir")
      zf.add("src.txt", @src)
    end

    Ziperu::File.open(path) do |zf|
      assert_equal %w[first.txt a_dir/ src.txt], zf.map(&:name)
      assert_equal "Hello from Ziperu::File\n", zf.read("first.txt")
      assert_equal "source file contents\n", zf.read("src.txt")
      assert_predicate zf.get_entry("a_dir"), :directory?
      refute_predicate zf, :commit_required?
    end
  end

  def test_open_without_create_on_missing_or_empty_file
    missing = File.join(@tmp, "missing.zip")
    error = assert_raises(Ziperu::Error) { Ziperu::File.open(missing) }
    assert_match(/not found/, error.message)

    File.binwrite(missing, "")
    error = assert_raises(Ziperu::Error) { Ziperu::File.open(missing) }
    assert_match(/zero size/, error.message)
    # ...but create: true is fine with an empty file.
    Ziperu::File.open(missing, create: true) { |zf| zf.add("src.txt", @src) }
    assert_equal 1, Ziperu::File.count_entries(missing)
  end

  def test_add_keeps_existing_entries_as_raw_copies
    before = Ziperu::File.open(@zip) { |zf| zf.get_entry("long.txt") }
    Ziperu::File.open(@zip) { |zf| zf.add("src.txt", @src) }

    Ziperu::File.open(@zip) do |zf|
      after = zf.get_entry("long.txt")
      assert_equal before.compressed_size, after.compressed_size
      assert_equal before.crc, after.crc
      assert_equal before.compression_method, after.compression_method
      assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
      assert_equal "source file contents\n", zf.read("src.txt")
      assert_equal 7, zf.size
    end
  end

  def test_add_existing_entry_raises_unless_continue_proc
    Ziperu::File.open(@zip) do |zf|
      error = assert_raises(Ziperu::EntryExistsError) { zf.add("short.txt", @src) }
      assert_match(/'add' failed. Entry short.txt already exists/, error.message)
      zf.add("short.txt", @src) { true }
      assert_equal 6, zf.size
    end
    Ziperu::File.open(@zip) { |zf| assert_equal "source file contents\n", zf.read("short.txt") }
  end

  def test_add_existing_entry_with_global_setting
    Ziperu.continue_on_exists_proc = true
    Ziperu::File.open(@zip) { |zf| zf.add("short.txt", @src) }
    Ziperu::File.open(@zip) { |zf| assert_equal "source file contents\n", zf.read("short.txt") }
  end

  def test_add_stored
    Ziperu::File.open(@zip) { |zf| zf.add_stored("stored.txt", @src) }
    Ziperu::File.open(@zip) do |zf|
      assert_equal Ziperu::Entry::STORED, zf.get_entry("stored.txt").compression_method
      assert_equal "source file contents\n", zf.read("stored.txt")
    end
  end

  def test_add_directory_from_path
    dir = File.join(@tmp, "adir")
    Dir.mkdir(dir)
    Ziperu::File.open(@zip) { |zf| zf.add("adir", dir) }
    Ziperu::File.open(@zip) { |zf| assert_predicate zf.get_entry("adir/"), :directory? }
  end

  def test_remove
    Ziperu::File.open(@zip) do |zf|
      zf.remove("short.txt")
      zf.remove(zf.get_entry("dir/bin.dat"))
      assert_nil zf.find_entry("short.txt")
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal %w[long.txt empty.txt dir/ crlf.txt], zf.map(&:name)
      assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
    end
    Ziperu::File.open(@zip) { |zf| assert_raises(Errno::ENOENT) { zf.remove("gone") } }
  end

  def test_rename
    Ziperu::File.open(@zip) do |zf|
      zf.rename("short.txt", "renamed.txt")
      assert_raises(Ziperu::EntryExistsError) { zf.rename("long.txt", "renamed.txt") }
      zf.rename("long.txt", "renamed.txt") { true }
    end
    Ziperu::File.open(@zip) do |zf|
      assert_nil zf.find_entry("short.txt")
      assert_nil zf.find_entry("long.txt")
      assert_equal File.binread(fixture("text/long.txt")), zf.read("renamed.txt")
    end
  end

  def test_replace
    Ziperu::File.open(@zip) do |zf|
      zf.replace("short.txt", @src)
      assert_raises(Errno::ENOENT) { zf.replace("empty.txt", File.join(@tmp, "nope")) }
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal "source file contents\n", zf.read("short.txt")
      assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
    end
  end

  def test_mkdir
    Ziperu::File.open(@zip) do |zf|
      zf.mkdir("newdir")
      assert_raises(Errno::EEXIST) { zf.mkdir("newdir") }
      assert_raises(Errno::EEXIST) { zf.mkdir("dir") }
    end
    Ziperu::File.open(@zip) { |zf| assert_predicate zf.get_entry("newdir/"), :directory? }
  end

  def test_get_output_stream
    Ziperu::File.open(@zip) do |zf|
      zf.get_output_stream("newfile.txt", comment: "a comment") { |os| os.write("new content") }
      assert_raises(ArgumentError) { zf.get_output_stream("adir/") }
      # Readable before commit.
      assert_equal "new content", zf.read("newfile.txt")
    end
    Ziperu::File.open(@zip) do |zf|
      assert_equal "new content", zf.read("newfile.txt")
      assert_equal "a comment", zf.get_entry("newfile.txt").comment
    end
  end

  def test_get_output_stream_overwrites_existing_entry
    Ziperu::File.open(@zip) { |zf| zf.get_output_stream("short.txt") { |os| os.write("replaced") } }
    Ziperu::File.open(@zip) do |zf|
      assert_equal "replaced", zf.read("short.txt")
      assert_equal 6, zf.size
    end
  end

  def test_comment
    Ziperu::File.open(@zip) do |zf|
      assert_equal "", zf.comment
      zf.comment = "archive comment"
    end
    Ziperu::File.open(@zip) { |zf| assert_equal "archive comment", zf.comment }
  end

  def test_commit_then_keep_using
    Ziperu::File.open(@zip) do |zf|
      zf.add("src.txt", @src)
      zf.commit
      refute_predicate zf, :commit_required?
      assert_equal "source file contents\n", zf.read("src.txt")
      zf.remove("src.txt")
      zf.commit
      assert_nil zf.find_entry("src.txt")
    end
    Ziperu::File.open(@zip) { |zf| assert_nil zf.find_entry("src.txt") }
  end

  def test_no_commit_when_nothing_changed
    mtime = File.mtime(@zip)
    bytes = File.binread(@zip)
    sleep 0.05
    Ziperu::File.open(@zip) { |zf| zf.read("short.txt") }
    assert_equal bytes, File.binread(@zip)
    assert_equal mtime, File.mtime(@zip)
  end

  def test_commit_preserves_file_permissions
    skip "no unix permissions on Windows" if Ziperu::RUNNING_ON_WINDOWS

    File.chmod(0o640, @zip)
    Ziperu::File.open(@zip) { |zf| zf.add("src.txt", @src) }
    assert_equal 0o640, File.stat(@zip).mode & 0o777
  end

  def test_write_buffer_and_open_buffer
    buffer = Ziperu::File.open(@zip) do |zf|
      zf.add("src.txt", @src)
      zf.write_buffer
    end
    assert_kind_of StringIO, buffer

    Ziperu::File.open_buffer(buffer.string) do |zf|
      assert_equal "source file contents\n", zf.read("src.txt")
      assert_equal File.binread(fixture("text/long.txt")), zf.read("long.txt")
    end
  end

  def test_open_buffer_with_block_writes_back
    io = StringIO.new(File.binread(@zip))
    Ziperu::File.open_buffer(io) { |zf| zf.add("src.txt", @src) }
    Ziperu::File.open_buffer(io.string) { |zf| assert_equal 7, zf.size }
  end

  def test_open_buffer_create
    io = StringIO.new
    Ziperu::File.open_buffer(io, create: true) do |zf|
      zf.get_output_stream("a.txt") { |os| os.write "a" }
    end
    Ziperu::File.open_buffer(io.string) { |zf| assert_equal "a", zf.read("a.txt") }
  end

  def test_open_buffer_rejects_bad_argument
    assert_raises(RuntimeError) { Ziperu::File.open_buffer(42) }
  end

  def test_add_recursive
    src = File.join(@tmp, "tree")
    FileUtils.mkdir_p(File.join(src, "subdir", "deeper"))
    FileUtils.mkdir_p(File.join(src, "empty"))
    File.write(File.join(src, "top.txt"), "top")
    File.write(File.join(src, "subdir", "nested.txt"), "nested")
    File.write(File.join(src, "subdir", "deeper", "deep.txt"), "deep")

    path = File.join(@tmp, "tree.zip")
    Ziperu::File.add_recursive(path, src, prefix: "pre")
    Ziperu::File.open(path) do |zf|
      assert_equal %w[pre/empty/ pre/subdir/ pre/subdir/deeper/ pre/subdir/deeper/deep.txt pre/subdir/nested.txt pre/top.txt],
                   zf.map(&:name)
      assert_equal "deep", zf.read("pre/subdir/deeper/deep.txt")
    end

    shallow = File.join(@tmp, "shallow.zip")
    assert_output("", /max_depth \(1\) reached/) do
      Ziperu::File.open(shallow, create: true) { |zf| zf.add_recursive(src, max_depth: 1) }
    end
    Ziperu::File.open(shallow) { |zf| assert_equal %w[empty/ subdir/ top.txt], zf.map(&:name) }

    Ziperu::File.open(@zip) do |zf|
      assert_raises(Errno::ENOENT) { zf.add_recursive(File.join(@tmp, "nope")) }
      assert_raises(ArgumentError) { zf.add_recursive(src, max_depth: 0) }
    end
  end

  def test_sort_entries_and_case_insensitive_match
    Ziperu.sort_entries = true
    Ziperu::File.open(@zip) do |zf|
      assert_equal %w[crlf.txt dir/ dir/bin.dat empty.txt long.txt short.txt], zf.map(&:name)
      assert_nil zf.find_entry("SHORT.TXT")
    end
    Ziperu.case_insensitive_match = true
    Ziperu::File.open(@zip) { |zf| assert_equal "short.txt", zf.find_entry("SHORT.TXT").name }
  end

  def test_glob
    Ziperu::File.open(@zip) do |zf|
      assert_equal %w[crlf.txt empty.txt long.txt short.txt], zf.glob("*.txt").map(&:name).sort
      assert_equal %w[dir/bin.dat], zf.glob("dir/*").map(&:name)
      yielded = []
      zf.glob("*.txt") { |e| yielded << e.name }
      assert_equal 4, yielded.size
    end
  end

  def test_count_entries
    assert_equal 6, Ziperu::File.count_entries(@zip)
    File.open(@zip, "rb") { |f| assert_equal 6, Ziperu::File.count_entries(f) }
  end

  # Edits the native raw copy cannot carry are written by re-streaming the
  # entry; a chmod or a rename alone still copies the data as is.
  def test_metadata_edits_persist_through_commit
    stamp = Time.utc(2001, 2, 3, 4, 5, 6)
    Ziperu::File.open(@zip) do |zf|
      zf.get_entry("long.txt").comment = "edited"
      e = zf.get_entry("short.txt")
      e.time = stamp
      zf.rename(e, "stamped.txt")
      zf.get_entry("crlf.txt").unix_perms = 0o600
    end
    Ziperu::File.open(@zip) do |zf|
      long = zf.get_entry("long.txt")
      assert_equal "edited", long.comment
      stamped = zf.get_entry("stamped.txt")
      # DOS times are wall-clock fields; the zone they come back in is local.
      assert_equal stamp.strftime("%F %T"), stamped.time.strftime("%F %T")
      assert_predicate stamped.time, :absolute_time?, "the extended timestamp was written too"
      assert_equal 0o600, zf.get_entry("crlf.txt").unix_perms
      assert_equal "short\n", zf.read("stamped.txt")
    end
  end

  def test_host_system_survives_a_rewrite
    unix = File.join(@tmp, "unix.zip")
    FileUtils.cp(fixture("rubyzip/zipWithDirs.zip"), unix)
    Ziperu::File.open(unix) { |zf| zf.get_entry("dir1/file11").comment = "c" }
    Ziperu::File.open(unix) do |zf|
      e = zf.get_entry("dir1/file11")
      assert_equal Ziperu::FSTYPE_UNIX, e.fstype
      assert_equal "c", e.comment
    end
  end

  def test_written_archive_is_valid_for_python
    Ziperu::File.open(@zip) do |zf|
      zf.add("src.txt", @src)
      zf.rename("short.txt", "renamed.txt")
      zf.remove("empty.txt")
      zf.comment = "hi"
    end
    out = `python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); print(z.testzip()); print(z.comment.decode()); print(sorted(z.namelist()))" "#{@zip}"`
    skip "python not available" unless $CHILD_STATUS.success?

    assert_equal ["None", "hi", "['crlf.txt', 'dir/', 'dir/bin.dat', 'long.txt', 'renamed.txt', 'src.txt']"],
                 out.lines.map(&:chomp)
  end
end
