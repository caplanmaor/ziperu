# frozen_string_literal: true

# For $INPUT_RECORD_SEPARATOR, the line-separator default in gets and friends.
require 'English'

require_relative 'ioextras/fake_io'
require_relative 'ioextras/abstract_input_stream'
require_relative 'ioextras/abstract_output_stream'

module Zip
  # IO-like conveniences shared by the stream classes. Ported from rubyzip so
  # that `gets`, `readline`, `each_line` and friends behave identically.
  module IOExtras # :nodoc:
    CHUNK_SIZE = 32_768
  end
end
