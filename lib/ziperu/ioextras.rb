# frozen_string_literal: true

# For $INPUT_RECORD_SEPARATOR, the line-separator default in gets and friends.
require 'English'

require_relative 'ioextras/fake_io'
require_relative 'ioextras/abstract_input_stream'
require_relative 'ioextras/abstract_output_stream'

module Ziperu
  # IO-like conveniences shared by the stream classes. Ported from rubyzip so
  # that `gets`, `readline`, `each_line` and friends behave identically.
  module IOExtras # :nodoc:
    CHUNK_SIZE = 32_768

    class << self
      # Whether `io` can be positioned: it answers `seek` and `tell` and a
      # no-op seek succeeds (a pipe or socket raises).
      def seekable?(io)
        return false unless io.respond_to?(:seek) && io.respond_to?(:tell)

        io.seek(0, ::IO::SEEK_CUR)
        true
      rescue SystemCallError, IOError, NotImplementedError
        false
      end

      # A path (a String, a Pathname, anything with `to_path` that is not
      # an IO), as opposed to an IO-like object.
      def path_like?(obj)
        obj.kind_of?(::String) ||
          (obj.respond_to?(:to_path) && !obj.respond_to?(:seek)) ||
          !obj.respond_to?(:read)
      end

      # The path a path-like object names.
      def path_of(obj)
        obj.respond_to?(:to_path) ? obj.to_path : obj.to_s
      end

      # Puts an IO in binary mode when it has one (a StringIO does not).
      def binmode(io)
        io.binmode if io.respond_to?(:binmode)
        io
      end

      def copy_stream(ostream, istream)
        ostream.write(istream.read(CHUNK_SIZE, +'')) until istream.eof?
      end
    end
  end
end
