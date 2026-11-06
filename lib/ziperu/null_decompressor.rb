# frozen_string_literal: true

# Ported verbatim from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).
# Not on any ziperu code path: the Rust core compresses and decompresses.
# Kept so that code which references these classes keeps loading.
module Ziperu
  module NullDecompressor # :nodoc:all
    module_function

    def read(_length = nil, _outbuf = nil)
      nil
    end

    def eof?
      true
    end

    # Alias for compatibility. Remove for version 4.
    alias eof eof?
  end
end

# Copyright (C) 2002, 2003 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
