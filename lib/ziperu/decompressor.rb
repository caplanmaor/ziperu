# frozen_string_literal: true

# Ported verbatim from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).
# Not on any ziperu code path: the Rust core compresses and decompresses.
# Kept so that code which references these classes keeps loading.
module Ziperu
  class Decompressor # :nodoc:all
    CHUNK_SIZE = 32_768

    def self.decompressor_classes
      @decompressor_classes ||= {}
    end

    def self.register(compression_method, decompressor_class)
      decompressor_classes[compression_method] = decompressor_class
    end

    def self.find_by_compression_method(compression_method)
      decompressor_classes[compression_method]
    end

    attr_reader :decompressed_size, :input_stream

    def initialize(input_stream, decompressed_size = nil)
      super()

      @input_stream = input_stream
      @decompressed_size = decompressed_size
    end
  end
end

# Copyright (C) 2002, 2003 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
