# frozen_string_literal: true

module Ziperu
  # What `get_input_stream` hands out for a directory entry: an IO-like
  # object that is already at EOF. A module, as in rubyzip, so it is passed
  # around by reference rather than instantiated.
  module NullInputStream # :nodoc:all
    extend ::Ziperu::IOExtras::FakeIO

    class << self
      def read(maxlen = nil, _out_string = nil)
        maxlen.nil? || maxlen.zero? ? '' : nil
      end
      alias sysread read

      def gets(*_args, **_opts)
        nil
      end

      def readline(*_args, **_opts)
        raise EOFError
      end

      def readlines(*_args, **_opts)
        []
      end

      def each(*_args, **_opts)
        to_enum(:each) unless block_given? # rubocop:disable Lint/ToEnumArguments -- nothing to enumerate
      end
      alias each_line each

      def eof?
        true
      end
      alias eof eof?

      def pos
        0
      end

      def lineno
        0
      end

      def rewind; end

      def close; end

      def size
        nil
      end
    end
  end
end
