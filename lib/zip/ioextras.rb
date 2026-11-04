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

    class << self
      def copy_stream(ostream, istream)
        ostream.write(istream.read(CHUNK_SIZE, +'')) until istream.eof?
      end

      def copy_stream_n(ostream, istream, nbytes)
        toread = nbytes
        while toread > 0 && !istream.eof?
          tr = [toread, CHUNK_SIZE].min
          ostream.write(istream.read(tr, +''))
          toread -= tr
        end
      end
    end
  end
end
