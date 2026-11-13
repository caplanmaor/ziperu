# frozen_string_literal: true

require "socket"

# A one-file HTTP server that answers Range requests (and, to check
# redirects, sends /moved to /a.zip and /away to `redirect_to`). Counts
# what it sends and keeps the headers of every request.
class RangeServer
  attr_reader :port, :bytes_sent, :hits, :seen_headers
  attr_accessor :redirect_to

  def initialize(body, ranges: true)
    @body = body
    @ranges = ranges
    @bytes_sent = 0
    @hits = 0
    @seen_headers = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def url(path = "/a.zip")
    "http://127.0.0.1:#{@port}#{path}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(client)
    while (request_line = client.gets)
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip
      end
      @hits += 1
      @seen_headers << headers
      path = request_line.split[1]
      if ["/moved", "/away"].include?(path)
        respond(client, "302 Found", { "location" => path == "/away" ? @redirect_to : "/a.zip" }, "")
        next
      end
      range = headers["range"]
      if @ranges && range
        first, last = parse(range)
        if first.nil?
          respond(client, "416 Range Not Satisfiable", { "content-range" => "bytes */#{@body.bytesize}" }, "")
          next
        end
        part = @body.byteslice(first..last)
        respond(client, "206 Partial Content",
                { "content-range" => "bytes #{first}-#{last}/#{@body.bytesize}" }, part)
      else
        respond(client, "200 OK", {}, @body)
      end
    end
  rescue IOError, SystemCallError
    nil
  ensure
    client.close
  end

  def parse(range)
    spec = range.delete_prefix("bytes=")
    size = @body.bytesize
    return nil if size.zero?

    if spec.start_with?("-")
      n = spec[1..].to_i
      [[size - n, 0].max, size - 1]
    else
      a, b = spec.split("-")
      [a.to_i, [b.to_i, size - 1].min]
    end
  end

  def respond(client, status, headers, body)
    @bytes_sent += body.bytesize
    head = "HTTP/1.1 #{status}\r\ncontent-length: #{body.bytesize}\r\n"
    headers.each { |k, v| head << "#{k}: #{v}\r\n" }
    client.write(head << "\r\n" << body)
  end
end
