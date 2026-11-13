# frozen_string_literal: true

module Ziperu
  # Writes zip archives entry by entry, with rubyzip's `Zip::OutputStream`
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
    #
    # Any `Ziperu.*` setting is taken by its name too, for this archive
    # alone (`write_zip64_support:`, `write_extended_timestamps:`,
    # `unicode_names:`, `source_date_epoch:`; see Ziperu::Settings).
    def initialize(file_name, *legacy, stream: false, encrypter: nil, suppress_extra_fields: false,
                   memory: false, append: false, **opts)
      @settings = Settings.take!(opts)
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
      @aborted = false
      @current_entry = nil
      @written = []
      # On a stream, a file entry is begun in the native writer only when
      # its first bytes are written (or the next entry, or the end, comes):
      # until then nothing of it has gone out, so `rollback_entry` can
      # still take it back. Its name and options wait here.
      @deferred = nil
      @stream_names = {} if @streamed
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
      # Not in rubyzip.
      def body(**opts, &block)
        raise ArgumentError, 'a block that writes the entries is required' unless block

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
      @io.close if @io.respond_to?(:close)
      @closed = true
      nil
    end

    # Closes the stream after a failure, and the entries written so far
    # learn nothing from it. An append puts the archive back as it was. A
    # stream over an IO (`write_buffer`, `body`) is left unfinished, with
    # no central directory, so whoever receives it sees a broken archive
    # rather than a complete-looking one missing data; rubyzip leaves it
    # unfinished too. An archive at a path is closed, as rubyzip's `open`
    # does.
    def abort # :nodoc:
      @aborted = true
      discard_writes
      if @append || @io
        @writer.abort
        @closed = true
      else
        close
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
      compression_method = Entry::DEFLATED, level = nil, zip64: nil
    )
      check_open!

      new_entry =
        if entry_name.kind_of?(Entry) || entry_name.kind_of?(StreamableStream)
          entry_name
        else
          Entry.new(
            @file_name, entry_name.to_s, comment: comment, extra: extra,
            compression_method: compression_method, compression_level: level || @settings.default_compression,
            zip64: zip64,
            settings: @settings
          )
        end

      init_next_entry(new_entry)
      @written << new_entry
      @current_entry = new_entry
    end

    # Takes the entry being written back out of the archive, as if it had
    # never been put: the central directory will not list it, and the
    # next entry goes where it was. For an entry whose data could not be
    # had (a download that failed, say), so the rest of the archive can
    # still be written:
    #
    #   files.each do |name, url|
    #     zos.put_next_entry(name)
    #     begin
    #       fetch(url) { |chunk| zos << chunk }
    #     rescue Net::HTTPError
    #       zos.rollback_entry
    #     end
    #   end
    #
    # On a stream to an IO that cannot seek (`body`, `write_buffer` to a
    # pipe) bytes already sent cannot be taken back, so there it works
    # until the entry's first bytes are written, and raises after.
    # Returns the entry taken back.
    # Not in rubyzip.
    def rollback_entry
      check_open!
      entry = @current_entry
      raise Error, 'there is no entry being written to take back' if entry.nil? || !@written.last.equal?(entry)

      discard_writes
      if @deferred
        @deferred = nil
      else
        @writer.rollback_entry
      end
      @written.pop
      @stream_names&.delete(entry.name.b)
      @current_entry = nil
      entry
    end

    # Bytes handed to the IO so far, for a stream to an IO that cannot
    # seek (`write_buffer` to a pipe or socket, `body`): what the consumer
    # has been given, for a progress report alongside
    # `OutputStream.estimated_size`. Nil for a file or a seekable IO.
    # Not in rubyzip.
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
    # Not in rubyzip.
    def add_files(files, threads: 4)
      check_open!
      entries = files.map do |name, path|
        entry = Entry.new(@file_name, name.to_s, settings: @settings)
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
      entries.chunk { |e| put_kind(e, parallel) }.each do |kind, run|
        if kind == :from_disk && run.size > 1
          add_from_disk_parallel(run, threads)
        elsif kind.kind_of?(Native::Archive) && run.size > 1
          copy_raw_entries(kind, run)
        else
          run.each { |e| e.write_to_zip_output_stream(self) }
        end
      end
      nil
    end

    # How `put_entries` writes `entry`: :from_disk (compressed on the
    # pool), the native archive it is copied raw from as it is (runs of
    # those go in one call), or :one (by itself).
    def put_kind(entry, parallel)
      return :from_disk if parallel && entry.write_plan == :restream && entry.file? && !entry.filepath.nil?
      return entry.archive if entry.plain_raw_copy?

      :one
    end
    private :put_kind

    # Copies `entries`, all of `archive` and each as it is, in one call to
    # the native writer.
    def copy_raw_entries(archive, entries)
      check_open!
      start_deferred
      flush_writes
      if @stream_names
        entries.each do |e|
          name = e.name.b
          raise EntryExistsError.new('put_next_entry', e.name) if @stream_names.key?(name)

          @stream_names[name] = true
        end
      end
      @writer.raw_copy_many(archive, entries.map(&:index))
      @written.concat(entries)
      @current_entry = nil
    rescue Native::DuplicateEntryError
      raise_duplicate_among(entries)
    end
    private :copy_raw_entries

    # The native core refused a name already in the archive without saying
    # which; the names written so far and those of `entries` tell.
    def raise_duplicate_among(entries)
      names = @written.map(&:name) + entries.map(&:name)
      name = names.tally.find { |_, count| count > 1 }&.first || entries.first.name
      raise EntryExistsError.new('put_next_entry', name)
    end
    private :raise_duplicate_among

    # A batch is compressed to memory in full before it is appended, so
    # the batches are bounded by the bytes they read.
    PARALLEL_BATCH_BYTES = 256 * 1024 * 1024 # :nodoc:
    PARALLEL_BATCH_FILES = 512 # :nodoc:

    def add_from_disk_parallel(entries, threads)
      batch = []
      bytes = 0
      flush = lambda do
        items = batch.map { |e| [e.name.b, e.filepath.to_s, native_entry_options(e)] }
        flush_writes
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
      raise_duplicate_among(entries)
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
      start_deferred
      flush_writes
      @stream_names[(new_name || entry.name).to_s.b] = true if @stream_names
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
        zipcrypto: true, descriptor: entry.gp_flags.anybits?(Entry::DATA_DESCRIPTOR_GPFLAG)
      )
      start_deferred
      flush_writes
      @writer.copy_zipcrypto(entry.archive, entry.index, (new_name || entry.name).b, opts)
      @written << entry
      @current_entry = nil
    end

    # Writes shorter than this are gathered (see `<<`).
    SMALL_WRITE = 16 * 1024 # :nodoc:
    # Gathered writes go to the native writer once they reach this.
    WRITE_BUFFER = 64 * 1024 # :nodoc:

    # Modeled after IO.<<
    #
    # Small writes (`puts` of a line, `<<` of a field) are gathered here
    # and handed to the native writer 64 KB at a time: one call into it
    # costs about what deflating a few KB does. Whatever is gathered goes
    # in before anything else the writer does.
    def <<(data)
      raise IOError, 'closed stream' if @closed || @current_entry.nil?
      raise Error, "cannot write data to directory entry '#{@current_entry.name}'" if @current_entry.directory?

      start_deferred
      data = data.to_s
      if data.bytesize >= SMALL_WRITE
        flush_writes
        @writer.write(data.b)
      else
        gathered = (@gathered ||= +''.b)
        gathered << (data.encoding == ::Encoding::BINARY || data.ascii_only? ? data : data.b)
        flush_writes if gathered.bytesize >= WRITE_BUFFER
      end
      self
    end

    # Writes the file at `path` to the entry in progress, as `<<` of its
    # contents would, without reading them into Ruby.
    def write_file(path) # :nodoc:
      raise IOError, 'closed stream' if @closed || @current_entry.nil?

      start_deferred
      flush_writes
      @writer.write_file(path)
      self
    end

    private

    # Hands the gathered small writes (see `<<`) to the native writer.
    def flush_writes
      gathered = @gathered
      return if gathered.nil? || gathered.empty?

      # Taken first: should the write raise, the bytes are not written
      # again by the next flush.
      @gathered = nil
      @writer.write(gathered)
    end

    # Drops the gathered small writes, which belong to the entry being
    # taken back or abandoned.
    def discard_writes
      @gathered = nil
    end

    def finish_archive
      unless @keep_comment
        comment = @comment.to_s.b
        if comment.bytesize > MAX_FIELD_LENGTH
          raise ArgumentError,
                "archive comment is #{comment.bytesize} bytes; the limit is #{MAX_FIELD_LENGTH}"
        end

        @writer.comment = comment
      end
      start_deferred
      flush_writes
      @current_entry = nil
      begin
        bytes, stats = @writer.finish
      rescue IOError => e
        raise unless @io && e.message.include?('not opened for reading')

        raise Error, 'finishing an archive with ZipCrypto entries reads its headers back, which ' \
                     "the IO given does not allow (#{e.message}); open it for reading and writing"
      end
      unless @aborted
        if stats.size != @written.size
          raise Error, "the archive holds #{stats.size} entries where #{@written.size} were written"
        end

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

      start_deferred
      flush_writes
      opts = native_entry_options(entry)
      if @stream_names
        # The native writer would catch a second entry under a name only
        # once it begins it, which on a stream is later (see @deferred).
        raise EntryExistsError.new('put_next_entry', entry.name) if @stream_names.key?(entry.name.b)

        @stream_names[entry.name.b] = true
      end
      if entry.directory?
        @writer.add_directory(entry.name, opts)
      elsif entry.symlink?
        @writer.add_symlink(entry.name, entry.symlink_target, opts)
      else
        opts.merge!(@encrypter.native_options)
        if @streamed
          @deferred = [entry.name.b, opts]
        else
          @writer.start_entry(entry.name.b, opts)
        end
      end
    rescue Native::DuplicateEntryError
      raise EntryExistsError.new('put_next_entry', entry.name)
    end

    # Begins in the native writer the entry `init_next_entry` deferred.
    def start_deferred
      name, opts = @deferred
      return unless name

      @deferred = nil
      @writer.start_entry(name, opts)
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

    # Translate a Ziperu::Entry into the Hash the native writer takes.
    def native_entry_options(entry)
      suppress = @suppress_extra_fields
      zip64_suppressed = suppress == true || [*suppress].include?(:zip64)
      extra = entry.extra.dup
      add_default_fields(entry, extra)
      extra.suppress_fields!(suppress) if suppress
      extra.delete(:zip64) # the native writer emits its own

      level = entry.compression_level
      # An extra field may hand back a plain Time.
      time = DOSTime.from_time(entry.time)
      method = entry.compression_method
      # An empty XZ or PPMd entry is a stream with no blocks, which 7-Zip
      # refuses ("data after the end of the payload"); an empty file is
      # stored, as Info-ZIP stores every empty file.
      method = Entry::STORED if empty_entry?(entry) && [Entry::XZ, Entry::PPMD].include?(method)
      {
        method:        method,
        level:         (level if method != Entry::STORED && level && level != Zlib::DEFAULT_COMPRESSION),
        dos_date:      time.to_binary_dos_date,
        dos_time:      time.to_binary_dos_time,
        unix_perms:    entry.unix_perms,
        fstype:        entry.fstype,
        large_file:    zip64_needed?(entry, zip64_suppressed),
        comment:       entry.comment.to_s.b,
        extra:         extra.to_local_bin.b,
        central_extra: extra.to_c_dir_bin.b,
        # The language encoding flag on every entry (`Ziperu.unicode_names`),
        # which the native writer sets by patching the headers; a non-ASCII
        # UTF-8 name gets it from the native core regardless.
        efs:           entry.gp_flags.anybits?(Entry::EFS)
      }
    end

    def empty_entry?(entry)
      entry.size_known? && entry.size.zero? # rubocop:disable Style/ZeroLengthPredicate -- an Integer
    end

    # The fields a new entry gets unless it has them (see
    # `Ziperu.write_extended_timestamps`). An entry rewritten from an
    # archive keeps exactly the fields it had.
    def add_default_fields(entry, extra)
      return unless entry.archive.nil? || entry.pending_data?
      return unless @settings.write_extended_timestamps
      return if extra.member?(:universaltime) || extra.member?(:ntfs)

      extra.create(:universaltime).mtime = DOSTime.from_time(entry.time)
    end

    # rubyzip writes a zip64 extra for a file entry only when it has to:
    # the size is unknown up front (it may turn out huge) or is already
    # over the 32-bit limit. The native writer does the same with
    # `large_file`. An entry's own `zip64:` overrides that either way
    # (short of a size that leaves no choice), and
    # `Ziperu.write_zip64_support = :always` makes every file entry
    # zip64-ready, for testing readers.
    def zip64_needed?(entry, suppressed)
      return true if entry.size >= ZIP64_SIZE_LIMIT || entry.compressed_size >= ZIP64_SIZE_LIMIT
      return false unless entry.file?
      return entry.zip64 unless entry.zip64.nil?
      return true if @settings.write_zip64_support == :always && !suppressed
      return false if suppressed || !@settings.write_zip64_support

      entry.zip64? || !entry.size_known?
    end
  end
end
