# frozen_string_literal: true

require 'net/http'
require 'uri'

module Ziperu
  # A read-only, seekable IO over an archive somewhere else: an HTTP(S)
  # URL that answers Range requests (S3, GCS, a CDN, most file servers),
  # or anything a block can fetch byte ranges from. Opening an archive
  # through it reads only what is needed: the end of the file (its
  # central directory) in one request, then each entry's bytes as they
  # are read, so listing a 5 GB archive or pulling one file out of it
  # costs a few requests and a few megabytes.
  #
  #   io = Ziperu::RemoteIO.new("https://example.com/big.zip")
  #   Ziperu::File.open_buffer(io, write: false) do |zf|
  #     zf.extract("docs/readme.txt", "readme.txt")
  #   end
  #
  # S3 refuses HEAD to some credentials, so the size comes from the first
  # ranged GET (a presigned URL works as is). With the AWS SDK instead:
  #
  #   s3 = Aws::S3::Client.new
  #   size = s3.head_object(bucket: b, key: k).content_length
  #   io = Ziperu::RemoteIO.new(size: size) do |offset, length|
  #     s3.get_object(bucket: b, key: k, range: "bytes=#{offset}-#{offset + length - 1}").body.read
  #   end
  #
  # Reads go in blocks of `block_size` bytes (adjacent missing blocks in
  # one request); the last `cache_blocks` of them are kept. Not thread
  # safe: one RemoteIO per thread.
  #
  # Not in rubyzip.
  class RemoteIO
    # Raised when the server or the block does not give the bytes asked
    # for.
    class Error < ::Ziperu::Error; end

    DEFAULT_BLOCK_SIZE = 256 * 1024
    DEFAULT_CACHE_BLOCKS = 64
    # The first request asks for this much of the end: the end of central
    # directory record, and for most archives the whole central directory.
    TAIL_SIZE = 64 * 1024
    MAX_REDIRECTS = 5
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60

    attr_reader :size, :pos, :requests
    alias tell pos
    alias length size

    # `url` (a String or URI) to fetch over HTTP(S) with `headers` sent on
    # every request; or, with no url, `size:` and a block that returns
    # `length` bytes from `offset`.
    def initialize(url = nil, headers: {}, size: nil, block_size: DEFAULT_BLOCK_SIZE,
                   cache_blocks: DEFAULT_CACHE_BLOCKS, open_timeout: DEFAULT_OPEN_TIMEOUT,
                   read_timeout: DEFAULT_READ_TIMEOUT, &fetch)
      raise ArgumentError, 'give a url or a block, not both' if url && fetch
      raise ArgumentError, 'give a url, or size: and a block' unless url || (fetch && size)
      raise ArgumentError, 'block_size must be positive' unless block_size.positive?

      @block_size = block_size
      @cache_blocks = [cache_blocks, 1].max
      @blocks = {}
      @tail_start = nil
      @tail = nil
      @pos = 0
      @requests = 0
      @closed = false
      if url
        @uri = URI(url.to_s)
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @size = discover_size
      else
        @fetch = fetch
        @size = Integer(size)
      end
    end

    def read(length = nil, outbuf = nil)
      check_open
      if length.nil?
        data = take(@size - @pos)
      else
        raise ArgumentError, "negative length #{length} given" if length.negative?
        return +''.b if length.zero?
        return nil if @pos >= @size

        data = take([length, @size - @pos].min)
      end
      outbuf ? outbuf.replace(data) : data
    end

    def seek(offset, whence = ::IO::SEEK_SET)
      check_open
      target =
        case whence
        when ::IO::SEEK_SET, :SET then offset
        when ::IO::SEEK_CUR, :CUR then @pos + offset
        when ::IO::SEEK_END, :END then @size + offset
        else raise ArgumentError, "unknown whence: #{whence.inspect}"
        end
      raise Errno::EINVAL, "seek to #{target}" if target.negative?

      @pos = target
      0
    end

    def pos=(offset)
      seek(offset)
    end

    def rewind
      seek(0)
    end

    def eof?
      @pos >= @size
    end
    alias eof eof?

    def binmode
      self
    end

    def close
      @closed = true
      disconnect
      @blocks.clear
      nil
    end

    def closed?
      @closed
    end

    private

    def check_open
      raise IOError, 'closed stream' if @closed
    end

    # `count` bytes from the position, which moves past them.
    def take(count)
      return +''.b if count <= 0

      out = +''.b
      at = @pos
      finish = at + count
      while at < finish
        if @tail_start && at >= @tail_start
          piece = @tail.byteslice(at - @tail_start, finish - at)
        else
          index = at / @block_size
          load_blocks(index, (finish - 1) / @block_size)
          block = @blocks[index]
          offset = at - (index * @block_size)
          piece = block.byteslice(offset, finish - at)
          # Most recently used last, so the first is the one to drop.
          @blocks[index] = @blocks.delete(index)
        end
        raise Error, "no data at offset #{at}" if piece.nil? || piece.empty?

        out << piece
        at += piece.bytesize
      end
      @pos = finish
      out
    end

    # Makes sure blocks `first..last` are cached, fetching each run of
    # missing ones in one request.
    def load_blocks(first, last)
      last = [last, first + @cache_blocks - 1].min
      index = first
      while index <= last
        if @blocks.key?(index)
          # Kept as the most recently used: the caller reads it next, and
          # fetching the blocks after it must not push it out.
          @blocks[index] = @blocks.delete(index)
          index += 1
          next
        end
        run_end = index
        run_end += 1 while run_end < last && !@blocks.key?(run_end + 1)
        offset = index * @block_size
        length = [((run_end + 1) * @block_size), @size].min - offset
        data = fetch(offset, length)
        (index..run_end).each_with_index do |i, n|
          @blocks[i] = data.byteslice(n * @block_size, @block_size)
        end
        @blocks.shift while @blocks.size > @cache_blocks
        index = run_end + 1
      end
    end

    def fetch(offset, length)
      @requests += 1
      data =
        if @fetch
          @fetch.call(offset, length).to_s.b
        else
          http_range("bytes=#{offset}-#{offset + length - 1}", offset)
        end
      raise Error, "asked for #{length} bytes at offset #{offset}, got #{data.bytesize}" unless data.bytesize == length

      data
    end

    # The size, from the first request: the last TAIL_SIZE bytes (a
    # suffix range), whose Content-Range carries the total. They are kept,
    # being what opening an archive reads first.
    def discover_size
      @requests += 1
      response = request("bytes=-#{TAIL_SIZE}")
      case response
      when Net::HTTPPartialContent
        total = response['content-range'].to_s[%r{/(\d+)\z}, 1]
        raise Error, "#{@uri} answered without a usable Content-Range" unless total

        keep_tail(response.body.to_s.b, Integer(total))
      when Net::HTTPRequestedRangeNotSatisfiable
        # An empty file has no last bytes.
        0
      when Net::HTTPOK
        # The server ignores Range: the whole file came back; keep it.
        body = response.body.to_s.b
        keep_tail(body, body.bytesize)
      else
        raise Error, "#{@uri} answered #{response.code} #{response.message}"
      end
    end

    def http_range(range, offset)
      response = request(range)
      unless response.kind_of?(Net::HTTPPartialContent)
        raise Error, "#{@uri} answered #{response.code} to a Range request at offset #{offset}"
      end

      response.body.to_s.b
    end

    # A GET with `Range: range`, following redirects (the URL redirected
    # to is used from then on, as a presigned S3 link redirects once).
    def request(range, redirects = MAX_REDIRECTS)
      http = connection
      get = Net::HTTP::Get.new(@uri)
      @headers.each { |k, v| get[k.to_s] = v.to_s }
      get['range'] = range
      get['accept-encoding'] = 'identity'
      response = http.request(get)
      return response unless response.kind_of?(Net::HTTPRedirection)
      raise Error, "too many redirects from #{@uri}" if redirects.zero?

      location = URI.join(@uri.to_s, response['location'].to_s)
      disconnect if location.host != @uri.host || location.port != @uri.port || location.scheme != @uri.scheme
      @uri = location
      request(range, redirects - 1)
    end

    # Keeps `body`, the last bytes of a file of `total` bytes. Returns `total`.
    def keep_tail(body, total)
      @tail_start = total - body.bytesize
      @tail = body
      total
    end

    def disconnect
      @http&.finish if @http&.started?
      @http = nil
    end

    def connection
      return @http if @http&.started?

      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.use_ssl = @uri.scheme == 'https'
      @http.open_timeout = @open_timeout
      @http.read_timeout = @read_timeout
      @http.start
    end
  end
end
