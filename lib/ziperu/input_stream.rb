# frozen_string_literal: true

module Ziperu
  # Reads the entries of an archive one after another, exposing each as an
  # IO-like stream, exactly as rubyzip's `Ziperu::InputStream` does:
  #
  #   Ziperu::InputStream.open("my.zip") do |io|
  #     while (entry = io.get_next_entry)
  #       puts "Contents of #{entry.name}: '#{io.read}'"
  #     end
  #   end
  #
  # Unlike rubyzip, entries are located through the central directory rather
  # than by walking local headers, so archives whose local headers lack sizes
  # (general-purpose bit 3, as written by OS X Archive Utility and most
  # streaming writers) read fine instead of raising `Ziperu::StreamingError`.
  class InputStream
    CHUNK_SIZE = IOExtras::CHUNK_SIZE # :nodoc:

    include ::Ziperu::IOExtras::AbstractInputStream

    # Opens the indicated zip file.
    #
    # @param context [String||IO||StringIO] file path or IO/StringIO object
    # @param offset [Integer] byte offset of the local header to start at
    # This method also accepts the standard IO encoding options:
    # `external_encoding:`, `internal_encoding:` and `encoding:`.
    def initialize(context, offset: 0, decrypter: nil, enforce_size: true, **opts)
      super(**opts)
      @split = !context.kind_of?(Native::Archive) && self.class.split_archive?(context)
      # A split segment has no central directory to open; rubyzip fails on
      # the first entry, so defer the error to `get_next_entry`.
      @archive =
        if context.kind_of?(Native::Archive)
          context
        elsif !@split
          self.class.open_archive(context)
        end
      @decrypter = decrypter
      @enforce_size = enforce_size
      @next_index = offset.zero? ? 0 : index_at_offset(offset)
      @reader = nil
      @current_entry = nil
      @complete_entry = nil
    end

    # Close this InputStream. All further IO will raise an IOError.
    def close
      @reader&.close
      @reader = nil
      @archive = nil
    end

    # Returns an Entry object and positions the stream at the beginning of
    # the entry data. Returns nil when there are no more entries.
    def get_next_entry
      raise SplitArchiveError if @split
      raise IOError, 'closed stream' if @archive.nil?
      return @current_entry = nil if @next_index >= @archive.entry_count

      @current_entry = Entry.from_meta(@archive, @archive.entry_meta(@next_index))
      @next_index += 1
      open_entry
      @current_entry
    end

    # Position the stream at an entry that already exists as an object
    # (used by Entry#get_input_stream to avoid rebuilding it).
    #
    # @api private
    def get_next_stream_entry(entry)
      raise IOError, 'closed stream' if @archive.nil?

      @current_entry = entry
      @next_index = entry.index + 1
      open_entry
      @current_entry
    end

    # Rewinds the stream to the beginning of the current entry.
    def rewind
      return if @current_entry.nil?

      @lineno = 0
      @pos    = 0
      wrap_errors { @reader.rewind }
      flush
    end

    # Modelled after IO#sysread. Reads up to maxlen bytes from the stream,
    # bypassing the line buffer; returns a string (either a new string or the
    # given out_string).
    def sysread(maxlen = nil, out_string = nil)
      return (maxlen.nil? || maxlen.zero? ? '' : nil) if eof?

      output = produce_input(maxlen) || +''.b

      if out_string.nil?
        output.force_encoding(@internal_encoding || @external_encoding)
      else
        encoding = out_string.encoding
        out_string.replace(output).force_encoding(encoding)
      end
    end

    # Returns the size of the current entry, or `nil` if there isn't one.
    def size
      return if @current_entry.nil?

      @current_entry.size
    end

    class << self
      # Same as #initialize but if a block is passed the opened stream is
      # passed to the block and closed when the block returns.
      def open(filename_or_io, offset: 0, decrypter: nil, **opts)
        zio = new(filename_or_io, offset: offset, decrypter: decrypter, **opts)
        return zio unless block_given?

        begin
          yield zio
        ensure
          zio.close if zio
        end
      end

      # @api private
      def open_archive(context)
        return Native::Archive.open_path(context.to_s) unless context.respond_to?(:read)

        context.binmode if context.respond_to?(:binmode)
        if seekable?(context)
          # Driven lazily through seek/read; nothing is copied up front.
          Native::Archive.open_io(context)
        else
          # A pipe or socket: there is no way back to the central directory
          # once the data has gone past, so take it all.
          bytes = context.read.to_s.b
          raise SplitArchiveError if split_signature?(bytes)

          Native::Archive.open_bytes(bytes)
        end
      end

      def seekable?(io)
        return false unless io.respond_to?(:seek) && io.respond_to?(:tell)

        io.seek(0, ::IO::SEEK_CUR)
        true
      rescue SystemCallError, IOError
        false
      end

      # The first part of a multi-part archive starts with a split-file
      # signature.
      #
      # @api private
      def split_archive?(context)
        head =
          if context.respond_to?(:read)
            # A pipe cannot be peeked at; `open_archive` checks what it reads.
            return false unless seekable?(context)

            context.seek(0, ::IO::SEEK_SET)
            context.read(4)
          elsif ::File.file?(context.to_s)
            ::File.binread(context.to_s, 4)
          end
        split_signature?(head)
      end

      def split_signature?(head)
        !head.nil? && head.bytesize >= 4 && head.unpack1('V') == SPLIT_FILE_SIGNATURE
      end
    end

    protected

    def open_entry # :nodoc:
      entry = @current_entry
      unless READABLE_COMPRESSION_METHODS.include?(entry.compression_method)
        raise CompressionMethodError, entry.compression_method
      end

      if entry.encrypted? && @decrypter.nil?
        raise Error, PASSWORD_REQUIRED_MESSAGE
      end

      password = @decrypter&.password&.b
      @reader = wrap_errors { @archive.open_entry(entry.index, password, @enforce_size) }
      flush
    end

    def produce_input(maxlen = CHUNK_SIZE) # :nodoc:
      return nil if @reader.nil?

      wrap_errors { @reader.read(maxlen) }
    end

    def input_finished? # :nodoc:
      @reader.nil? || @reader.eof?
    end

    private

    def index_at_offset(offset)
      found = @archive.entries.find { |meta| meta[:header_offset] == offset }
      raise Error, "no local header at offset #{offset}" if found.nil?

      found[:index]
    end

    # Re-raise the native core's errors as the rubyzip-shaped ones.
    def wrap_errors
      yield
    rescue Native::SizeLimitError
      raise EntrySizeError, @current_entry
    rescue Native::PasswordError => e
      # rubyzip verifies AES passwords up front but just inflates garbage for
      # a wrong ZipCrypto one, so the exception classes differ.
      raise Error, 'Bad password' if @decrypter.kind_of?(AESDecrypter)

      raise DecompressionError, e
    rescue Native::UnsupportedError => e
      raise Error, e.message
    end
  end
end
