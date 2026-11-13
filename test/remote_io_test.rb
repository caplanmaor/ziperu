# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "support/range_server"

# Ziperu::RemoteIO: an archive read over HTTP Range requests, a little at
# a time.
class RemoteIOTest < Minitest::Test
  def setup
    @files = (1..40).to_h { |i| ["dir/file#{i}.bin", Random.new(i).bytes(100_000)] }
    buf = Ziperu::OutputStream.write_buffer do |zos|
      @files.each do |name, data|
        zos.put_next_entry(Ziperu::Entry.new("", name, compression_method: Ziperu::Entry::STORED))
        zos << data
      end
    end
    @zip = buf.string
    @server = RangeServer.new(@zip)
  end

  def teardown
    @server.stop
  end

  def test_listing_and_one_entry_read_little_of_the_archive
    io = Ziperu::RemoteIO.new(@server.url)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files.keys, zf.entries.map(&:name)
      assert_equal @files["dir/file17.bin"], zf.read("dir/file17.bin")
    end
    assert_operator @server.bytes_sent, :<, 600_000, "a few blocks of a 4 MB archive"
    assert_operator io.requests, :<=, 4
  end

  def test_every_entry_and_verify
    io = Ziperu::RemoteIO.new(@server.url, block_size: 64 * 1024, cache_blocks: 4)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      @files.each { |name, data| assert_equal data, zf.read(name) }
      assert_empty zf.verify
    end
  end

  def test_extract_all_and_input_stream
    io = Ziperu::RemoteIO.new(@server.url)
    Dir.mktmpdir do |dest|
      Ziperu::File.open_buffer(io, write: false) { |zf| zf.extract_all(dest) }
      assert_equal @files["dir/file40.bin"], File.binread(File.join(dest, "dir/file40.bin"))
    end
    io.rewind
    Ziperu::InputStream.open(io) do |is|
      assert_equal "dir/file1.bin", is.get_next_entry.name
      assert_equal @files["dir/file1.bin"], is.read
    end
  end

  def test_redirect_is_followed
    io = Ziperu::RemoteIO.new(@server.url("/moved"))
    assert_equal @zip.bytesize, io.size
    io.seek(100)
    assert_equal @zip.byteslice(100, 1000), io.read(1000)
  end

  SECRET = { "Authorization" => "Bearer SECRET" }.freeze

  def headers_seen_by(server)
    seen = []
    seen << server.seen_headers.pop until server.seen_headers.empty?
    seen
  end

  def test_headers_stay_on_the_origin_they_were_given_for
    other = RangeServer.new(@zip)
    @server.redirect_to = other.url
    io = Ziperu::RemoteIO.new(@server.url("/away"), headers: SECRET)
    assert_equal @zip.bytesize, io.size
    assert_equal @zip.byteslice(0, 10), io.read(10)
    assert_equal(["Bearer SECRET"], headers_seen_by(@server).map { |h| h["authorization"] })
    seen = headers_seen_by(other)
    refute_empty seen
    assert seen.none? { |h| h.key?("authorization") }, "no credentials to the other origin"
  ensure
    other&.stop
  end

  def test_headers_follow_a_redirect_on_the_same_origin
    Ziperu::RemoteIO.new(@server.url("/moved"), headers: SECRET)
    assert_equal(["Bearer SECRET"] * 2, headers_seen_by(@server).map { |h| h["authorization"] })
  end

  def test_forward_headers_sends_them_to_another_origin
    other = RangeServer.new(@zip)
    @server.redirect_to = other.url
    Ziperu::RemoteIO.new(@server.url("/away"), headers: SECRET, forward_headers: true)
    assert_equal(["Bearer SECRET"], headers_seen_by(other).map { |h| h["authorization"] })
  ensure
    other&.stop
  end

  def test_redirects_to_other_schemes_are_refused
    @server.redirect_to = "file:///etc/passwd"
    error = assert_raises(Ziperu::RemoteIO::Error) { Ziperu::RemoteIO.new(@server.url("/away")) }
    assert_match(/not an http or https URL/, error.message)
  end

  def test_a_redirect_from_https_to_http_is_refused
    # No TLS server here: the check is on the URL alone.
    io = Ziperu::RemoteIO.new(size: 1) { "x" }
    io.instance_variable_set(:@uri, URI("https://example.com/a.zip"))
    error = assert_raises(Ziperu::RemoteIO::Error) { io.send(:redirect_target, "http://example.com/a.zip") }
    assert_match(/refusing to drop to plain http/, error.message)
    assert_equal URI("https://cdn.example.com/a.zip"), io.send(:redirect_target, "https://cdn.example.com/a.zip")
  end

  def test_only_http_and_https_urls
    ["file:///etc/passwd", "ftp://example.com/a.zip", "example.com/a.zip"].each do |url|
      assert_raises(ArgumentError, url) { Ziperu::RemoteIO.new(url) }
    end
  end

  def test_a_full_download_past_the_cap_raises
    plain = RangeServer.new(@zip, ranges: false)
    error = assert_raises(Ziperu::RemoteIO::Error) { Ziperu::RemoteIO.new(plain.url, max_full_download: 1_000_000) }
    assert_match(/max_full_download/, error.message)
    assert_equal @zip.bytesize, Ziperu::RemoteIO.new(plain.url, max_full_download: nil).size
  ensure
    plain&.stop
  end

  def test_a_content_range_other_than_the_one_asked_for_raises
    io = Ziperu::RemoteIO.new(@server.url)
    @server.range_shift = 1
    error = assert_raises(Ziperu::RemoteIO::Error) { io.read(10) }
    assert_match(/Content-Range/, error.message)
  end

  def test_a_file_changed_since_opening_raises
    @server.etag = '"v1"'
    io = Ziperu::RemoteIO.new(@server.url)
    assert_equal @zip.byteslice(0, 10), io.read(10)
    headers_seen_by(@server)
    @server.etag = '"v2"'
    @server.body = @zip.reverse
    io.seek(1_000_000)
    error = assert_raises(Ziperu::RemoteIO::Error) { io.read(10) }
    assert_match(/changed since it was opened/, error.message)
    assert_equal(['"v1"'], headers_seen_by(@server).map { |h| h["if-match"] })
  end

  def test_a_weak_etag_is_compared_not_sent
    @server.etag = 'W/"v1"'
    io = Ziperu::RemoteIO.new(@server.url)
    @server.etag = 'W/"v2"'
    error = assert_raises(Ziperu::RemoteIO::Error) { io.read(10) }
    assert_match(/changed since it was opened/, error.message)
    assert(headers_seen_by(@server).none? { |h| h.key?("if-match") })
  end

  def test_io_behaviour
    io = Ziperu::RemoteIO.new(@server.url, block_size: 1000)
    assert_equal 0, io.pos
    assert_equal @zip.byteslice(0, 2500), io.read(2500)
    assert_equal 2500, io.tell
    io.seek(-10, IO::SEEK_END)
    assert_equal @zip.byteslice(-10, 10), io.read
    assert io.eof?
    assert_nil io.read(1)
    assert_equal "", io.read
    io.seek(-5, IO::SEEK_CUR)
    assert_equal @zip.byteslice(-5, 5), io.read(100)
    io.close
    assert_raises(IOError) { io.read(1) }
  end

  def test_a_server_without_ranges_gives_the_whole_file_once
    plain = RangeServer.new(@zip, ranges: false)
    io = Ziperu::RemoteIO.new(plain.url)
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files["dir/file3.bin"], zf.read("dir/file3.bin")
    end
    assert_equal 1, plain.hits
  ensure
    plain&.stop
  end

  def test_a_block_as_the_source
    calls = []
    io = Ziperu::RemoteIO.new(size: @zip.bytesize) do |offset, length|
      calls << [offset, length]
      @zip.byteslice(offset, length)
    end
    Ziperu::File.open_buffer(io, write: false) do |zf|
      assert_equal @files["dir/file9.bin"], zf.read("dir/file9.bin")
    end
    refute_empty calls
  end

  def test_a_short_answer_raises
    io = Ziperu::RemoteIO.new(size: 1000) { |_offset, _length| "x" }
    assert_raises(Ziperu::RemoteIO::Error) { io.read(10) }
  end

  def test_bad_arguments
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new }
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new(@server.url) { "" } }
    assert_raises(ArgumentError) { Ziperu::RemoteIO.new(size: 1, block_size: 0) { "" } }
  end
end
