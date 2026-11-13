# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).

require_relative 'fake_io'

module Ziperu
  module IOExtras # :nodoc:
    # Implements many of the convenience methods of IO such as gets, getc,
    # read, readline and readlines. Depends on: input_finished?,
    # produce_input and read.
    module AbstractInputStream
      include Enumerable
      include FakeIO

      # Past this many handed-out bytes (and half the buffer), they are
      # dropped from it.
      COMPACT_AT = 64 * 1024
      private_constant :COMPACT_AT

      def initialize(**opts)
        super
        @lineno        = 0
        @pos           = 0
        # Bytes produced but not yet handed out are those of
        # `@output_buffer` from `@out_pos` on. Handing some out moves the
        # offset rather than shifting the rest down (`slice!`), which for a
        # line at a time from a 64 KB chunk copied most of the chunk per
        # line; the consumed part is dropped once it is large.
        @output_buffer = +''.b
        @out_pos       = 0
      end

      attr_accessor :lineno
      attr_reader :pos

      def read(maxlen = nil, out_string = nil)
        return (maxlen.nil? || maxlen.zero? ? '' : nil) if eof?

        available = buffered_size
        tbuf = if available > 0
                 if maxlen && maxlen <= available
                   take_buffered(maxlen)
                 else
                   maxlen -= available if maxlen
                   rbuf = produce_input(maxlen)
                   out  = take_buffered(available)
                   out << rbuf if rbuf
                   out
                 end
               else
                 produce_input(maxlen)
               end

        if tbuf.nil? || tbuf.empty?
          return nil if maxlen&.positive?

          return ''
        end

        @pos += tbuf.length

        if out_string.nil?
          tbuf.force_encoding(@internal_encoding || @external_encoding)
        else
          encoding = out_string.encoding
          out_string.replace(tbuf).force_encoding(encoding)
        end
      end

      def readlines(sep = $INPUT_RECORD_SEPARATOR, limit = nil, chomp: false)
        each(sep, limit, chomp: chomp).to_a
      end

      def gets(sep = $INPUT_RECORD_SEPARATOR, limit = nil, chomp: false)
        if sep.nil?
          return nil if eof?

          @lineno = @lineno.next
          return read(limit)
        end

        sep, limit = separator_and_limit(sep, limit)
        encoding = @internal_encoding || @external_encoding

        # The buffer is binary, so `index` counts bytes.
        buffer_index = @out_pos
        while (sep_index = @output_buffer.index(sep, buffer_index)).nil?
          break if limit && buffered_size >= limit

          # The input ends either before a read or, for an entry whose
          # data turns out empty, on the read itself (nil).
          chunk = input_finished? ? nil : produce_input
          return take_last_line(encoding) if chunk.nil?

          # A line runs on into the next chunk: drop what was handed out
          # before appending, so the buffer holds only the unread bytes.
          buffer_index -= @out_pos
          drop_consumed
          buffer_index = [buffer_index, @output_buffer.bytesize - sep.bytesize].max
          @output_buffer << chunk
        end

        limit ||= buffered_size
        cut_index = sep_index ? [sep_index - @out_pos + sep.bytesize, limit].min : limit
        @lineno = @lineno.next
        @pos += cut_index
        data = take_buffered(cut_index)
        data.chomp!(sep) if chomp
        data.force_encoding(encoding)
      end

      # Half-open style: the bytes read here are what read(maxlen) gives, so
      # a short answer is possible but never a blocking one.
      def readpartial(maxlen, outbuf = nil)
        raise EOFError, 'end of file reached' if eof?

        read(maxlen, outbuf) || raise(EOFError, 'end of file reached')
      end

      def read_nonblock(maxlen, outbuf = nil, exception: true)
        return nil if !exception && eof?

        readpartial(maxlen, outbuf)
      end

      # The external encoding is always binary, so a character is a byte.
      def getc
        read(1)
      end

      def getbyte
        read(1)&.getbyte(0)
      end

      def readchar
        getc || raise(EOFError, 'end of file reached')
      end

      def readbyte
        getbyte || raise(EOFError, 'end of file reached')
      end

      def each_byte
        return to_enum(:each_byte) unless block_given?

        while (byte = getbyte)
          yield byte
        end
      end

      def each_char
        return to_enum(:each_char) unless block_given?

        while (char = getc)
          yield char
        end
      end

      # Accepts a String or an Integer byte, as IO#ungetc does; rubyzip only
      # took the Integer.
      def ungetc(char)
        return if char.nil?

        drop_consumed
        @output_buffer = pushback_bytes(char) + @output_buffer
        nil
      end

      alias ungetbyte ungetc

      def binmode
        self
      end

      def binmode?
        true
      end

      def tty?
        false
      end

      alias isatty tty?

      def sync
        true
      end

      def sync=(_value); end

      def fileno
        nil
      end

      def flush # :nodoc:
        take_buffered(buffered_size)
      end

      def readline(sep = $INPUT_RECORD_SEPARATOR, limit = nil, chomp: false)
        raise EOFError if eof?

        gets(sep, limit, chomp: chomp)
      end

      def each(sep = $INPUT_RECORD_SEPARATOR, limit = nil, chomp: false)
        return to_enum(:each, sep, limit, chomp: chomp) unless block_given?

        while (line = gets(sep, limit, chomp: chomp))
          yield line
        end
      end

      alias each_line each

      def eof?
        buffered_size.zero? && input_finished?
      end

      alias eof eof? # :nodoc:

      private

      # `gets(limit)` and `gets('')` (paragraphs), as IO#gets reads them.
      def separator_and_limit(sep, limit)
        if sep.respond_to?(:to_int)
          [$INPUT_RECORD_SEPARATOR, sep.to_int]
        elsif sep.empty?
          ["#{$INPUT_RECORD_SEPARATOR}#{$INPUT_RECORD_SEPARATOR}", limit]
        else
          [sep, limit]
        end
      end

      # What is left when the input ends without a separator; nil when
      # nothing is.
      def take_last_line(encoding)
        return nil if buffered_size.zero?

        @lineno = @lineno.next
        @pos += buffered_size
        take_buffered(buffered_size).force_encoding(encoding)
      end

      # Bytes produced and not yet handed out.
      def buffered_size
        @output_buffer.bytesize - @out_pos
      end

      # The next `count` buffered bytes, as a String of their own.
      def take_buffered(count)
        data = @output_buffer.byteslice(@out_pos, count) || +''.b
        @out_pos += data.bytesize
        if @out_pos == @output_buffer.bytesize
          @output_buffer = +''.b
          @out_pos = 0
        elsif @out_pos > COMPACT_AT && @out_pos * 2 > @output_buffer.bytesize
          drop_consumed
        end
        data
      end

      def drop_consumed
        return if @out_pos.zero?

        @output_buffer = @output_buffer.byteslice(@out_pos..)
        @out_pos = 0
      end

      def pushback_bytes(char)
        char.kind_of?(::Integer) ? char.chr.b : char.to_str.b
      end
    end
  end
end
