# frozen_string_literal: true

# Behaviour that code written against rubyzip relies on, found by diffing
# the two libraries side by side: what a commit must preserve, what a
# stream must report, and which rubyzip paths must keep loading.

require_relative "test_helper"
require "tmpdir"

class MigrationTest < Minitest::Test
  include TestHelper

  PASSWORD = "password"

  def setup
    @tmp = Dir.mktmpdir("ziperu")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def copy_fixture(name)
    path = File.join(@tmp, name)
    FileUtils.cp(fixture("rubyzip/#{name}"), path)
    path
  end

  def zipcrypto_contents(path)
    Ziperu::File.open(path) do |zf|
      zf.entries.reject(&:directory?).map do |e|
        [e.name, e.encrypted?,
         e.get_input_stream(decrypter: Ziperu::TraditionalDecrypter.new(PASSWORD), &:read).bytesize]
      end
    end
  end

  # The native raw copy cannot write ZipCrypto, so it drops the encryption
  # flag and the ciphertext would read as corrupt deflate data.
  def test_zipcrypto_entries_survive_a_commit
    path = copy_fixture("zipWithEncryption.zip")
    before = zipcrypto_contents(path)
    Ziperu::File.open(path) { |zf| zf.mkdir("added") }
    assert_equal before, zipcrypto_contents(path)
    Ziperu::File.open(path) { |zf| zf.rename("file1.txt", "renamed.txt") }
    after = zipcrypto_contents(path)
    assert_includes after, ["renamed.txt", true, before.assoc("file1.txt")[2]]
  end

  def test_extra_fields_the_native_copy_would_lose_survive_a_commit
    { "ntfs.zip" => :ntfs, "local_extra_field.zip" => :iunix }.each do |name, field|
      path = copy_fixture(name)
      snapshot = lambda do
        Ziperu::File.open(path) do |zf|
          zf.entries.reject(&:directory?).map do |e|
            [e.name, e.extra.keys.sort, e.mtime.to_i, e.extra[field]&.to_local_bin]
          end
        end
      end
      before = snapshot.call
      assert_includes before.first[1], field
      Ziperu::File.open(path) { |zf| zf.mkdir("added") }
      Ziperu::File.open(path) { |zf| zf.entries.reject(&:directory?).first.comment = "c" }
      assert_equal before, snapshot.call, name
    end
  end

  def test_edits_an_encrypted_entry_cannot_take_raise_at_commit
    path = copy_fixture("zip-aes-256.zip")
    error = assert_raises(Ziperu::Error) do
      Ziperu::File.open(path) { |zf| zf.entries.first.comment = "c" }
    end
    assert_match(/comment of entry/, error.message)
    # The archive is untouched and a rename still works.
    Ziperu::File.open(path) { |zf| zf.rename("zip-aes-128.txt", "moved.txt") }
    Ziperu::File.open(path) { |zf| assert_equal %w[moved.txt zip-aes-256.txt], zf.entries.map(&:name).sort }
  end

  def test_corrupt_data_is_a_decompression_error_everywhere
    path = File.join(@tmp, "c.zip")
    Ziperu::OutputStream.open(path) do |zos|
      zos.put_next_entry("a.txt")
      zos.write("hello world " * 500)
    end
    bytes = File.binread(path)
    bytes[60, 20] = "\xFF".b * 20
    error = assert_raises(Ziperu::DecompressionError) do
      Ziperu::File.open_buffer(bytes) { |zf| zf.read("a.txt") }
    end
    assert_kind_of Ziperu::Error, error
    assert_raises(Ziperu::DecompressionError) do
      Ziperu::InputStream.open(StringIO.new(bytes)) do |zis|
        zis.get_next_entry
        zis.read
      end
    end
    assert_raises(Ziperu::DecompressionError) do
      Ziperu::File.open_buffer(bytes) { |zf| zf.extract("a.txt", destination_directory: @tmp) }
    end
  end

  def test_validate_entry_sizes_off_reads_past_the_declared_size_everywhere
    path = File.join(@tmp, "s.zip")
    Ziperu::OutputStream.open(path) do |zos|
      zos.put_next_entry("a.txt", "", Ziperu::ExtraField.new, Ziperu::Entry::STORED)
      zos.write("x" * 5000)
    end
    bytes = File.binread(path)
    bytes[bytes.index("PK\x01\x02".b) + 24, 4] = [10].pack("V")
    assert_raises(Ziperu::EntrySizeError) { Ziperu::File.open_buffer(bytes) { |zf| zf.read("a.txt") } }
    Ziperu.validate_entry_sizes = false
    Ziperu::File.open_buffer(bytes) do |zf|
      assert_equal 5000, zf.read("a.txt").bytesize
      assert_equal 5000, zf.get_input_stream("a.txt", &:read).bytesize
    end
    Ziperu::InputStream.open(StringIO.new(bytes)) do |zis|
      zis.get_next_entry
      assert_equal 5000, zis.read.bytesize
    end
  ensure
    Ziperu.validate_entry_sizes = true
  end

  def test_a_written_entry_learns_its_size_crc_and_offset
    entry = Ziperu::Entry.new("o.zip", "a.txt")
    path = File.join(@tmp, "o.zip")
    second = nil
    Ziperu::OutputStream.open(path) do |zos|
      zos.put_next_entry(entry)
      zos.write("hello world " * 100)
      second = zos.put_next_entry("b.txt")
      zos.write("x")
    end
    assert_equal 1200, entry.size
    assert_equal Zlib.crc32("hello world " * 100), entry.crc
    assert_operator entry.compressed_size, :<, 1200
    assert_equal 0, entry.local_header_offset
    Ziperu::File.open(path) do |zf|
      assert_equal zf.get_entry("b.txt").local_header_offset, second.local_header_offset
      assert_equal 1, second.size
    end
  end

  def test_get_output_stream_entries_are_filled_in_by_commit
    path = File.join(@tmp, "g.zip")
    entry = Ziperu::Entry.new(path, "made.txt")
    Ziperu::File.open(path, create: true) do |zf|
      zf.get_output_stream(entry) { |os| os.write("made here") }
    end
    assert_equal 9, entry.size
    assert_equal Zlib.crc32("made here"), entry.crc
  end

  def test_input_stream_over_a_non_archive_yields_nothing
    assert_nil Ziperu::InputStream.open(StringIO.new(""), &:get_next_entry)
    assert_nil Ziperu::InputStream.open(StringIO.new("just text"), &:get_next_entry)
    # An offset that is not an entry's is an error, as in rubyzip.
    assert_raises(Ziperu::Error) { Ziperu::InputStream.open(fixture("text.zip"), offset: 7) }
    # A missing file is still an error, as is a closed stream.
    assert_raises(Errno::ENOENT) { Ziperu::InputStream.open(File.join(@tmp, "missing.zip")) }
    zis = Ziperu::InputStream.new(StringIO.new("just text"))
    zis.close
    assert_raises(IOError) { zis.get_next_entry }
  end

  def test_entries_marshal_without_their_archive
    Ziperu::File.open(fixture("text.zip")) do |zf|
      entry = zf.entries.first
      copy = Marshal.load(Marshal.dump(entry))
      assert_equal entry.name, copy.name
      assert_equal entry.size, copy.size
      assert_equal entry.crc, copy.crc
      assert_raises(Ziperu::Error) { copy.get_input_stream(&:read) }
    end
  end

  def test_a_plain_time_in_an_extra_field_writes
    entry = Ziperu::Entry.new("", "f.txt")
    entry.extra.create(:universaltime)
    entry.extra[:universaltime].mtime = Time.utc(2001, 2, 3, 4, 5, 7)
    archive = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry(entry)
      zos.write("x")
    end.string
    Ziperu::File.open_buffer(archive) do |zf|
      assert_equal Time.utc(2001, 2, 3, 4, 5, 7), zf.entries.first.mtime
    end
  end

  def test_central_only_custom_extra_fields_are_written
    entry = Ziperu::Entry.new("", "f.txt")
    entry.extra.merge("#{[0x7777, 4].pack("vv")}ABCD")
    archive = Ziperu::OutputStream.write_buffer do |zos|
      zos.put_next_entry(entry)
      zos.write("x")
    end.string
    central = archive[archive.index("PK\x01\x02".b)..]
    assert_includes central, "#{[0x7777, 4].pack("vv")}ABCD"
    Ziperu::File.open_buffer(archive) do |zf|
      assert_includes zf.entries.first.extra.keys, :unknown
    end
  end

  def test_bzip2_and_zstd_entries_write_and_read_back
    { Ziperu::Entry::BZIP2 => 9, Ziperu::Entry::ZSTD => 3 }.each do |method, level|
      archive = Ziperu::OutputStream.write_buffer do |zos|
        zos.put_next_entry("m.txt", "", Ziperu::ExtraField.new, method, level)
        zos.write("method #{method} " * 1000)
      end.string
      Ziperu::File.open_buffer(archive) do |zf|
        assert_equal method, zf.entries.first.compression_method
        assert_equal "method #{method} " * 1000, zf.read("m.txt")
      end
      # Such an entry can be re-streamed when an edit calls for it.
      path = File.join(@tmp, "m#{method}.zip")
      File.binwrite(path, archive)
      Ziperu::File.open(path) { |zf| zf.entries.first.comment = "c" }
      Ziperu::File.open(path) do |zf|
        assert_equal "c", zf.entries.first.comment
        assert_equal method, zf.entries.first.compression_method
      end
    end
    assert_raises(Ziperu::CompressionMethodError) do
      Ziperu::OutputStream.write_buffer { |zos| zos.put_next_entry("l", "", Ziperu::ExtraField.new, Ziperu::COMPRESSION_METHOD_LZMA) }
    end
  end

  def test_rubyzip_require_paths_and_internal_classes_load
    require "rubyzip"
    require "zip/crypto/aes_encryption"
    require "zip/inflater"
    assert_equal Ziperu::AESEncrypter, Zip::AESEncrypter
    assert_equal Ziperu::Inflater, Zip::Inflater
    assert_equal Ziperu::PassThruDecompressor, Zip::Decompressor.find_by_compression_method(Ziperu::COMPRESSION_METHOD_STORE)
    assert_equal Zlib::NO_FLUSH, Ziperu::ZLIB_FLUSHING_STRATEGY
  end
end
