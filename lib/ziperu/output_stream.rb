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
    # object that receives the archive bytes on `close_buffer`.
    def initialize(file_name, stream: false, encrypter: nil, suppress_extra_fields: false, **opts)
      super(**opts)
      @file_name = file_name
      @io = nil
      if stream
        @io = file_name
        @io.binmode if @io.respond_to?(:binmode)
        @writer = Native::Writer.open_memory
      else
        @writer = Native::Writer.open_path(file_name.to_s)
      end
      @encrypter = encrypter || ::Ziperu::NullEncrypter.new
      @suppress_extra_fields = suppress_extra_fields
      @comment = ''
      @closed = false
      @current_entry = nil
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
        yield zos
      ensure
        zos.close if zos
      end

      # Same as #open but writes to an IO instead; returns the IO.
      def write_buffer(io = ::StringIO.new, encrypter: nil, suppress_extra_fields: false, **opts)
        zos = new(io, stream: true, encrypter: encrypter,
                      suppress_extra_fields: suppress_extra_fields, **opts)
        yield zos
        zos.close_buffer
      end
    end

    # Closes the stream and writes the central directory. A stream over an
    # IO (`stream: true`) writes the archive to it and closes it, as
    # rubyzip does; `close_buffer` is the variant that leaves it open.
    def close
      return if @closed

      bytes = finish_archive
      if @io
        write_archive_to_io(bytes)
        @io.close if @io.respond_to?(:close)
      end
      @closed = true
      nil
    end

    # Closes the stream and writes the archive to the IO given to
    # `write_buffer`; returns that IO.
    def close_buffer
      return @io if @closed

      bytes = finish_archive
      write_archive_to_io(bytes) if @io
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

      touch_opts =
        if touch && new_name.nil?
          time = entry.time
          { dos_date: time.to_binary_dos_date, dos_time: time.to_binary_dos_time,
            unix_perms: entry.unix_perms }
        end
      @writer.raw_copy(entry.archive, entry.index, new_name, touch_opts)
      @current_entry = nil
    end

    # Modeled after IO.<<
    def <<(data)
      raise IOError, 'closed stream' if @closed || @current_entry.nil?

      @writer.write(data.to_s.b)
      self
    end

    private

    def finish_archive
      comment = @comment.to_s.b
      raise ArgumentError, "archive comment is #{comment.bytesize} bytes; the limit is 65535" if comment.bytesize > 0xFFFF

      @writer.comment = comment
      @current_entry = nil
      @writer.finish
    end

    # Like rubyzip, the archive is written from the start of the IO.
    def write_archive_to_io(bytes)
      @io.rewind if @io.respond_to?(:rewind)
      @io.write(bytes)
      @io.flush if @io.respond_to?(:flush)
    end

    def init_next_entry(entry)
      unless [Entry::STORED, Entry::DEFLATED].include?(entry.compression_method)
        raise ::Ziperu::CompressionMethodError, entry.compression_method
      end

      opts = native_entry_options(entry)
      if entry.directory?
        @writer.add_directory(entry.name, opts)
      else
        opts.merge!(@encrypter.native_options)
        @writer.start_entry(entry.name.b, opts)
      end
    end

    # Translate a Ziperu::Entry into the Hash the native writer takes.
    def native_entry_options(entry)
      suppress = @suppress_extra_fields
      zip64_suppressed = suppress == true || [*suppress].include?(:zip64)
      extra = entry.extra.dup
      extra.suppress_fields!(suppress) if suppress
      extra.delete(:zip64) # the native writer emits its own

      level = entry.compression_level
      time = entry.time
      {
        method: entry.compression_method,
        level: (level if entry.compression_method == Entry::DEFLATED && level &&
                         level != Zlib::DEFAULT_COMPRESSION),
        dos_date: time.to_binary_dos_date,
        dos_time: time.to_binary_dos_time,
        unix_perms: entry.unix_perms,
        fstype: entry.fstype,
        large_file: zip64_needed?(entry, zip64_suppressed),
        comment: entry.comment.to_s.b,
        extra: extra.to_local_bin.b
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
