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
    HTTP_SCHEMES = %w[http https].freeze
    DEFAULT_MAX_FULL_DOWNLOAD = 64 * 1024 * 1024
    # How much of an answer that is neither data nor a redirect is read.
    ERROR_BODY_LIMIT = 64 * 1024
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60

    attr_reader :size, :pos, :requests
    alias tell pos
    alias length size

    # `url` (a String or URI) to fetch over HTTP(S) with `headers` sent on
    # every request; or, with no url, `size:` and a block that returns
    # `length` bytes from `offset`.
    #
    # Redirects are followed, but `headers` (credentials, typically) go
    # only to the scheme, host and port of `url`: not to another origin a
    # redirect leads to, unless `forward_headers: true`. A redirect from
    # https to http is refused.
    #
    # A server that ignores Range sends the whole file, which is kept in
    # memory; past `max_full_download` bytes (64 MB; nil for no limit)
    # that raises instead. Every ranged answer must carry the
    # Content-Range asked for, and when the server gives an ETag (or a
    # Last-Modified time) it must stay the same: a file changed between
    # requests raises rather than being read as a mix of two versions.
    def initialize(url = nil, headers: {}, size: nil, block_size: DEFAULT_BLOCK_SIZE,
                   cache_blocks: DEFAULT_CACHE_BLOCKS, open_timeout: DEFAULT_OPEN_TIMEOUT,
                   read_timeout: DEFAULT_READ_TIMEOUT, forward_headers: false,
                   max_full_download: DEFAULT_MAX_FULL_DOWNLOAD, &fetch)
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
        unless HTTP_SCHEMES.include?(@uri.scheme&.downcase) && @uri.host
          raise ArgumentError, "RemoteIO fetches http and https URLs, not #{url.to_s.inspect}"
        end

        @headers = headers
        @headers_origin = origin(@uri)
        @forward_headers = forward_headers
        @max_full_download = max_full_download
        @validator = nil
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
          http_range(offset, length)
        end
      raise Error, "asked for #{length} bytes at offset #{offset}, got #{data.bytesize}" unless data.bytesize == length

      data
    end

    # The size, from the first request: the last TAIL_SIZE bytes (a
    # suffix range), whose Content-Range carries the total. They are kept,
    # being what opening an archive reads first.
    def discover_size
      @requests += 1
      response, body = request("bytes=-#{TAIL_SIZE}", TAIL_SIZE, full: true)
      @validator = validator_of(response)
      case response
      when Net::HTTPPartialContent
        first, last, total = content_range(response)
        unless total && last == total - 1 && last - first + 1 == body.bytesize
          raise Error, "#{@uri} answered a request for its last bytes with " \
                       "Content-Range #{response['content-range'].inspect} and #{body.bytesize} bytes"
        end

        keep_tail(body, total)
      when Net::HTTPRequestedRangeNotSatisfiable
        # An empty file has no last bytes.
        0
      when Net::HTTPOK
        # The server ignores Range: the whole file came back; keep it.
        keep_tail(body, body.bytesize)
      else
        raise Error, "#{@uri} answered #{response.code} #{response.message}"
      end
    end

    def http_range(offset, length)
      last = offset + length - 1
      response, body = request("bytes=#{offset}-#{last}", length)
      if response.kind_of?(Net::HTTPPreconditionFailed)
        raise Error, "#{@uri} changed since it was opened (its ETag no longer matches)"
      end
      unless response.kind_of?(Net::HTTPPartialContent)
        raise Error, "#{@uri} answered #{response.code} to a Range request at offset #{offset}"
      end

      check_unchanged(response)
      first, got_last, total = content_range(response)
      unless first == offset && got_last == last && (total.nil? || total == @size)
        raise Error, "#{@uri} answered a request for bytes #{offset}-#{last} of #{@size} " \
                     "with Content-Range #{response['content-range'].inspect}"
      end

      body
    end

    # `[first, last, total]` from a 206's Content-Range, total nil for
    # `*`; nil when there is none or it does not parse.
    def content_range(response)
      match = %r{\Abytes (\d+)-(\d+)/(\d+|\*)\z}.match(response['content-range'].to_s.strip)
      return unless match

      [Integer(match[1]), Integer(match[2]), match[3] == '*' ? nil : Integer(match[3])]
    end

    # What identifies the version of the file first read: its ETag, or
    # failing that its Last-Modified time.
    def validator_of(response)
      if (etag = response['etag'])
        [:etag, etag]
      elsif (modified = response['last-modified'])
        [:last_modified, modified]
      end
    end

    # Raises when an answer names a different version than the first one.
    def check_unchanged(response)
      kind, value = @validator
      now = kind == :etag ? response['etag'] : response['last-modified'] if kind
      return if now.nil? || weak_etag_equal?(now, value)

      raise Error, "#{@uri} changed since it was opened (#{kind} was #{value}, now #{now})"
    end

    def weak_etag_equal?(one, other)
      one.delete_prefix('W/') == other.delete_prefix('W/')
    end

    # A GET with `Range: range`, following redirects (the URL redirected
    # to is used from then on, as a presigned S3 link redirects once).
    # Returns the response and its body, read no further than a range of
    # `wanted` bytes can be, or, with `full:` true, a whole file of
    # `max_full_download`.
    def request(range, wanted, full: false, redirects: MAX_REDIRECTS)
      http = connection
      get = Net::HTTP::Get.new(@uri)
      @headers.each { |k, v| get[k.to_s] = v.to_s } if @forward_headers || origin(@uri) == @headers_origin
      get['range'] = range
      get['accept-encoding'] = 'identity'
      # A strong ETag pins the version: a server that has a newer one
      # answers 412 rather than its bytes.
      kind, value = @validator
      get['if-match'] = value if kind == :etag && !value.start_with?('W/')
      response = body = nil
      http.request(get) do |res|
        response = res
        body = read_limited(res, wanted, full) unless res.kind_of?(Net::HTTPRedirection)
      end
      return [response, body] unless response.kind_of?(Net::HTTPRedirection)
      raise Error, "too many redirects from #{@uri}" if redirects.zero?

      location = redirect_target(response['location'])
      disconnect if origin(location) != origin(@uri)
      @uri = location
      request(range, wanted, full: full, redirects: redirects - 1)
    rescue Error
      # A body left half read cannot be followed by another request.
      disconnect
      raise
    end

    # The body of `response`, raising once it is longer than it can be.
    def read_limited(response, wanted, full)
      limit =
        case response
        when Net::HTTPPartialContent then wanted
        when Net::HTTPOK then full ? @max_full_download : ERROR_BODY_LIMIT
        else ERROR_BODY_LIMIT
        end
      body = +''.b
      check_length = lambda do |length|
        return if limit.nil? || length <= limit

        raise Error, too_long(response, limit)
      end
      check_length.call(response.content_length) if response.content_length
      response.read_body do |chunk|
        body << chunk
        check_length.call(body.bytesize)
      end
      body
    end

    def too_long(response, limit)
      case response
      when Net::HTTPOK
        "#{@uri} ignores Range requests and sent the whole file, which is over max_full_download " \
        "(#{limit} bytes); raise that limit, or download the file first"
      when Net::HTTPPartialContent
        "#{@uri} sent more than the #{limit} bytes asked for"
      else
        "#{@uri} answered #{response.code} #{response.message}"
      end
    end

    # Where a redirect leads, if it may be followed: http or https only,
    # and never from https down to http.
    def redirect_target(header)
      location = URI.join(@uri.to_s, header.to_s)
      scheme = location.scheme&.downcase
      unless HTTP_SCHEMES.include?(scheme) && location.host
        raise Error, "#{@uri} redirected to #{location}, which is not an http or https URL"
      end
      if @uri.scheme.downcase == 'https' && scheme == 'http'
        raise Error, "#{@uri} redirected from https to #{location}; refusing to drop to plain http"
      end

      location
    rescue URI::Error => e
      raise Error, "#{@uri} redirected to an unusable location #{header.inspect}: #{e.message}"
    end

    # Scheme, host and port: where headers given for one URL may go.
    def origin(uri)
      [uri.scheme.downcase, uri.host.downcase, uri.port]
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
