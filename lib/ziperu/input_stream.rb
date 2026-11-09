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
    def initialize(context, *legacy, offset: 0, decrypter: nil, password: nil,
                   enforce_size: ::Ziperu.validate_entry_sizes, **opts)
      # rubyzip 2.x's `new(io, offset, decrypter)`.
      offset, decrypter = Compat.positional(legacy, %i[offset decrypter],
                                            offset: offset, decrypter: decrypter)
                                .values_at(:offset, :decrypter)
      # `password:` is the plain form of `decrypter:`; the native core tells
      # AES from ZipCrypto by the entry, so one password serves both.
      decrypter ||= TraditionalDecrypter.new(password) if password
      super(**opts)
      @split = !context.kind_of?(Native::Archive) && self.class.split_archive?(context)
      # An archive handed in (by Entry#get_input_stream) stays open for its
      # owner; one opened here is closed with the stream. A split segment
      # has no central directory to open; rubyzip fails on the first entry,
      # so defer the error to `get_next_entry`.
      @owns_archive = !context.kind_of?(Native::Archive)
      @archive =
        if !@owns_archive
          context
        elsif !@split
          begin
            self.class.open_archive(context)
          rescue LimitError
            raise
          rescue Error => e
            # Not an archive: rubyzip finds no entries rather than raising,
            # and `while (entry = zis.get_next_entry)` over untrusted input
            # relies on that. Something that starts like an archive but
            # cannot be opened (a truncated one, say) is an error.
            raise if self.class.archive_like?(context)

            @not_an_archive = e
            nil
          end
        end
      @decrypter = decrypter
      @enforce_size = enforce_size
      # An archive with several records under one name is walked from its
      # listing, since the native core addresses only the last of each name
      # by index; every record is yielded, as rubyzip's walk of the local
      # headers would.
      @records = @archive.entries if @archive&.duplicate_names?
      @next_index = offset.zero? || @archive.nil? ? 0 : index_at_offset(offset)
      if @next_index.nil?
        raise Error, "no entry starts at offset #{offset} (Zip local header magic not found)"
      end
      @reader = nil
      @current_entry = nil
    end

    # Close this InputStream. All further IO will raise an IOError.
    def close
      @reader&.close
      @reader = nil
      @archive&.close if @owns_archive
      @archive = nil
      @not_an_archive = nil
    end

    # Returns an Entry object and positions the stream at the beginning of
    # the entry data. Returns nil when there are no more entries.
    def get_next_entry
      raise SplitArchiveError if @split
      check_open!
      return @current_entry = nil if @archive.nil? || @next_index.nil?
      if @next_index >= (@records ? @records.size : @archive.entry_count)
        # Past the last entry there is nothing to read, not the previous
        # entry again.
        @reader&.close
        @reader = nil
        flush
        return @current_entry = nil
      end

      @current_entry = Entry.from_meta(@archive, meta_at(@next_index))
      @next_index += 1
      open_entry
      @current_entry
    end

    def check_open!
      raise IOError, 'closed stream' if closed?
    end
    private :check_open!

    # Entries are fetched from the archive a batch at a time: opening the
    # source once per entry is most of the cost of walking a large archive.
    META_BATCH = 64
    private_constant :META_BATCH

    def meta_at(index)
      return @records[index] if @records

      unless @batch && index >= @batch_at && index < @batch_at + @batch.size
        @batch_at = index
        @batch = @archive.entry_metas(index, META_BATCH)
      end
      @batch[index - @batch_at]
    end
    private :meta_at

    # Position the stream at an entry that already exists as an object
    # (used by Entry#get_input_stream to avoid rebuilding it).
    #
    # @api private
    def get_next_stream_entry(entry)
      check_open!

      @current_entry = entry
      @next_index =
        if @records
          at = @records.index { |meta| meta[:header_offset] == entry.local_header_offset }
          at && at + 1
        else
          entry.index + 1
        end
      open_entry
      @current_entry
    end

    # Rewinds the stream to the beginning of the current entry.
    def rewind
      check_open!
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
      def open(filename_or_io, *legacy, **opts)
        zio = new(filename_or_io, *legacy, **opts)
        return zio unless block_given?

        begin
          yield zio
        ensure
          zio.close if zio
        end
      end

      # @api private
      def open_archive(context)
        check_limits(open_native(context))
      end

      # Ziperu.max_entries / max_total_size, checked before any entry is
      # read. An archive that fails is closed again.
      def check_limits(native)
        if (limit = ::Ziperu.max_entries) && native.entry_count > limit
          raise LimitError.new('an entry count', native.entry_count, limit)
        end
        if (limit = ::Ziperu.max_total_size) && (total = native.total_size) > limit
          raise LimitError.new('a declared total size', total, limit)
        end
        if (limit = ::Ziperu.max_compression_ratio) &&
           (ratio = native.max_compression_ratio) > limit
          raise LimitError.new('an entry with a compression ratio', ratio.round(1), limit)
        end

        native
      rescue LimitError
        native.close
        raise
      end

      # @api private
      def path_like?(context)
        IOExtras.path_like?(context)
      end

      # Whether what `context` holds begins with a local file header, the
      # one thing rubyzip's `InputStream` needs to yield entries.
      #
      # @api private
      def archive_like?(context)
        head =
          if path_like?(context)
            ::File.binread(path_of(context), 4)
          elsif context.kind_of?(::StringIO)
            context.string.byteslice(0, 4)
          elsif IOExtras.seekable?(context)
            context.seek(0, ::IO::SEEK_SET)
            context.read(4)
          end
        head.to_s.b.start_with?([LOCAL_ENTRY_SIGNATURE].pack("V"))
      rescue SystemCallError, IOError
        false
      end

      def path_of(context)
        IOExtras.path_of(context)
      end

      def open_native(context)
        return Native::Archive.open_path(path_of(context)) if path_like?(context)

        # A StringIO's bytes are already in memory: snapshot them once rather
        # than paying a method call per chunk (12x faster per entry).
        return Native::Archive.open_bytes(context.string) if context.kind_of?(::StringIO)

        IOExtras.binmode(context)
        if IOExtras.seekable?(context)
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

      # The first part of a multi-part archive starts with a split-file
      # signature.
      #
      # @api private
      def split_archive?(context)
        head =
          if path_like?(context)
            path = path_of(context)
            ::File.binread(path, 4) if ::File.file?(path)
          else
            # A pipe cannot be peeked at; `open_archive` checks what it reads.
            return false unless IOExtras.seekable?(context)

            context.seek(0, ::IO::SEEK_SET)
            context.read(4)
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
      @reader = wrap_errors do
        if entry.index
          @archive.open_entry(entry.index, password, @enforce_size)
        else
          @archive.open_entry_at(entry.local_header_offset, entry.size, entry.compressed_size,
                                 entry.crc, password, @enforce_size)
        end
      end
      flush
    end

    def produce_input(maxlen = CHUNK_SIZE) # :nodoc:
      check_open!
      unless maxlen.nil? || maxlen.kind_of?(::Integer)
        raise TypeError, "no implicit conversion of #{maxlen.class} into Integer"
      end
      raise ArgumentError, "negative length #{maxlen} given" if maxlen&.negative?
      return nil if @reader.nil?

      wrap_errors { @reader.read(maxlen) }
    end

    def input_finished? # :nodoc:
      # A closed stream is not "at EOF": reading it raises, as with an IO.
      return false if closed?

      @reader.nil? || @reader.eof?
    end

    private

    # Nil when no entry starts there, which reads as "no more entries".
    def index_at_offset(offset)
      return @records.index { |meta| meta[:header_offset] == offset } if @records

      found = @archive.entries.find { |meta| meta[:header_offset] == offset }
      found && found[:index]
    end

    # Closed by `close`, as opposed to never opened on an archive at all.
    def closed?
      @archive.nil? && @not_an_archive.nil?
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
