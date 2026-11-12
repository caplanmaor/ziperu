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
    # `external_encoding:`, `internal_encoding:` and `encoding:`, and any
    # `Ziperu.*` setting by its name, for this stream alone (the limits,
    # `validate_entry_sizes:`, `force_entry_names_encoding:`; see
    # Ziperu::Settings).
    #
    # `streaming: true` reads a pipe or socket (an upload, an S3 object's
    # body) in one pass, entry by entry, rather than taking all of it in
    # first to reach the central directory at its end: memory stays at an
    # entry's worth, whatever the archive's size. What the stream gives is
    # what the local headers hold: no comments, no permissions, and an
    # entry whose sizes come after its data has them (`size`, `crc`) only
    # once it has been read to its end. Such an entry must be Deflated,
    # which is how streaming writers write; a Stored one cannot be told
    # apart from what follows it in one pass, and raises. The limits apply
    # to the bytes as they come. A file, a StringIO or a seekable IO is
    # read through its central directory either way. Not in rubyzip.
    def initialize(context, *legacy, offset: 0, decrypter: nil, password: nil,
                   enforce_size: nil, metadata_encoding: nil, streaming: false, **opts)
      @settings = Settings.take!(opts)
      enforce_size = @settings.validate_entry_sizes if enforce_size.nil?
      @metadata_encoding = metadata_encoding
      # rubyzip 2.x's `new(io, offset, decrypter)`.
      offset, decrypter = Compat.positional(legacy, %i[offset decrypter],
                                            offset: offset, decrypter: decrypter)
                                .values_at(:offset, :decrypter)
      # `password:` is the plain form of `decrypter:`; the native core tells
      # AES from ZipCrypto by the entry, so one password serves both.
      decrypter ||= TraditionalDecrypter.new(password) if password
      super(**opts)
      if streaming && self.class.pipe_like?(context)
        IOExtras.binmode(context)
        @stream = Native::StreamReader.open(context, decrypter&.password&.b, enforce_size)
        @stream_entries = 0
        @stream_total = 0
        @decrypter = decrypter
        @enforce_size = enforce_size
        @owns_archive = false
        @archive = nil
        @reader = nil
        @current_entry = nil
        return
      end
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
            self.class.open_archive(context, @settings)
          rescue LimitError
            raise
          rescue Error => e
            # Not an archive: rubyzip finds no entries rather than raising,
            # and `while (entry = zis.get_next_entry)` over untrusted input
            # relies on that. Something that starts like an archive but
            # cannot be opened (a truncated one, say) is an error.
            raise if self.class.archive_like?(context)

            @open_error = e
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
      @lazy_open = false
      @stream&.close
      @stream = nil
      @archive&.close if @owns_archive
      @archive = nil
      @open_error = nil
    end

    # Returns an Entry object and positions the stream at the beginning of
    # the entry data. Returns nil when there are no more entries.
    def get_next_entry
      raise SplitArchiveError if @split
      check_open!
      return next_stream_entry if @stream

      return @current_entry = nil if @archive.nil? || @next_index.nil?
      if @next_index >= (@records ? @records.size : @archive.entry_count)
        # Past the last entry there is nothing to read, not the previous
        # entry again.
        @reader&.close
        @reader = nil
        @lazy_open = false
        flush
        return @current_entry = nil
      end

      @current_entry = Entry.from_meta(@archive, meta_at(@next_index),
                                       metadata_encoding: @metadata_encoding, settings: @settings)
      @next_index += 1
      # The entry's data is opened when it is first read: a walk that only
      # looks at the entries reads no local header.
      open_entry(lazy: true)
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
    def get_next_stream_entry(entry) # :nodoc:
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
      raise Error, 'an entry read with streaming: true cannot be rewound' if @stream

      @lineno = 0
      @pos    = 0
      wrap_errors { reader.rewind }
      flush
    end

    # Moves to byte `offset` of the current entry (from its start, its
    # current position or its end, as `whence` says), as IO#seek does.
    # Only a Stored entry that is not encrypted can be seeked in: its
    # bytes are in the archive as they are. A compressed one raises
    # Ziperu::Error; `rewind` is the way back to its start. Reads after a
    # seek check no CRC, which only reading from the start can do.
    # Not in rubyzip.
    def seek(offset, whence = ::IO::SEEK_SET)
      check_open!
      raise Error, 'no entry to seek in' if reader.nil?
      raise Error, 'an entry read with streaming: true cannot be seeked in' if @stream

      target =
        case whence
        when ::IO::SEEK_SET, :SET then offset
        when ::IO::SEEK_CUR, :CUR then pos + offset
        when ::IO::SEEK_END, :END then @current_entry.size + offset
        else raise ArgumentError, "unknown whence: #{whence.inspect}"
        end
      raise Errno::EINVAL, "seek to #{target}" if target.negative?

      wrap_errors { reader.seek(target) }
      flush
      @pos = [target, @current_entry.size].min
      0
    end

    # IO#pos=, through #seek.
    # Not in rubyzip.
    def pos=(offset)
      seek(offset)
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

      def open_archive(context, settings = ::Ziperu) # :nodoc:
        check_limits(open_native(context, settings), settings)
      end

      # Ziperu.max_entries / max_total_size / max_entry_size /
      # max_compression_ratio, checked before any entry is read, over every
      # record in the central directory (several under one name included).
      # An archive that fails is closed again.
      def check_limits(native, settings = ::Ziperu)
        limits = [settings.max_entries, settings.max_total_size,
                  settings.max_entry_size, settings.max_compression_ratio]
        return native if limits.none?

        count, total, largest, ratio = native.limits
        if (limit = settings.max_entries) && count > limit
          raise LimitError.new('an entry count', count, limit)
        end
        if (limit = settings.max_total_size) && total > limit
          raise LimitError.new('a declared total size', total, limit)
        end
        if (limit = settings.max_entry_size) && largest > limit
          raise LimitError.new('an entry with a declared size', largest, limit)
        end
        if (limit = settings.max_compression_ratio) && ratio > limit
          raise LimitError.new('an entry with a compression ratio', ratio.round(1), limit)
        end

        native
      rescue LimitError
        native.close
        raise
      end

      def path_like?(context) # :nodoc:
        IOExtras.path_like?(context)
      end

      # A pipe, socket or the like: an IO that can only be read forward.
      def pipe_like?(context) # :nodoc:
        !context.kind_of?(Native::Archive) && !path_like?(context) &&
          !context.kind_of?(::StringIO) && context.respond_to?(:read) && !IOExtras.seekable?(context)
      end

      # Whether what `context` holds begins with a local file header, the
      # one thing rubyzip's `InputStream` needs to yield entries.
      def archive_like?(context) # :nodoc:
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

      def open_native(context, settings = ::Ziperu)
        if path_like?(context)
          path = path_of(context)
          begin
            return Native::Archive.open_path(path)
          rescue Errno::ENOENT
            # The native message names no file; Ruby's own does.
            raise Errno::ENOENT, path
          end
        end

        # A StringIO's bytes are already in memory: snapshot them once rather
        # than paying a method call per chunk (12x faster per entry).
        return Native::Archive.open_bytes(context.string) if context.kind_of?(::StringIO)

        IOExtras.binmode(context)
        if IOExtras.seekable?(context)
          # Driven lazily through seek/read; nothing is copied up front.
          Native::Archive.open_io(context)
        else
          # A pipe or socket: there is no way back to the central directory
          # once the data has gone past, so take it all, up to
          # `max_archive_size`.
          bytes = read_bounded(context, settings.max_archive_size)
          raise SplitArchiveError if split_signature?(bytes)

          Native::Archive.open_bytes(bytes)
        end
      end

      # All of `io`, or a LimitError as soon as it passes `limit` bytes.
      def read_bounded(io, limit)
        return io.read.to_s.b unless limit

        bytes = +''.b
        while (chunk = io.read(IOExtras::CHUNK_SIZE))
          bytes << chunk
          raise LimitError.new('an archive size', bytes.bytesize, limit) if bytes.bytesize > limit
        end
        bytes
      end
      private :read_bounded

      # The first part of a multi-part archive starts with a split-file
      # signature.
      def split_archive?(context) # :nodoc:
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

    def open_entry(lazy: false) # :nodoc:
      entry = @current_entry
      unless READABLE_COMPRESSION_METHODS.include?(entry.compression_method)
        raise CompressionMethodError, entry.compression_method
      end

      if entry.encrypted? && @decrypter.nil?
        raise Error, PASSWORD_REQUIRED_MESSAGE
      end

      @reader&.close
      @reader = nil
      @lazy_open = true
      reader unless lazy
      flush
    end

    # The native reader of the current entry, opened on first use.
    def reader # :nodoc:
      return @reader unless @lazy_open

      @lazy_open = false
      entry = @current_entry
      password = @decrypter&.password&.b
      @reader = wrap_errors do
        if entry.index
          @archive.open_entry(entry.index, password, @enforce_size)
        else
          @archive.open_entry_at(entry.local_header_offset, entry.size, entry.compressed_size,
                                 entry.crc, password, @enforce_size)
        end
      end
    end

    def produce_input(maxlen = CHUNK_SIZE) # :nodoc:
      check_open!
      unless maxlen.nil? || maxlen.kind_of?(::Integer)
        raise TypeError, "no implicit conversion of #{maxlen.class} into Integer"
      end
      raise ArgumentError, "negative length #{maxlen} given" if maxlen&.negative?
      return produce_stream_input(maxlen) if @stream
      return nil if reader.nil?

      wrap_errors { @reader.read(maxlen) }
    end

    def input_finished? # :nodoc:
      # A closed stream is not "at EOF": reading it raises, as with an IO.
      return false if closed?

      reader.nil? || @reader.eof?
    end

    private

    # Nil when no entry starts there, which reads as "no more entries".
    def index_at_offset(offset)
      return @records.index { |meta| meta[:header_offset] == offset } if @records

      found = @archive.entries.find { |meta| meta[:header_offset] == offset }
      found && found[:index]
    end

    # Closed by `close`, as opposed to opened on something that is not an
    # archive (`@open_error` holds why), which yields no entries but is
    # not closed.
    def closed?
      @archive.nil? && @open_error.nil? && @stream.nil?
    end

    # `get_next_entry` with `streaming: true`: the next local header.
    def next_stream_entry
      meta = wrap_errors { @stream.next_entry }
      @reader = nil
      flush
      return @current_entry = nil unless meta

      @stream_entries += 1
      if (limit = @settings.max_entries) && @stream_entries > limit
        raise LimitError.new('an entry count', @stream_entries, limit)
      end
      if meta[:size]
        check_stream_entry_size(meta[:size])
        if (limit = @settings.max_compression_ratio) && meta[:size].positive?
          ratio = meta[:compressed_size].zero? ? Float::INFINITY : meta[:size].fdiv(meta[:compressed_size])
          raise LimitError.new('an entry with a compression ratio', ratio.round(1), limit) if ratio > limit
        end
      end
      # Unknown until the entry has been read (see `produce_stream_input`).
      meta[:crc] ||= 0
      meta[:compressed_size] ||= 0
      @current_entry = Entry.from_meta(nil, meta, metadata_encoding: @metadata_encoding, settings: @settings)
      @current_entry.instance_variable_set(:@size, nil) if meta[:size].nil?
      @stream_entry_bytes = 0
      @reader = @stream
      @lineno = 0
      @pos = 0
      @current_entry
    end

    # Reads from the stream, counting against the limits as the bytes
    # come; nil `maxlen` reads to the end of the entry, in chunks.
    def produce_stream_input(maxlen)
      return stream_chunk(maxlen) if maxlen

      out = +''.b
      while (chunk = stream_chunk(CHUNK_SIZE))
        out << chunk
      end
      out.empty? ? nil : out
    end

    def stream_chunk(length)
      chunk = wrap_errors { @stream.read(length) }
      if chunk
        @stream_entry_bytes += chunk.bytesize
        @stream_total += chunk.bytesize
        check_stream_entry_size(@stream_entry_bytes)
        if (limit = @settings.max_total_size) && @stream_total > limit
          raise LimitError.new('a total size', @stream_total, limit)
        end
      end
      learn_stream_trailer if @stream.eof?
      chunk
    end

    def check_stream_entry_size(size)
      return unless (limit = @settings.max_entry_size) && size > limit

      raise LimitError.new('an entry with a size', size, limit)
    end

    # Once a streamed entry has been read to its end: what its data came
    # to, for an entry whose header left it to the descriptor.
    def learn_stream_trailer
      crc, size = @stream.trailer
      return unless crc && !@current_entry.size_known?

      @current_entry.instance_variable_set(:@size, size)
      @current_entry.instance_variable_set(:@crc, crc)
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
