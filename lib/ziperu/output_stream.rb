# frozen_string_literal: true

module Ziperu
  # Writes zip archives entry by entry, with rubyzip's `Ziperu::OutputStream`
  # API: `put_next_entry` opens an entry, then the IO-like methods (`<<`,
  # `write`, `puts`, `print`) fill it.
  #
  #   Ziperu::OutputStream.open("my.zip") do |io|
  #     io.put_next_entry("first_entry.txt")
  #     io.write "Hello world!"
  #   end
  #
  # `write_buffer` writes to an IO (a StringIO by default) instead of a file.
  class OutputStream
    include ::Ziperu::IOExtras::AbstractOutputStream

    attr_accessor :comment

    # Opens the indicated zip file. If a file with that name already exists
    # it will be overwritten. With `stream: true`, `file_name` is an IO
    # object that receives the archive from its start, entry by entry if it
    # is seekable (a StringIO, File or Tempfile) and all at once on
    # `close_buffer` if it is not (a pipe).
    def initialize(file_name, stream: false, encrypter: nil, suppress_extra_fields: false, **opts)
      super(**opts)
      @file_name = file_name
      @io = nil
      if stream
        @io = file_name
        @io.binmode if @io.respond_to?(:binmode)
        @writer =
          if IOExtras.seekable?(@io)
            @io.rewind if @io.respond_to?(:rewind)
            Native::Writer.open_io(@io)
          else
            Native::Writer.open_memory
          end
      else
        @writer = Native::Writer.open_path(file_name.to_s)
      end
      @encrypter = encrypter || ::Ziperu::NullEncrypter.new
      @suppress_extra_fields = suppress_extra_fields
      @comment = ''
      @closed = false
      @current_entry = nil
      @written = []
    end

    class << self
      # Same as #initialize but if a block is passed the opened stream is
      # passed to the block and closed when the block returns.
      def open(file_name, encrypter: nil, suppress_extra_fields: false, **opts)
        unless block_given?
          return new(file_name, encrypter: encrypter,
                                suppress_extra_fields: suppress_extra_fields, **opts)
        end

        zos = new(file_name, stream: false, encrypter: encrypter,
                             suppress_extra_fields: suppress_extra_fields, **opts)
        result =
          begin
            yield zos
          rescue Exception # rubocop:disable Lint/RescueException
            # The archive is abandoned: the entries written so far must
            # not learn offsets and sizes from it.
            zos.abort
            raise
          end
        zos.close
        result
      end

      # Same as #open but writes to an IO instead; returns the IO.
      def write_buffer(io = ::StringIO.new, encrypter: nil, suppress_extra_fields: false, **opts)
        zos = new(io, stream: true, encrypter: encrypter,
                      suppress_extra_fields: suppress_extra_fields, **opts)
        begin
          yield zos
        rescue Exception # rubocop:disable Lint/RescueException
          zos.abort
          raise
        end
        zos.close_buffer
      end
    end

    # Closes the stream and writes the central directory. A stream over an
    # IO (`stream: true`) closes it too, as rubyzip does; `close_buffer` is
    # the variant that leaves it open.
    def close
      return if @closed

      finish_archive
      @io.close if @io && @io.respond_to?(:close)
      @closed = true
      nil
    end

    # Closes the stream after a failure: the native writer is released,
    # but the entries written so far are left as they were, since the
    # archive they were written to is not going to be used.
    def abort # :nodoc:
      @aborted = true
      @io ? close_buffer : close
    rescue StandardError
      # Nothing to add to the exception already on its way.
      nil
    end

    # Closes the stream and completes the archive in the IO given to
    # `write_buffer`; returns that IO.
    def close_buffer
      return @io if @closed

      finish_archive
      @closed = true
      @io
    end

    # Closes the current entry and opens a new one for writing. `entry_name`
    # can be a Ziperu::Entry or a string.
    def put_next_entry(
      entry_name, comment = '', extra = ExtraField.new,
      compression_method = Entry::DEFLATED, level = Ziperu.default_compression
    )
      raise Error, 'zip stream is closed' if @closed

      new_entry =
        if entry_name.kind_of?(Entry) || entry_name.kind_of?(StreamableStream)
          entry_name
        else
          Entry.new(
            @file_name, entry_name.to_s, comment: comment, extra: extra,
            compression_method: compression_method, compression_level: level
          )
        end

      init_next_entry(new_entry)
      @written << new_entry
      @current_entry = new_entry
    end

    # Copies an entry from another archive without recompressing it. With
    # `touch: true` the entry's current permissions and mtime are written
    # instead of the source's. The native writer can do that or a rename,
    # not both, and carries nothing else over from the entry object;
    # `Entry#write_to_zip_output_stream` re-streams edited entries instead.
    def copy_raw_entry(entry, new_name = nil, touch: false) # :nodoc:
      raise Error, 'zip stream is closed' if @closed
      raise Error, 'entry is not a ZipEntry' unless entry.kind_of?(Entry)
      raise Error, "entry '#{entry.name}' is not in an archive" if entry.archive.nil?
      if entry.index.nil?
        raise Error, "entry '#{entry.name}' shares its name with another record and cannot be copied raw"
      end

      return copy_encrypted_entry(entry, new_name) if entry.zipcrypto?

      touch_opts =
        if touch && new_name.nil?
          time = DOSTime.from_time(entry.time)
          { dos_date: time.to_binary_dos_date, dos_time: time.to_binary_dos_time,
            unix_perms: entry.unix_perms }
        end
      @writer.raw_copy(entry.archive, entry.index, new_name, touch_opts)
      @written << entry
      @current_entry = nil
    end

    # Copies a ZipCrypto entry byte for byte. The native raw copy cannot
    # write one faithfully (it rebuilds the headers without the cipher's
    # flags and descriptor), so the ciphertext goes in under the entry's
    # own headers: name, time, permissions, extra fields and comment are
    # all taken from the entry, so a rename or chmod is carried too.
    def copy_encrypted_entry(entry, new_name = nil) # :nodoc:
      raise Error, 'zip stream is closed' if @closed
      raise Error, "entry '#{entry.name}' is not in an archive" if entry.archive.nil?
      if entry.index.nil?
        raise Error, "entry '#{entry.name}' shares its name with another record and cannot be copied raw"
      end

      opts = native_entry_options(entry).merge(
        zipcrypto: true, descriptor: entry.gp_flags & 8 != 0 # bit 3: data descriptor follows
      )
      @writer.copy_zipcrypto(entry.archive, entry.index, (new_name || entry.name).b, opts)
      @written << entry
      @current_entry = nil
    end

    # Modeled after IO.<<
    def <<(data)
      raise IOError, 'closed stream' if @closed || @current_entry.nil?
      if @current_entry.directory?
        raise Error, "cannot write data to directory entry '#{@current_entry.name}'"
      end

      @writer.write(data.to_s.b)
      self
    end

    private

    def finish_archive
      comment = @comment.to_s.b
      raise ArgumentError, "archive comment is #{comment.bytesize} bytes; the limit is 65535" if comment.bytesize > 0xFFFF

      @writer.comment = comment
      @current_entry = nil
      begin
        bytes, stats = @writer.finish
      rescue IOError => e
        raise unless @io && e.message.include?('not opened for reading')

        raise Error, 'finishing an archive with ZipCrypto entries reads its headers back, which ' \
                     "the IO given does not allow (#{e.message}); open it for reading and writing"
      end
      unless @aborted
        stats.each_with_index do |(offset, size, compressed_size, crc), i|
          @written[i].written_as(offset, size, compressed_size, crc)
        end
      end
      # A seekable IO already holds the archive; a pipe gets it now.
      return unless bytes && @io

      @io.write(bytes)
      @io.flush if @io.respond_to?(:flush)
    end

    def init_next_entry(entry)
      unless WRITABLE_COMPRESSION_METHODS.include?(entry.compression_method)
        raise ::Ziperu::CompressionMethodError, entry.compression_method
      end

      opts = native_entry_options(entry)
      if entry.directory?
        @writer.add_directory(entry.name, opts)
      elsif entry.symlink?
        @writer.add_symlink(entry.name, entry.symlink_target, opts)
      else
        opts.merge!(@encrypter.native_options)
        @writer.start_entry(entry.name.b, opts)
      end
    rescue Native::DuplicateEntryError
      raise EntryExistsError.new('put_next_entry', entry.name)
    end

    # Translate a Ziperu::Entry into the Hash the native writer takes.
    def native_entry_options(entry)
      suppress = @suppress_extra_fields
      zip64_suppressed = suppress == true || [*suppress].include?(:zip64)
      extra = entry.extra.dup
      extra.suppress_fields!(suppress) if suppress
      extra.delete(:zip64) # the native writer emits its own

      level = entry.compression_level
      # An extra field may hand back a plain Time.
      time = DOSTime.from_time(entry.time)
      {
        method: entry.compression_method,
        level: (level if entry.compression_method != Entry::STORED && level &&
                         level != Zlib::DEFAULT_COMPRESSION),
        dos_date: time.to_binary_dos_date,
        dos_time: time.to_binary_dos_time,
        unix_perms: entry.unix_perms,
        fstype: entry.fstype,
        large_file: zip64_needed?(entry, zip64_suppressed),
        comment: entry.comment.to_s.b,
        extra: extra.to_local_bin.b,
        central_extra: extra.to_c_dir_bin.b
      }
    end

    # rubyzip writes a zip64 extra for a file entry only when it has to:
    # the size is unknown up front (it may turn out huge) or is already
    # over the 32-bit limit. The native writer does the same with
    # `large_file`.
    def zip64_needed?(entry, suppressed)
      return true if entry.size >= 0xFFFFFFFF || entry.compressed_size >= 0xFFFFFFFF
      return false if suppressed || !Ziperu.write_zip64_support || !entry.file?

      entry.zip64? || !entry.size_known?
    end
  end
end
