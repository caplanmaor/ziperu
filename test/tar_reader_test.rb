# frozen_string_literal: true

require_relative "test_helper"
require "rubygems/package"
require "tmpdir"

# Ziperu::Tar: archives written by GNU tar, bsdtar and Python (the
# fixtures under test/data/tar, see make.sh there) and by RubyGems' own
# writer, read entry by entry.
class TarReaderTest < Minitest::Test
  include TestHelper

  LONG = "n" * 150

  # What every fixture made from the whole tree holds: name => data, or
  # the entry's type where it has none.
  TREE = {
    "tree/"                    => :directory,
    "tree/big.txt"             => "z" * 70_000,
    "tree/dir/"                => :directory,
    "tree/dir/nested.txt"      => "nested\n",
    "tree/empty"               => "",
    "tree/héllo.txt"           => "unicode\n",
    "tree/link"                => :symlink,
    "tree/#{LONG}/"            => :directory,
    "tree/#{LONG}/#{LONG}.txt" => "deep\n"
  }.freeze

  def tar(name)
    fixture(File.join("tar", name))
  end

  # name => data (or type) for every entry, with the hardlinked pair
  # (which of the two is the link depends on the writer) taken out and
  # returned apart.
  def contents(source, **options)
    seen = {}
    Ziperu::Tar.foreach(source, **options) do |entry|
      seen[entry.name] = entry.file? ? entry.read : entry.type
    end
    pair = [seen.delete("tree/hard"), seen.delete("tree/hello.txt")]
    [seen, pair]
  end

  def assert_whole_tree(source, without_long: false)
    seen, pair = contents(source)
    expected = without_long ? TREE.reject { |name, _| name.include?(LONG) } : TREE
    assert_equal expected.keys.sort, seen.keys.sort
    expected.each do |name, data|
      assert_equal data, seen.fetch(name), name
    end
    assert_equal ["hello\n", :hardlink], pair.sort_by(&:to_s).reverse
  end

  # A tar archive from RubyGems' writer: name => data, a name ending in
  # a slash being a directory.
  def build_tar(files)
    io = StringIO.new(+"".b)
    Gem::Package::TarWriter.new(io) do |writer|
      files.each do |name, data|
        if name.end_with?("/")
          writer.mkdir(name.chomp("/"), 0o755)
        else
          writer.add_file_simple(name, 0o644, data.bytesize) { |f| f.write(data) }
        end
      end
    end
    io.string
  end

  def gzip(bytes)
    out = StringIO.new(+"".b)
    Zlib::GzipWriter.wrap(out) { |gz| gz.write(bytes) }
    out.string
  end

  # `bytes` on the read end of a pipe, written from a thread.
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

  def test_reads_what_gnu_tar_writes
    assert_whole_tree(tar("gnu.tar"))
  end

  def test_reads_the_pax_format
    assert_whole_tree(tar("pax.tar"))
  end

  def test_reads_ustar_with_names_split_across_the_prefix
    assert_whole_tree(tar("ustar.tar"), without_long: true)
  end

  def test_reads_the_v7_format
    assert_whole_tree(tar("v7.tar"), without_long: true)
  end

  def test_reads_what_bsdtar_writes
    assert_whole_tree(tar("bsdtar.tar"))
  end

  def test_reads_what_python_writes
    assert_whole_tree(tar("python.tar"))
  end

  def test_reads_every_compression_and_tells_which_from_the_bytes
    { "gnu.tar" => :none, "gnu.tar.gz" => :gzip, "gnu.tar.zst" => :zstd,
      "gnu.tar.xz" => :xz, "gnu.tar.bz2" => :bzip2 }.each do |name, compression|
      assert_whole_tree(tar(name))
      Ziperu::Tar::Reader.open(tar(name)) { |reader| assert_equal compression, reader.compression, name }
    end
  end

  def test_the_name_of_the_file_does_not_decide_the_compression
    Dir.mktmpdir do |dir|
      disguised = File.join(dir, "archive.tar")
      FileUtils.cp(tar("gnu.tar.zst"), disguised)
      assert_whole_tree(disguised)
    end
  end

  def test_gzip_members_end_to_end_are_one_archive
    assert_whole_tree(tar("gnu-two-members.tar.gz"))
  end

  def test_an_entry_says_what_its_header_says
    entries = Ziperu::Tar.foreach(tar("pax.tar")).to_h { |entry| [entry.name, entry] }

    nested = entries.fetch("tree/dir/nested.txt")
    assert_predicate nested, :file?
    assert_equal 7, nested.size
    assert_equal 0o600, nested.mode
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5, 123_456.789r), nested.mtime
    assert_equal 0, nested.uid
    assert_nil nested.link_target

    link = entries.fetch("tree/link")
    assert_predicate link, :symlink?
    assert_equal "hello.txt", link.link_target
    assert_equal 0, link.size

    assert_predicate entries.fetch("tree/dir/"), :directory?
    assert_equal "tree/hard", entries.fetch("tree/hello.txt").link_target
    assert_predicate entries.fetch("tree/hello.txt"), :hardlink?
    assert_equal '#<Ziperu::Tar::Entry "tree/empty" file size=0>', entries.fetch("tree/empty").inspect
  end

  def test_names_are_utf8_when_they_can_be_and_bytes_when_not
    names = Ziperu::Tar.foreach(tar("gnu.tar")).map(&:name)
    unicode = names.find { |name| name.include?("llo.txt") && !name.ascii_only? }
    assert_equal Encoding::UTF_8, unicode.encoding
    assert_equal "tree/héllo.txt", unicode

    latin1 = "caf\xE9.txt".b
    entry = Ziperu::Tar.foreach(StringIO.new(build_tar(latin1 => "x"))).first
    assert_equal Encoding::BINARY, entry.name.encoding
    assert_equal latin1, entry.name
  end

  def test_fractional_times_come_from_the_extended_header
    python = Ziperu::Tar.foreach(tar("python.tar")).first
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5.5r), python.mtime
    gnu = Ziperu::Tar.foreach(tar("gnu.tar")).first
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5), gnu.mtime
  end

  def test_a_global_header_ahead_of_the_entries_is_read_past
    entries = Ziperu::Tar.foreach(tar("global-header.tar")).map { |entry| [entry.name, entry.read] }
    assert_equal [["tree/hello.txt", "hello\n"]], entries
  end

  def test_sparse_files_are_refused
    %w[sparse.tar sparse-pax.tar].each do |name|
      error = assert_raises(Ziperu::Error) { Ziperu::Tar.foreach(tar(name)).to_a }
      assert_equal "sparse files in a tar archive are not supported", error.message, name
    end
  end

  def test_reads_what_rubygems_writes
    deep = "#{"d" * 90}/#{"e" * 90}/file.txt"
    files = { "a.txt" => "alpha", "dir/" => nil, "dir/b.bin" => Random.new(1).bytes(3000), deep => "deep" }
    seen = {}
    Ziperu::Tar.foreach(StringIO.new(build_tar(files))) do |entry|
      seen[entry.name] = entry.file? ? entry.read : nil
    end
    assert_equal files.transform_keys { |name| name.chomp("/") }, seen
  end

  def test_foreach_without_a_block_is_an_enumerator
    names = Ziperu::Tar.foreach(tar("gnu.tar.gz"))
    assert_kind_of Enumerator, names
    assert_equal 11, names.count
    assert_equal "tree/", names.first.name
  end

  def test_reads_from_a_file_object_a_string_io_and_a_pipe
    bytes = File.binread(tar("gnu.tar.xz"))
    File.open(tar("gnu.tar.xz"), "rb") { |file| assert_whole_tree(file) }
    assert_whole_tree(StringIO.new(bytes))
    piped(bytes) { |pipe| assert_whole_tree(pipe) }
    piped(File.binread(tar("gnu.tar"))) { |pipe| assert_whole_tree(pipe) }
  end

  def test_takes_a_pathname
    assert_whole_tree(Pathname.new(tar("gnu.tar")))
  end

  def test_data_is_read_in_pieces_and_what_is_left_is_skipped
    Ziperu::Tar::Reader.open(tar("gnu.tar")) do |reader|
      reader.next_entry
      big = reader.next_entry
      assert_equal "tree/big.txt", big.name
      refute_predicate big, :eof?
      assert_equal "z" * 10, big.read(10)
      assert_equal Encoding::BINARY, big.read(5).encoding
      assert_equal 15, big.pos
      assert_equal "", big.read(0)
      # The rest is left unread: the next entry is found all the same.
      assert_equal "tree/dir/", reader.next_entry.name
      nested = reader.next_entry
      assert_equal "nested\n", nested.read
      assert_predicate nested, :eof?
      assert_equal "", nested.read
      assert_nil nested.read(10)
    end
  end

  def test_each_chunk_yields_the_data_in_pieces
    Ziperu::Tar.foreach(tar("gnu.tar.bz2")) do |entry|
      next unless entry.name == "tree/big.txt"

      sizes = entry.each_chunk(32_000).map(&:bytesize)
      assert_equal [32_000, 32_000, 6_000], sizes
    end
  end

  def test_an_entry_cannot_be_read_once_the_archive_has_moved_on
    first = nil
    Ziperu::Tar.foreach(tar("gnu.tar")) do |entry|
      first ||= entry if entry.file?
    end
    error = assert_raises(IOError) { first.read }
    assert_match(%r{tree/big\.txt.*moved past it}, error.message)
    assert_equal 70_000, first.size
  end

  def test_a_closed_reader_raises
    reader = Ziperu::Tar::Reader.open(tar("gnu.tar"))
    entry = reader.next_entry
    reader.close
    assert_raises(IOError) { reader.next_entry }
    assert_raises(IOError) { entry.read }
  end

  def test_the_io_is_left_open
    File.open(tar("gnu.tar"), "rb") do |file|
      Ziperu::Tar.foreach(file) { |entry| entry }
      refute_predicate file, :closed?
    end
  end

  def test_an_unknown_keyword_is_refused
    error = assert_raises(ArgumentError) { Ziperu::Tar.foreach(tar("gnu.tar"), threads: 2) { |entry| entry } }
    assert_match(/unknown keyword: :threads/, error.message)
  end

  def test_what_is_not_a_tar_archive_is_refused
    Dir.mktmpdir do |dir|
      { "empty" => "", "short" => "hello", "noise" => Random.new(2).bytes(4096),
        "one zero block" => "\0" * 512, "zeros, then not" => ("\0" * 512) + ("x" * 512) }.each do |name, bytes|
        path = File.join(dir, name)
        File.binwrite(path, bytes)
        error = assert_raises(Ziperu::Error, name) { Ziperu::Tar.foreach(path).to_a }
        assert_equal "invalid tar archive: not a tar archive", error.message, name
      end
    end
    assert_raises(Errno::ENOENT) { Ziperu::Tar.foreach("no-such-file.tar").to_a }
    assert_raises(TypeError) { Ziperu::Tar.foreach(12).to_a }
  end

  def test_an_archive_of_nothing_has_no_entries
    # What `tar -cf empty.tar -T /dev/null` writes: twenty zero blocks.
    assert_empty Ziperu::Tar.foreach(StringIO.new("\0" * 10_240)).to_a
    assert_empty Ziperu::Tar.foreach(StringIO.new(gzip("\0" * 1024))).to_a
  end

  def test_a_truncated_archive_is_refused
    whole = File.binread(tar("gnu.tar"))
    [700, 5000, 60_000].each do |length|
      names = []
      error = assert_raises(Ziperu::Error, length.to_s) do
        Ziperu::Tar.foreach(StringIO.new(whole[0, length])) { |entry| names << entry.name }
      end
      assert_equal "invalid tar archive: the archive is cut short", error.message, length.to_s
      refute_empty names
    end
  end

  def test_an_archive_with_no_end_marker_ends_at_its_last_entry
    bytes = build_tar("a.txt" => "alpha")
    assert_equal 1024 + 1024, bytes.bytesize
    assert_equal ["a.txt"], Ziperu::Tar.foreach(StringIO.new(bytes[0, 1024])).map(&:name)
  end

  def test_corrupt_compressed_data_is_refused
    %w[gnu.tar.gz gnu.tar.zst gnu.tar.xz gnu.tar.bz2].each do |name|
      bytes = File.binread(tar(name))
      middle = bytes.bytesize / 2
      8.times { |i| bytes.setbyte(middle + i, bytes.getbyte(middle + i) ^ 0xFF) }
      error = assert_raises(Ziperu::Error, name) do
        Ziperu::Tar.foreach(StringIO.new(bytes)) { |entry| entry.read if entry.file? }
      end
      assert_match(/\Ainvalid tar archive: /, error.message, name)
    end
  end

  def test_a_header_with_a_bad_checksum_is_refused
    bytes = build_tar("a.txt" => "alpha", "b.txt" => "beta")
    bytes.setbyte(1024 + 3, "X".ord)
    error = assert_raises(Ziperu::Error) { Ziperu::Tar.foreach(StringIO.new(bytes)).to_a }
    assert_equal "invalid tar archive: a header's checksum does not match (at offset 1024)", error.message
  end

  def test_nothing_more_is_read_after_a_failure
    reader = Ziperu::Tar::Reader.open(StringIO.new(File.binread(tar("gnu.tar"))[0, 5000]))
    assert_raises(Ziperu::Error) { reader.each { |entry| entry } }
    error = assert_raises(IOError) { reader.next_entry }
    assert_equal "the tar reader failed earlier and cannot go on", error.message
  end

  def test_an_exception_from_the_io_comes_through
    broken = Object.new
    def broken.read(_length) = raise(Errno::ECONNRESET)
    assert_raises(Errno::ECONNRESET) { Ziperu::Tar.foreach(broken).to_a }
  end

  def test_entry_limits
    path = tar("gnu.tar")
    error = assert_raises(Ziperu::LimitError) { Ziperu::Tar.foreach(path, max_entries: 5).to_a }
    assert_equal "archive has an entry count of 6, over the limit of 5", error.message

    error = assert_raises(Ziperu::LimitError) { Ziperu::Tar.foreach(path, max_entry_size: 69_999).to_a }
    assert_equal "archive has an entry with a declared size of 70000, over the limit of 69999", error.message

    error = assert_raises(Ziperu::LimitError) { Ziperu::Tar.foreach(path, max_total_size: 70_010).to_a }
    assert_equal "archive has a declared total size of 70013, over the limit of 70010", error.message

    assert_equal 11, Ziperu::Tar.foreach(path, max_entries: 11, max_entry_size: 70_000, max_total_size: 70_026).count
    assert_equal 11, Ziperu::Tar.foreach(path, **Ziperu::Limits::UPLOAD).count
  end

  def test_limits_follow_the_globals
    Ziperu.max_entries = 3
    assert_raises(Ziperu::LimitError) { Ziperu::Tar.foreach(tar("gnu.tar")).to_a }
    assert_equal 11, Ziperu::Tar.foreach(tar("gnu.tar"), max_entries: nil).count
  ensure
    Ziperu.max_entries = nil
  end

  def test_the_compression_ratio_limit_stops_a_bomb_as_it_is_read
    bomb = gzip(build_tar("zeros" => "\0" * (16 << 20)))
    assert_operator bomb.bytesize, :<, 32_000

    read = 0
    error = assert_raises(Ziperu::LimitError) do
      Ziperu::Tar.foreach(StringIO.new(bomb), max_compression_ratio: 100) do |entry|
        entry.each_chunk(65_536) { |chunk| read += chunk.bytesize }
      end
    end
    assert_match(/\Aarchive has a compression ratio of \d+\.\d, over the limit of 100\.0\z/, error.message)
    # Stopped a few megabytes in, not at the end.
    assert_operator read, :<, 8 << 20

    # Unread, the entry is skipped: the limit holds there too.
    assert_raises(Ziperu::LimitError) do
      Ziperu::Tar.foreach(StringIO.new(bomb), max_compression_ratio: 100).to_a
    end
    assert_equal ["zeros"], Ziperu::Tar.foreach(StringIO.new(bomb)).map(&:name)
  end

  def test_a_small_archive_is_not_taken_for_a_bomb
    small = gzip(build_tar("a.txt" => "a"))
    assert_operator 2048.fdiv(small.bytesize), :>, 10
    assert_equal ["a.txt"], Ziperu::Tar.foreach(StringIO.new(small), max_compression_ratio: 10).map(&:name)
  end

  def test_the_archive_size_limit_counts_what_is_read_from_the_input
    bytes = File.binread(tar("gnu.tar"))
    error = assert_raises(Ziperu::LimitError) do
      Ziperu::Tar.foreach(StringIO.new(bytes), max_archive_size: 70_000) { |entry| entry.read if entry.file? }
    end
    assert_match(/\Aarchive has an archive size of \d+, over the limit of 70000\z/, error.message)
    assert_equal 11, Ziperu::Tar.foreach(StringIO.new(bytes), max_archive_size: bytes.bytesize).count
  end

  def test_other_threads_run_while_a_large_entry_is_skipped
    # Under valgrind threads take turns, whatever is released.
    return if ENV["RUBY_MEMCHECK_RUNNING"]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.tar.gz")
      File.binwrite(path, gzip(build_tar("zeros" => "\0" * (64 << 20), "after" => "x")))
      # A thread that only counts gets nowhere while another holds the
      # GVL, and a long way in the tens of milliseconds the skip takes.
      ticks = 0
      ticker = Thread.new { loop { ticks += 1 } }
      Ziperu::Tar::Reader.open(path) do |reader|
        assert_equal "zeros", reader.next_entry.name
        before = ticks
        assert_equal "after", reader.next_entry.name
        assert_operator ticks - before, :>, 10_000
      end
    ensure
      ticker&.kill
    end
  end
end
