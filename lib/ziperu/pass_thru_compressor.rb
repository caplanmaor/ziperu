# frozen_string_literal: true

# Ported verbatim from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).
# Not on any ziperu code path: the Rust core compresses and decompresses.
# Kept so that code which references these classes keeps loading.
module Ziperu
  class PassThruCompressor < Compressor # :nodoc:all
    def initialize(output_stream, encrypter = NullEncrypter.new)
      super()
      @output_stream = output_stream
      @encrypter = encrypter
      @crc = Zlib.crc32
      @size = 0
    end

    def <<(data)
      val = data.to_s
      @crc = Zlib.crc32(val, @crc)
      @size += val.bytesize
      @output_stream << @encrypter.encrypt(val)
    end

    attr_reader :size, :crc
  end
end

# Copyright (C) 2002, 2003 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
