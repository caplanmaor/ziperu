# frozen_string_literal: true

# Ported verbatim from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).
# Not on any ziperu code path: the Rust core compresses and decompresses.
# Kept so that code which references these classes keeps loading.
module Ziperu
  class PassThruDecompressor < Decompressor # :nodoc:all
    def initialize(*args)
      super
      @read_so_far = 0
    end

    def read(maxlen = nil)
      return (maxlen.nil? || maxlen.zero? ? '' : nil) if eof?

      maxlen = decompressed_size - @read_so_far if maxlen.nil? || (@read_so_far + maxlen) > decompressed_size

      @read_so_far += maxlen
      input_stream.read(maxlen)
    end

    def eof?
      @read_so_far >= decompressed_size
    end

    # Alias for compatibility. Remove for version 4.
    alias eof eof?
  end

  ::Ziperu::Decompressor.register(::Ziperu::COMPRESSION_METHOD_STORE, ::Ziperu::PassThruDecompressor)
end

# Copyright (C) 2002, 2003 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
