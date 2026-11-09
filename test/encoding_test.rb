# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Names in other encodings: the Unicode Path extra field written and read,
# metadata_encoding: on read, extended timestamps by default.
class EncodingTest < Minitest::Test
  include TestHelper

  def setup
    @dir = Dir.mktmpdir("ziperu-encoding")
    @path = File.join(@dir, "a.zip")
  end

  def teardown
    Ziperu.write_extended_timestamps = false
    Ziperu.unicode_names = false
    Ziperu.write_zip64_support = true
    FileUtils.rm_rf(@dir)
  end

  def raw_name_and_extra(bytes, offset)
    hdr = bytes.byteslice(offset, 30).unpack("VvvvvvVVVvv")
    [bytes.byteslice(offset + 30, hdr[9]), bytes.byteslice(offset + 30 + hdr[9], hdr[10])]
  end

  # Clears the language encoding flag in both headers of a one-entry
  # archive, the way a tool writing names in a local code page leaves it.
  def unflag(bytes)
    local = bytes.index("PK\x03\x04".b)
    central = bytes.rindex("PK\x01\x02".b)
    bytes[local + 6, 2] = [bytes.byteslice(local + 6, 2).unpack1("v") & ~Ziperu::Entry::EFS].pack("v")
    bytes[central + 8, 2] = [bytes.byteslice(central + 8, 2).unpack1("v") & ~Ziperu::Entry::EFS].pack("v")
    bytes
  end

  def header_flags(bytes)
    local = bytes.index("PK\x03\x04".b)
    central = bytes.rindex("PK\x01\x02".b)
    [bytes.byteslice(local + 6, 2).unpack1("v"), bytes.byteslice(central + 8, 2).unpack1("v")]
  end

  def test_a_utf8_name_is_flagged_whatever_unicode_names_says
    name = "ünïcödé-名前.txt"
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry(name); z.write("x") }
    bytes = File.binread(@path)
    assert_equal [Ziperu::Entry::EFS, Ziperu::Entry::EFS], header_flags(bytes).map { |f| f & Ziperu::Entry::EFS },
                 "the native core flags a non-ASCII UTF-8 name"
    Ziperu::File.open(@path) do |zf|
      e = zf.get_entry(name)
      assert_equal name, e.name
      assert_equal Encoding::UTF_8, e.name.encoding
      assert_nil e.extra[:unicodepath], "no Unicode Path field: the flag says it all"
    end
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("plain.txt"); z.write("p") }
    assert_equal [0, 0], header_flags(File.binread(@path)).map { |f| f & Ziperu::Entry::EFS }, "an ASCII name is not"
  end

  def test_unicode_names_flags_every_entry
    Ziperu.unicode_names = true
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry("plain.txt")
      z.write("x")
      z.put_next_entry("dir/")
    end
    bytes = File.binread(@path)
    assert_equal [Ziperu::Entry::EFS, Ziperu::Entry::EFS], header_flags(bytes).map { |f| f & Ziperu::Entry::EFS }
    Ziperu::File.open(@path) do |zf|
      refute_equal 0, zf.get_entry("plain.txt").gp_flags & Ziperu::Entry::EFS
      refute_equal 0, zf.get_entry("dir/").gp_flags & Ziperu::Entry::EFS
      assert_empty zf.verify
    end
    # ZipCrypto entries carry it alongside the cipher's own bits.
    Ziperu::OutputStream.open(@path, encrypter: Ziperu::TraditionalEncrypter.new("pw")) do |z|
      z.put_next_entry("secret.txt")
      z.write("s")
    end
    assert_equal [Ziperu::Entry::EFS | 9, Ziperu::Entry::EFS | 9],
                 header_flags(File.binread(@path)).map { |f| f & (Ziperu::Entry::EFS | 9) }
    Ziperu::File.open(@path, password: "pw") { |zf| assert_equal "s", zf.read("secret.txt") }
  end

  def test_the_unicode_path_field_names_a_code_page_entry
    # What Info-ZIP on Windows writes: the name in the OEM code page, no
    # flag, and the UTF-8 name in a Unicode Path field.
    name = "名前.txt"
    stored = name.encode("Shift_JIS").b
    Ziperu::OutputStream.open(@path) do |z|
      e = Ziperu::Entry.new("", stored)
      field = e.extra.create(:unicodepath)
      field.name = name
      field.crc = Zlib.crc32(stored)
      z.put_next_entry(e)
      z.write("x")
    end
    bytes = File.binread(@path)
    assert_equal [0, 0], header_flags(bytes).map { |f| f & Ziperu::Entry::EFS }, "not valid UTF-8: not flagged"
    Ziperu::File.open(@path) do |zf|
      e = zf.entries.first
      assert_equal name, e.name
      assert_equal Encoding::UTF_8, e.name.encoding, "the field's name"
      assert_equal "x", zf.read(name)
    end
    # Renamed in both headers (same length) without the field following:
    # the CRC no longer matches, so the field is ignored.
    other = "名後.txt".encode("Shift_JIS").b
    assert_equal stored.bytesize, other.bytesize
    File.binwrite(@path, bytes.gsub(stored, other))
    Ziperu::File.open(@path) do |zf|
      assert_equal other, zf.entries.first.name
      assert_equal Encoding::BINARY, zf.entries.first.name.encoding
    end
  end

  def test_metadata_encoding_transcodes_names_and_comments
    name = "日本語.txt"
    Ziperu::OutputStream.open(@path) do |z|
      z.put_next_entry(name.encode("Shift_JIS").b)
      z.write("x")
    end
    # A comment in another encoding, as a tool from that locale writes it
    # (the native writer takes comments in UTF-8 only).
    bytes = File.binread(@path)
    comment = "注釈".encode("Shift_JIS").b
    central = bytes.rindex("PK\x01\x02".b)
    bytes[central + 32, 2] = [comment.bytesize].pack("v")
    name_len, extra_len = bytes.byteslice(central + 28, 4).unpack("vv")
    bytes.insert(central + 46 + name_len + extra_len, comment)
    eocd = bytes.rindex("PK\x05\x06".b)
    bytes[eocd + 12, 4] = [bytes.byteslice(eocd + 12, 4).unpack1("V") + comment.bytesize].pack("V")
    File.binwrite(@path, bytes)
    Ziperu::File.open(@path) do |zf|
      assert_equal Encoding::BINARY, zf.entries.first.name.encoding, "bytes without the encoding"
    end
    Ziperu::File.open(@path, metadata_encoding: "Shift_JIS") do |zf|
      e = zf.entries.first
      assert_equal name, e.name
      assert_equal Encoding::UTF_8, e.name.encoding
      assert_equal "注釈", e.comment
      assert_equal "x", zf.read(name)
    end
    Ziperu::InputStream.open(@path, metadata_encoding: "Shift_JIS") { |is| assert_equal name, is.get_next_entry.name }
    assert_equal name, Ziperu::File.foreach(@path, metadata_encoding: "Shift_JIS").first.name
    # Bytes that do not decode stay bytes.
    Ziperu::File.open(@path, metadata_encoding: "US-ASCII") do |zf|
      assert_equal Encoding::BINARY, zf.entries.first.name.encoding
    end
  end

  def test_extended_timestamps_are_written_when_asked
    Ziperu.write_extended_timestamps = true
    # A local time: the DOS time has no zone, and rubyzip's `time=` keeps
    # the wall clock, so a UTC instant would come back shifted.
    t = Time.local(2021, 3, 4, 5, 6, 7)
    Ziperu::OutputStream.open(@path) do |z|
      e = Ziperu::Entry.new("", "a.txt", time: t)
      z.put_next_entry(e)
      z.write("x")
      z.put_next_entry("d/")
    end
    Ziperu::File.open(@path) do |zf|
      e = zf.get_entry("a.txt")
      assert_equal t.to_i, e.extra[:universaltime].mtime.to_i
      assert_equal t.to_i, e.time.to_i
      assert e.time.absolute_time?
      assert zf.get_entry("d/").extra[:universaltime]
    end
    # An entry rewritten from an archive keeps exactly the fields it had.
    Ziperu.write_extended_timestamps = false
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("bare.txt"); z.write("x") }
    Ziperu.write_extended_timestamps = true
    Ziperu::File.open(@path) { |zf| zf.get_entry("bare.txt").comment = "edited" }
    Ziperu::File.open(@path) { |zf| assert_nil zf.get_entry("bare.txt").extra[:universaltime] }
    # Off (the default): none, as rubyzip writes; an EPUB's mimetype entry
    # must have no extra field at all.
    Ziperu.write_extended_timestamps = false
    Ziperu.write_zip64_support = false # no zip64 placeholder either, as an EPUB producer sets it
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("mimetype", nil, nil, Ziperu::Entry::STORED); z.write("application/epub+zip") }
    assert File.binread(@path).include?("mimetypeapplication/epub+zip")
    Ziperu.write_extended_timestamps = false
    Ziperu::OutputStream.open(@path) { |z| z.put_next_entry("a.txt"); z.write("x") }
    Ziperu::File.open(@path) { |zf| assert_nil zf.get_entry("a.txt").extra[:universaltime] }
  end

  def test_the_size_estimate_follows_the_default_fields
    sink = +"".b
    io = Object.new
    io.define_singleton_method(:write) { |d| sink << d; d.bytesize }
    names = %w[plain.txt ünï.txt]
    estimate = Ziperu::OutputStream.estimated_size { |e| names.each { |n| e.add_stored(n, 3) }; e.add_directory("dír/") }
    Ziperu::OutputStream.write_buffer(io) do |zos|
      names.each do |n|
        zos.put_next_entry(Ziperu::Entry.new("", n, size: 3, compression_method: Ziperu::Entry::STORED))
        zos.write("abc")
      end
      zos.put_next_entry("dír/")
    end
    assert_equal sink.bytesize, estimate
  end
end
