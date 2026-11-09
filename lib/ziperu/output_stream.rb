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

    attr_reader :comment

    def comment=(comment)
      @keep_comment = false
      @comment = comment
    end

    # Opens the indicated zip file. If a file with that name already exists
    # it will be overwritten. With `stream: true`, `file_name` is an IO
    # object that receives the archive from its start, entry by entry. A
    # seekable IO (a StringIO, File or Tempfile) gets each entry's sizes in
    # its header; an IO that cannot seek (a pipe, a socket, a response
    # body) gets them in a data descriptor after the entry's data, as
    # rubyzip writes them, and never has to hold the archive in memory.
    # ZipCrypto entries need their headers patched once the data is
    # written, so with a `TraditionalEncrypter` (or `memory: true`) the
    # archive is built in memory and written out in one go at `close`.
    def initialize(file_name, *legacy, stream: false, encrypter: nil, suppress_extra_fields: false,
                   memory: false, append: false, **opts)
      super(**opts)
      # rubyzip 2.x's `new(io, stream, encrypter)`.
      stream, encrypter = Compat.positional(legacy, %i[stream encrypter],
                                            stream: stream, encrypter: encrypter)
                                .values_at(:stream, :encrypter)
      @file_name = file_name
      @io = nil
      @append = append
      @streamed = false
      @encrypter = encrypter || ::Ziperu::NullEncrypter.new
      if append
        # Adds to the archive at `file_name` in place: the entries it holds
        # stay as they are and the new ones follow them. Its comment is
        # kept unless `comment=` is called.
        raise ArgumentError, 'append: takes a path, not an IO' if stream
        @writer = Native::Writer.open_append(file_name.to_s)
      elsif stream
        @io = file_name
        IOExtras.binmode(@io)
        @writer =
          if IOExtras.seekable?(@io)
            @io.rewind if @io.respond_to?(:rewind)
            Native::Writer.open_io(@io)
          elsif memory || @encrypter.kind_of?(TraditionalEncrypter)
            # ZipCrypto headers are patched once the data is written, which
            # a stream cannot take: the archive is built in memory and
            # written out in one go at `close`.
            Native::Writer.open_memory
          else
            # A pipe, socket or response body: each entry goes out as it is
            # written, with its sizes in a data descriptor after the data.
            @streamed = true
            Native::Writer.open_stream(@io)
          end
      else
        @writer = Native::Writer.open_path(file_name.to_s)
      end
      @suppress_extra_fields = suppress_extra_fields
      @comment = ''
      # An append keeps the archive's own comment unless one is set.
      @keep_comment = append
      @closed = false
      @current_entry = nil
      @written = []
    end

    class << self
      # Same as #initialize (same keywords) but if a block is passed the
      # opened stream is passed to the block and closed when the block
      # returns.
      def open(file_name, *legacy, **opts)
        # rubyzip 2.x's `open(path, encrypter)`.
        opts = Compat.positional(legacy, %i[encrypter], opts)
        return new(file_name, **opts) unless block_given?

        zos = new(file_name, stream: false, **opts)
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

      # Same as #open but writes to an IO instead; returns the IO. A pipe,
      # socket or response body is streamed to as the entries are written.
      def write_buffer(io = ::StringIO.new, *legacy, **opts)
        # rubyzip 2.x's `write_buffer(io, encrypter)`.
        opts = Compat.positional(legacy, %i[encrypter], opts)
        zos = new(io, stream: true, **opts)
        begin
          yield zos
        rescue Exception # rubocop:disable Lint/RescueException
          zos.abort
          raise
        end
        zos.close_buffer
      end

      # The archive as an Enumerator of its bytes, in chunks, produced as
      # they are consumed: a Rack response body, or anything else that
      # takes an `each`. The block runs when the chunks are first asked
      # for, not here, and the whole archive is never in memory.
      #
      #   body = Ziperu::OutputStream.body do |zos|
      #     zos.put_next_entry("report.csv")
      #     zos.write(csv)
      #   end
      #   [200, { "content-type" => "application/zip" }, body]
      #
      # With `.next` the chunks can be pulled one at a time (a Fiber under
      # the hood, as with any Enumerator); `body.each { |chunk| ... }` is
      # the direct path. Writing the entries inside the block is the same
      # as with #open and #write_buffer.
      def body(**opts, &block)
        raise ArgumentError, "a block that writes the entries is required" unless block

        Enumerator.new { |yielder| write_buffer(Yielder.new(yielder), **opts, &block) }
      end
    end

    # A write-only IO over an Enumerator's yielder, for #body.
    class Yielder # :nodoc:
      def initialize(yielder)
        @yielder = yielder
      end

      def write(chunk)
        @yielder << chunk
        chunk.bytesize
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
    # archive they were written to is not going to be used. An append
    # puts the archive back as it was.
    def abort # :nodoc:
      @aborted = true
      if @append
        @writer.abort
        @closed = true
      else
        @io ? close_buffer : close
      end
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
      check_open!

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

    # Bytes handed to the IO so far, for a stream to an IO that cannot
    # seek (`write_buffer` to a pipe or socket, `body`): what the consumer
    # has been given, for a progress report alongside
    # `OutputStream.estimated_size`. Nil for a file or a seekable IO.
    def bytes_written
      @writer.bytes_written
    end

    # Adds files from disk, compressed on `threads` threads: `files` maps
    # entry names to paths (a Hash, or pairs). The entries come out in the
    # order given, each compressed in memory on the pool and appended as
    # it is ready, so the archive is the same as with `put_next_entry` and
    # `write` one by one, only faster on a multi-core machine.
    #
    #   Ziperu::OutputStream.open("site.zip") do |zos|
    #     zos.add_files({ "index.html" => "public/index.html", ... }, threads: 8)
    #   end
    #
    # Encrypted streams and streams to an IO that cannot seek add the files
    # one by one instead.
    def add_files(files, threads: 4)
      check_open!
      entries = files.map do |name, path|
        entry = Entry.new(@file_name, name.to_s)
        entry.gather_fileinfo_from_srcpath(path)
        entry
      end
      put_entries(entries, threads: threads)
    end

    # Writes `entries` as `Entry#write_to_zip_output_stream` would, one by
    # one, except that runs of plain files from disk go through
    # `add_files_parallel` when `threads` is above one and this stream can
    # take it (seekable sink, no encryption).
    def put_entries(entries, threads: 1) # :nodoc:
      parallel = threads > 1 && !@streamed && @encrypter.kind_of?(NullEncrypter)
      entries.chunk { |e| parallel && e.write_plan == :restream && e.file? && !e.filepath.nil? }
             .each do |from_disk, run|
        if from_disk && run.size > 1
          add_from_disk_parallel(run, threads)
        else
          run.each { |e| e.write_to_zip_output_stream(self) }
        end
      end
      nil
    end

    # A batch is compressed to memory in full before it is appended, so
    # the batches are bounded by the bytes they read.
    PARALLEL_BATCH_BYTES = 256 * 1024 * 1024 # :nodoc:
    PARALLEL_BATCH_FILES = 512 # :nodoc:

    def add_from_disk_parallel(entries, threads)
      batch = []
      bytes = 0
      flush = lambda do
        items = batch.map { |e| [e.name.b, e.filepath.to_s, native_entry_options(e)] }
        @writer.add_files_parallel(items, threads)
        @written.concat(batch)
        batch = []
        bytes = 0
      end
      entries.each do |e|
        flush.call if !batch.empty? && (bytes + e.size > PARALLEL_BATCH_BYTES || batch.size >= PARALLEL_BATCH_FILES)
        batch << e
        bytes += e.size
      end
      flush.call unless batch.empty?
      @current_entry = nil
    rescue Native::DuplicateEntryError
      # The native core does not say which; the names tell.
      names = @written.map(&:name) + entries.map(&:name)
      name = names.tally.find { |_, count| count > 1 }&.first || entries.first.name
      raise EntryExistsError.new('put_next_entry', name)
    end
    private :add_from_disk_parallel

    # Copies an entry from another archive without recompressing it. With
    # `touch: true` the entry's current permissions and mtime are written
    # instead of the source's. The native writer can do that or a rename,
    # not both, and carries nothing else over from the entry object;
    # `Entry#write_to_zip_output_stream` re-streams edited entries instead.
    def copy_raw_entry(entry, new_name = nil, touch: false) # :nodoc:
      raise Error, 'entry is not a ZipEntry' unless entry.kind_of?(Entry)

      check_copyable!(entry)
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
      check_copyable!(entry)
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
      unless @keep_comment
        comment = @comment.to_s.b
        if comment.bytesize > 0xFFFF
          raise ArgumentError, "archive comment is #{comment.bytesize} bytes; the limit is 65535"
        end

        @writer.comment = comment
      end
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

    def check_open!
      raise Error, 'zip stream is closed' if @closed
    end

    # An entry can be copied raw when it is in an archive and the native
    # core can address it by index (not one of several under one name).
    def check_copyable!(entry)
      check_open!
      raise Error, "entry '#{entry.name}' is not in an archive" if entry.archive.nil?
      return unless entry.index.nil?

      raise Error, "entry '#{entry.name}' shares its name with another record and cannot be copied raw"
    end
    private :check_open!, :check_copyable!

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
