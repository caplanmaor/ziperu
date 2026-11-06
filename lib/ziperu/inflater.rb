# frozen_string_literal: true

# Ported verbatim from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).
# Not on any ziperu code path: the Rust core compresses and decompresses.
# Kept so that code which references these classes keeps loading.
module Ziperu
  class Inflater < Decompressor # :nodoc:all
    def initialize(*args)
      super

      @buffer = +''.b
      @zlib_inflater = ::Zlib::Inflate.new(-Zlib::MAX_WBITS)
    end

    def read(maxlen = nil)
      return (maxlen.nil? || maxlen.zero? ? '' : nil) if eof?

      while maxlen.nil? || (@buffer.bytesize < maxlen)
        break if input_finished?

        @buffer << produce_input
      end

      @buffer.slice!(0...(maxlen || @buffer.bytesize))
    end

    def eof?
      @buffer.empty? && input_finished?
    end

    # Alias for compatibility. Remove for version 4.
    alias eof eof?

    private

    def produce_input
      retried = 0
      begin
        @zlib_inflater.inflate(input_stream.read(Decompressor::CHUNK_SIZE))
      rescue Zlib::BufError
        raise if retried >= 5 # how many times should we retry?

        retried += 1
        retry
      end
    rescue Zlib::Error => e
      raise ::Ziperu::DecompressionError, e
    end

    def input_finished?
      @zlib_inflater.finished?
    end
  end

  ::Ziperu::Decompressor.register(::Ziperu::COMPRESSION_METHOD_DEFLATE, ::Ziperu::Inflater)
end

# Copyright (C) 2002, 2003 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
