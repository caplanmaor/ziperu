# frozen_string_literal: true

require 'time' # Time#httpdate
require 'ziperu'

module Ziperu
  # Streams an archive as a Rails (or any Rack) response, without a
  # temporary file and without `ActionController::Live`:
  #
  #   class ExportsController < ApplicationController
  #     include Ziperu::RailsStreaming
  #
  #     def show
  #       zip_stream("export.zip") do |zos|
  #         zos.put_next_entry("report.csv")
  #         zos.write(csv)
  #       end
  #     end
  #   end
  #
  # The response body is `Ziperu::OutputStream.body`, an Enumerator the
  # server pulls chunks from as the block writes them; the headers say
  # the download's name and ask proxies not to buffer it. With `size:`
  # (see `OutputStream.estimated_size`) the response has a
  # `Content-Length` and the browser can show progress.
  #
  # `require "ziperu/rails_streaming"` to use it; it is not loaded with
  # the gem.
  module RailsStreaming
    # Sets the headers and the body. `filename` is what the browser saves
    # the download as; `size:` its length in bytes, when known; `type:`
    # the content type; `**opts` go to `OutputStream.body` (`encrypter:`,
    # `suppress_extra_fields:`).
    def zip_stream(filename = 'download.zip', size: nil, type: 'application/zip', **opts, &block)
      Ziperu::RailsStreaming.headers(filename, size: size, type: type).each do |name, value|
        response.headers[name] = value
      end
      self.response_body = Ziperu::OutputStream.body(**opts, &block)
    end

    class << self
      # The headers for a streamed zip download, as a Hash: for Rack apps
      # that are not Rails controllers.
      #
      #   [200, Ziperu::RailsStreaming.headers("export.zip"), Ziperu::OutputStream.body { ... }]
      def headers(filename, size: nil, type: 'application/zip')
        h = {
          'content-type' => type,
          'content-disposition' => content_disposition(filename),
          # Proxies (nginx) and Rack::ETag must not hold the body back.
          'x-accel-buffering' => 'no',
          'cache-control' => 'no-cache',
          'last-modified' => Time.now.httpdate
        }
        h['content-length'] = size.to_s if size
        h
      end

      # `attachment; filename="ascii"; filename*=UTF-8''percent-encoded`
      # (RFC 6266 and 5987), so every browser gets a usable name.
      def content_disposition(filename)
        name = filename.to_s
        ascii = name.encode('US-ASCII', undef: :replace, invalid: :replace, replace: '_').delete('"\\')
        encoded = name.b.gsub(/[^A-Za-z0-9!#$&+.^_`|~-]/) { |c| format('%%%02X', c.ord) }
        "attachment; filename=\"#{ascii}\"; filename*=UTF-8''#{encoded}"
      end
    end
  end
end
