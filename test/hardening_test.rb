# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "pathname"
require "stringio"

# Regressions from the review round after 0.1.1: ZipCrypto headers and
# copies, Pathname arguments, failed commits, entry order, extraction of
# uncommitted entries and the InputStream's error swallowing.
class HardeningTest < Minitest::Test
  include TestHelper

  PASSWORD = "s3cret"

  def setup
    @dir = Dir.mktmpdir("ziperu-hardening")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def path(name)
    File.join(@dir, name)
  end

  def write_zipcrypto(file, entries = { "a.txt" => "hello zipcrypto " * 100, "b.bin" => Random.new(7).bytes(50_000) })
    enc = Ziperu::TraditionalEncrypter.new(PASSWORD)
    Ziperu::OutputStream.open(file, encrypter: enc) do |z|
      entries.each do |name, data|
        z.put_next_entry(name)
        z.write(data)
      end
    end
    entries
  end

  def read_encrypted(file, name)
    Ziperu::File.open(file) do |zf|
      zf.get_entry(name).get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new(PASSWORD), &:read)
    end
  end

  # Parses the local header at `offset`; returns the fields and the bytes
  # that follow the entry's data.
  def local_header(bytes, offset, compressed_size)
    sig, _ver, flags, method, _t, _d, crc, csize, usize, nlen, xlen =
      bytes.byteslice(offset, 30).unpack("VvvvvvVVVvv")
    assert_equal Ziperu::LOCAL_ENTRY_SIGNATURE, sig
    data_end = offset + 30 + nlen + xlen + compressed_size
    { flags: flags, method: method, crc: crc, csize: csize, usize: usize, after: bytes.byteslice(data_end, 16) }
  end

  # --- ZipCrypto -----------------------------------------------------------

  def test_zipcrypto_entries_carry_a_data_descriptor
    file = path("zc.zip")
    data = write_zipcrypto(file)
    bytes = File.binread(file)
    Ziperu::File.open(file) do |zf|
      data.each do |name, plain|
        e = zf.get_entry(name)
        hdr = local_header(bytes, e.local_header_offset, e.compressed_size)
        assert_equal 9, hdr[:flags], "#{name}: encrypted + bit 3"
        assert_equal Ziperu::Entry::DEFLATED, hdr[:method]
        assert_equal e.crc, hdr[:crc]
        assert_equal e.compressed_size, hdr[:csize], "local header holds the real compressed size"
        assert_equal plain.bytesize, hdr[:usize]
        assert_equal plain.bytesize, e.size
        # The descriptor: signature, CRC, compressed size, uncompressed size.
        assert_equal [0x08074b50, e.crc, e.compressed_size, plain.bytesize], hdr[:after].unpack("V4")
      end
    end
    data.each { |name, plain| assert_equal plain.b, read_encrypted(file, name).b }
  end

  def test_zipcrypto_compressed_size_is_reported_to_the_entry
    file = path("zc.zip")
    enc = Ziperu::TraditionalEncrypter.new(PASSWORD)
    written = nil
    Ziperu::OutputStream.open(file, encrypter: enc) do |z|
      written = z.put_next_entry("a.txt")
      z.write("x" * 1000)
    end
    Ziperu::File.open(file) do |zf|
      e = zf.get_entry("a.txt")
      assert_equal e.compressed_size, written.compressed_size
      assert_equal e.size, written.size
      assert_equal e.crc, written.crc
    end
  end

  def test_zipcrypto_entry_survives_a_commit_that_copies_it
    file = path("zc.zip")
    data = write_zipcrypto(file)
    Ziperu::File.open(file) do |zf|
      zf.get_output_stream("plain.txt") { |o| o.write "plain" }
      zf.rename("b.bin", "renamed.bin")
      zf.get_entry("a.txt").unix_perms = 0o600
    end
    assert_equal data["a.txt"].b, read_encrypted(file, "a.txt").b
    assert_equal data["b.bin"].b, read_encrypted(file, "renamed.bin").b
    bytes = File.binread(file)
    Ziperu::File.open(file) do |zf|
      assert_equal "plain", zf.read("plain.txt")
      e = zf.get_entry("renamed.bin")
      assert_equal 9, e.gp_flags & 9
      assert_equal 0o600, zf.get_entry("a.txt").unix_perms
      hdr = local_header(bytes, e.local_header_offset, e.compressed_size)
      assert_equal 9, hdr[:flags]
      assert_equal [0x08074b50, e.crc, e.compressed_size, e.size], hdr[:after].unpack("V4")
      assert_empty zf.verify(decrypter: Ziperu::TraditionalDecrypter.new(PASSWORD))
    end
  end

  def test_zipcrypto_entry_without_bit_3_is_copied_without_a_descriptor
    # An archive written by a tool that seeks back (Info-ZIP's zip): bit 3
    # clear, check byte from the CRC. Flip ours into that shape.
    file = path("zc.zip")
    data = write_zipcrypto(file, "a.txt" => "plain text " * 50)
    bytes = File.binread(file)
    Ziperu::File.open(file) do |zf|
      e = zf.get_entry("a.txt")
      off = e.local_header_offset
      # Clear bit 3 in both headers and re-key the check byte: not possible
      # without the keys, so only assert that the copy keeps the flags it
      # was given.
      bytes.setbyte(off + 6, bytes.getbyte(off + 6) & ~8)
      cd = bytes.rindex([Ziperu::CENTRAL_DIRECTORY_ENTRY_SIGNATURE].pack("V"))
      bytes.setbyte(cd + 8, bytes.getbyte(cd + 8) & ~8)
    end
    File.binwrite(file, bytes)
    # A rewrite (an addition alone would append, copying nothing).
    Ziperu::File.open(file) do |zf|
      zf.get_output_stream("x") { |o| o.write "x" }
      zf.comment = "rewritten"
    end
    Ziperu::File.open(file) do |zf|
      e = zf.get_entry("a.txt")
      assert_equal 1, e.gp_flags & 9
      hdr = local_header(File.binread(file), e.local_header_offset, e.compressed_size)
      assert_equal 1, hdr[:flags] & 9
      refute_equal 0x08074b50, hdr[:after].unpack1("V")
      assert_equal data["a.txt"].bytesize, e.size
    end
  end

  def test_copy_raw_entry_of_a_zipcrypto_entry
    src = path("src.zip")
    data = write_zipcrypto(src)
    dst = path("dst.zip")
    Ziperu::File.open(src) do |zf|
      Ziperu::OutputStream.open(dst) do |os|
        os.copy_raw_entry(zf.get_entry("a.txt"))
        os.copy_raw_entry(zf.get_entry("b.bin"), "c.bin")
      end
    end
    assert_equal data["a.txt"].b, read_encrypted(dst, "a.txt").b
    assert_equal data["b.bin"].b, read_encrypted(dst, "c.bin").b
  end

  def test_zipcrypto_allows_only_stored_and_deflated
    enc = Ziperu::TraditionalEncrypter.new(PASSWORD)
    e = assert_raises(ArgumentError) do
      Ziperu::OutputStream.write_buffer(encrypter: enc) do |z|
        z.put_next_entry("a", "", Ziperu::ExtraField.new, Ziperu::Entry::BZIP2)
      end
    end
    assert_match(/Stored or Deflated/, e.message)
    io = Ziperu::OutputStream.write_buffer(encrypter: enc) do |z|
      z.put_next_entry("s", "", Ziperu::ExtraField.new, Ziperu::Entry::STORED)
      z.write "stored"
    end
    Ziperu::File.open_buffer(io.string) do |zf|
      e = zf.get_entry("s")
      assert_equal Ziperu::Entry::STORED, e.compression_method
      assert_equal 6 + 12, e.compressed_size
      assert_equal "stored", e.get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new(PASSWORD), &:read)
    end
  end

  def test_zipcrypto_into_a_write_only_io_explains_itself
    file = path("wo.zip")
    enc = Ziperu::TraditionalEncrypter.new(PASSWORD)
    e = assert_raises(Ziperu::Error) do
      File.open(file, "wb") do |f|
        Ziperu::OutputStream.write_buffer(f, encrypter: enc) do |z|
          z.put_next_entry("a")
          z.write "abc"
        end
      end
    end
    assert_match(/reading and writing/, e.message)
    File.open(file, "w+b") do |f|
      Ziperu::OutputStream.write_buffer(f, encrypter: enc) do |z|
        z.put_next_entry("a")
        z.write "abc"
      end
    end
    assert_equal "abc", read_encrypted(file, "a")
  end

  # --- OutputStream ---------------------------------------------------------

  def test_output_stream_open_returns_the_block_value_and_aborts_on_error
    assert_equal 42, Ziperu::OutputStream.open(path("r.zip")) { |z|
      z.put_next_entry("x")
      42
    }
    entry = Ziperu::Entry.new("", "x")
    assert_raises(RuntimeError) do
      Ziperu::OutputStream.open(path("abort.zip")) do |z|
        z.put_next_entry(entry)
        z.write("abc")
        raise "boom"
      end
    end
    assert_equal 0, entry.crc, "an abandoned archive leaves the entry alone"
  end

  def test_duplicate_name_in_a_stream_is_an_entry_exists_error
    e = assert_raises(Ziperu::EntryExistsError) do
      Ziperu::OutputStream.write_buffer do |z|
        z.put_next_entry("t")
        z.put_next_entry("t")
      end
    end
    assert_match(/put_next_entry.*t already exists/, e.message)
  end

  def test_writing_data_to_a_directory_entry_raises
    e = assert_raises(Ziperu::Error) do
      Ziperu::OutputStream.write_buffer do |z|
        z.put_next_entry("dir/")
        z.write "x"
      end
    end
    assert_match(%r{directory entry 'dir/'}, e.message)
  end

  def test_shrinking_an_archive_in_a_string_io_truncates_it
    sio = StringIO.new(+"")
    Ziperu::File.open_buffer(sio, create: true) do |zf|
      zf.get_output_stream("big") { |o| o.write Random.new(1).bytes(20_000) }
      zf.get_output_stream("small") { |o| o.write "s" }
    end
    before = sio.string.bytesize
    Ziperu::File.open_buffer(sio) { |zf| zf.remove("big") }
    assert_operator sio.string.bytesize, :<, before
    assert_equal 1, Ziperu::File.count_entries(StringIO.new(sio.string))
    assert_equal sio.string.bytesize, sio.string.rindex([Ziperu::CentralDirectory::END_OF_CD_SIG].pack("V")) + 22
  end

  def test_open_buffer_over_the_archives_own_file_handle
    file = path("rw.zip")
    Ziperu::File.open(file, create: true) do |zf|
      zf.get_output_stream("first.txt") { |o| o.write "first" }
      zf.get_output_stream("second.bin") { |o| o.write Random.new(2).bytes(200_000) }
    end
    second = Ziperu::File.open(file) { |zf| zf.read("second.bin") }
    File.open(file, "r+b") do |f|
      Ziperu::File.open_buffer(f) do |zf|
        zf.get_output_stream("first.txt") { |o| o.write("X" * 100_000) }
      end
    end
    Ziperu::File.open(file) do |zf|
      assert_equal "X" * 100_000, zf.read("first.txt")
      assert_equal second, zf.read("second.bin")
      assert_empty zf.verify
    end
  end

  # --- Pathname -----------------------------------------------------------------

  def test_pathname_arguments
    pn = Pathname.new(fixture("text.zip"))
    names = Ziperu::File.open(pn) { |zf| zf.entries.map(&:name) }
    assert_includes names, "short.txt"
    assert_equal "short\n", Ziperu::File.open(pn) { |zf| zf.read("short.txt") }
    streamed = []
    Ziperu::InputStream.open(pn) do |is|
      while (e = is.get_next_entry)
        streamed << e.name
      end
    end
    assert_equal names.sort, streamed.sort
    assert_equal names.size, Ziperu::File.count_entries(pn)
    out = Pathname.new(path("new.zip"))
    Ziperu::File.open(out, create: true) { |zf| zf.get_output_stream("a") { |o| o.write "a" } }
    Ziperu::File.open(out) do |zf|
      zf.rename("a", Pathname.new("b"))
    end
    assert_equal "a", Ziperu::File.open(out.to_s) { |zf| zf.read("b") }
  end

  # --- InputStream ---------------------------------------------------------------

  def test_truncated_archive_raises_instead_of_yielding_nothing
    bytes = File.binread(fixture("text.zip"))
    cut = bytes.byteslice(0, bytes.bytesize - 40)
    assert_raises(Ziperu::Error) { Ziperu::InputStream.open(StringIO.new(cut), &:get_next_entry) }
    File.binwrite(path("cut.zip"), cut)
    assert_raises(Ziperu::Error) { Ziperu::InputStream.open(path("cut.zip"), &:get_next_entry) }
    # Something that is not an archive at all still yields no entries.
    Ziperu::InputStream.open(StringIO.new("just some text")) { |is| assert_nil is.get_next_entry }
  end

  def test_offset_off_an_entry_raises
    e = assert_raises(Ziperu::Error) { Ziperu::InputStream.open(fixture("text.zip"), offset: 3) }
    assert_match(/offset 3/, e.message)
  end

  def test_read_with_a_non_integer_length
    Ziperu::InputStream.open(fixture("text.zip")) do |is|
      is.get_next_entry
      assert_raises(TypeError) { is.read("2") }
    end
  end

  def test_entry_declared_empty_but_holding_data_is_not_silently_empty
    io = Ziperu::OutputStream.write_buffer do |z|
      z.put_next_entry("lie.txt")
      z.write "hello"
    end
    bytes = io.string
    Ziperu::File.open_buffer(bytes) do |zf|
      e = zf.get_entry("lie.txt")
      bytes.setbyte(e.local_header_offset + 22, 0) # local uncompressed size
      4.times { |i| bytes.setbyte(e.local_header_offset + 22 + i, 0) }
      cd = bytes.rindex([Ziperu::CENTRAL_DIRECTORY_ENTRY_SIGNATURE].pack("V"))
      4.times { |i| bytes.setbyte(cd + 24 + i, 0) }
    end
    Ziperu::File.open_buffer(bytes) do |zf|
      assert_equal 0, zf.get_entry("lie.txt").size
      assert_raises(Ziperu::EntrySizeError) { zf.read("lie.txt") }
      assert_raises(Ziperu::EntrySizeError) { zf.get_entry("lie.txt").get_input_stream(&:read) }
      assert_raises(Ziperu::EntrySizeError) { zf.extract_all(path("lie")) }
    end
  end

  # --- Zip::File state -----------------------------------------------------------

  def test_failed_commit_keeps_the_pending_edits
    file = path("edit.zip")
    FileUtils.cp(fixture("text.zip"), file)
    src = path("src.txt")
    File.write(src, "s")
    Ziperu::File.open(file) do |zf|
      zf.get_entry("short.txt").comment = "edited"
      zf.add("zz.txt", src)
      File.delete(src)
      assert_raises(Errno::ENOENT) { zf.commit }
      assert_equal "short\n", zf.read("short.txt"), "the archive is untouched"
      zf.remove("zz.txt")
      zf.commit
    end
    Ziperu::File.open(file) { |zf| assert_equal "edited", zf.get_entry("short.txt").comment }
  end

  def test_rewriting_an_entry_keeps_its_place
    file = path("order.zip")
    Ziperu::File.open(file, create: true) do |zf|
      %w[mimetype META-INF/container.xml content.xml].each { |n| zf.get_output_stream(n) { |o| o.write n } }
    end
    Ziperu::File.open(file) { |zf| zf.get_output_stream("mimetype") { |o| o.write "application/epub+zip" } }
    Ziperu::File.open(file) do |zf|
      assert_equal %w[mimetype META-INF/container.xml content.xml], zf.entries.map(&:name)
      assert_equal "application/epub+zip", zf.read("mimetype")
    end
  end

  def test_extract_of_a_replaced_or_added_entry_uses_the_new_data
    file = path("repl.zip")
    FileUtils.cp(fixture("text.zip"), file)
    src = path("src.txt")
    File.write(src, "REPLACED")
    Ziperu::File.open(file) do |zf|
      zf.replace(zf.get_entry("short.txt"), src)
      zf.add("added.txt", src)
      out = path("out")
      zf.extract_all(out)
      assert_equal "REPLACED", File.read(File.join(out, "short.txt"))
      assert_equal "REPLACED", File.read(File.join(out, "added.txt"))
      zf.get_entry("short.txt").extract("one.txt", destination_directory: @dir)
      assert_equal "REPLACED", File.read(path("one.txt"))
      assert_empty zf.verify
    end
  end

  def test_stale_entry_after_a_commit_that_removed_entries
    file = path("stale.zip")
    FileUtils.cp(fixture("text.zip"), file)
    Ziperu::File.open(file) do |zf|
      last = zf.entries.last
      zf.entries.first(zf.size - 1).each { |e| zf.remove(e) }
      zf.commit
      e = assert_raises(Ziperu::Error) { last.get_input_stream(&:read) }
      assert_match(/no longer/, e.message)
    end
  end

  def test_edits_to_extra_fields_are_committed
    file = path("extra.zip")
    FileUtils.cp(fixture("text.zip"), file)
    Ziperu::File.open(file) do |zf|
      refute zf.commit_required?
      zf.get_entry("short.txt").extra.merge("#{[0x7777, 2].pack("vv")}AB")
      # Written with the next commit; alone it does not call for one.
      refute zf.commit_required?
      zf.mkdir("x")
    end
    Ziperu::File.open(file) do |zf|
      assert_includes zf.get_entry("short.txt").extra.keys, :unknown
      assert_equal "short
", zf.read("short.txt")
    end
  end

  def test_reading_an_empty_deflated_entry_reaches_eof
    io = Ziperu::OutputStream.write_buffer do |z|
      z.put_next_entry("empty.txt") # Deflated: two bytes of compressed data, none when inflated
      z.put_next_entry("after.txt")
      z.write("after")
    end
    Ziperu::File.open_buffer(io.string) do |zf|
      e = zf.get_entry("empty.txt")
      assert_equal 0, e.size
      assert_operator e.compressed_size, :>, 0
      e.get_input_stream do |is|
        reads = 0
        while (buf = is.sysread(1024))
          reads += 1
          flunk "sysread never returns nil for an empty entry" if reads > 3
          assert_equal "", buf
        end
        assert is.eof?
      end
      assert_equal "", zf.read("empty.txt")
      zf.extract_all(path("out"))
      assert_equal "", File.read(path("out/empty.txt"))
      assert_equal "after", File.read(path("out/after.txt"))
    end
    # The same through the stream reader (no index), as duplicate-name
    # records and pipes are read.
    r, w = IO.pipe
    w.write(io.string)
    w.close
    Ziperu::InputStream.open(r) do |is|
      is.get_next_entry
      reads = 0
      while is.sysread(1024)
        reads += 1
        flunk "sysread never returns nil over a pipe" if reads > 3
      end
      assert_equal "after", (is.get_next_entry && is.read)
    end
  end

  def test_bad_names_and_comments_fail_at_the_call_site
    Ziperu::File.open(fixture("text.zip")) do |zf|
      e = zf.get_entry("short.txt")
      assert_raises(Ziperu::EntryNameError) { e.name = "/abs.txt" }
      assert_raises(Ziperu::EntryNameError) { zf.rename("short.txt", "x" * 70_000) }
      assert_raises(Ziperu::Error) { e.comment = "c" * 70_000 }
      assert_equal "short.txt", e.name
      refute zf.commit_required?
    end
  end

  def test_open_buffer_refuses_a_pipe
    r, w = IO.pipe
    e = assert_raises(ArgumentError) { Ziperu::File.open_buffer(r) }
    assert_match(/seekable/, e.message)
    w.close
    r.close
  end

  def test_native_extraction_errors_name_the_path
    dest = path("dest")
    FileUtils.mkdir_p(dest)
    # "dir" must become a directory, but a file is in the way of its parent.
    File.write(File.join(dest, "dir"), "not a directory")
    Ziperu::File.open(fixture("text.zip")) do |zf|
      err = assert_raises(SystemCallError, Ziperu::DestinationExistsError) { zf.extract_all(dest) }
      assert_includes err.message, "dir"
    end
  end

  def test_rubyzip_2_positional_create_and_the_create_constant
    file = path("legacy.zip")
    assert Ziperu::File::CREATE
    Ziperu::File.open(file, Ziperu::File::CREATE) { |zf| zf.get_output_stream("a") { |o| o.write "a" } }
    assert_equal "a", Ziperu::File.open(file, false) { |zf| @r = zf.read("a") } && @r
    zf = Ziperu::File.new(path("legacy2.zip"), true)
    zf.get_output_stream("b") { |o| o.write "b" }
    zf.close
    assert_equal "b", Ziperu::File.open(path("legacy2.zip")) { |z| @r = z.read("b") } && @r
  end

  def test_central_directory_read_from_stream
    File.open(fixture("text.zip"), "rb") do |io|
      cdir = Ziperu::CentralDirectory.new
      cdir.read_from_stream(io)
      names = cdir.entries.map(&:name)
      assert_includes names, "short.txt"
      assert_equal names.size, cdir.size
      entry = cdir.find { |e| e.name == "short.txt" }
      assert_equal "short\n", entry.get_input_stream(&:read)
      entry.extract("short.txt", destination_directory: @dir)
      assert_equal "short\n", File.read(path("short.txt"))
    end
  end

  def test_local_header_size_points_at_the_data
    bytes = File.binread(fixture("text.zip"))
    Ziperu::File.open(fixture("text.zip")) do |zf|
      zf.each do |e|
        off = e.local_header_offset
        nlen, xlen = bytes.byteslice(off + 26, 4).unpack("vv")
        assert_equal 30 + nlen + xlen, e.calculate_local_header_size, e.name
        assert_equal off + 30 + nlen + xlen, e.local_entry_offset, e.name
      end
    end
  end

  def test_get_raw_input_stream
    Ziperu::File.open(fixture("text.zip")) do |zf|
      head = zf.get_entry("short.txt").get_raw_input_stream { |io| io.read(4) }
      assert_equal [Ziperu::LOCAL_ENTRY_SIGNATURE].pack("V"), head
    end
    Ziperu::File.open_buffer(File.binread(fixture("text.zip"))) do |zf|
      io = zf.get_entry("short.txt").get_raw_input_stream
      assert_equal [Ziperu::LOCAL_ENTRY_SIGNATURE].pack("V"), io.read(4)
    end
  end
end
