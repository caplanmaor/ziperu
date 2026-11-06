# frozen_string_literal: true

module Ziperu
  # Ziperu::File is modeled after java.util.zip.ZipFile from the Java SDK, with
  # rubyzip's API. The most important methods are those for accessing
  # information about the entries in the archive and `get_input_stream` /
  # `get_output_stream` for reading from and writing entries to it, plus the
  # conveniences `extract`, `extract_all`, `add_recursive`, `remove`,
  # `replace`, `rename` and `mkdir`.
  #
  # Modifications are not committed until `commit` or `close` is called.
  # `open` accepts a block following the pattern of ::File.open, closing the
  # archive when the block returns:
  #
  #   Ziperu::File.open('my.zip', create: true) do |zipfile|
  #     zipfile.get_output_stream('first.txt') { |f| f.puts 'Hello from Ziperu::File' }
  #     zipfile.mkdir('a_dir')
  #   end
  #
  # On commit, entries read from the archive are copied byte for byte
  # without recompression; only added or replaced entries are compressed.
  class File
    include Enumerable
    extend Forwardable

    IO_METHODS = [:tell, :seek, :read, :eof, :close].freeze # :nodoc:

    # The name of this zip archive.
    attr_reader :name

    attr_accessor :restore_ownership, :restore_permissions, :restore_times

    # The archive comment.
    attr_reader :comment

    def_delegators :@cdir, :each, :entries, :glob, :size

    # Opens a zip archive. Pass create: true to create a new archive if it
    # doesn't exist already.
    def initialize(path_or_io, create: false, buffer: false,
                   restore_ownership: DEFAULT_RESTORE_OPTIONS[:restore_ownership],
                   restore_permissions: DEFAULT_RESTORE_OPTIONS[:restore_permissions],
                   restore_times: DEFAULT_RESTORE_OPTIONS[:restore_times],
                   compression_level: ::Ziperu.default_compression,
                   suppress_extra_fields: false)
      super()

      @name    = path_or_io.respond_to?(:path) ? path_or_io.path : path_or_io
      @create  = create ? true : false # allow any truthy value to mean true

      initialize_cdir(path_or_io, buffer: buffer)

      @restore_ownership     = restore_ownership
      @restore_permissions   = restore_permissions
      @restore_times         = restore_times
      @compression_level     = compression_level
      @suppress_extra_fields = suppress_extra_fields
    end

    class << self
      include FileSplit

      # Similar to ::new. If a block is passed the Ziperu::File object is passed
      # to the block and is automatically closed afterwards.
      def open(file_name, create: false,
               restore_ownership: DEFAULT_RESTORE_OPTIONS[:restore_ownership],
               restore_permissions: DEFAULT_RESTORE_OPTIONS[:restore_permissions],
               restore_times: DEFAULT_RESTORE_OPTIONS[:restore_times],
               compression_level: ::Ziperu.default_compression,
               suppress_extra_fields: false)
        zf = ::Ziperu::File.new(file_name, create:                create,
                                        restore_ownership:     restore_ownership,
                                        restore_permissions:   restore_permissions,
                                        restore_times:         restore_times,
                                        compression_level:     compression_level,
                                        suppress_extra_fields: suppress_extra_fields)

        return zf unless block_given?

        begin
          yield zf
        ensure
          zf.close
        end
      end

      # Like #open, but reads zip archive contents from a String or open IO
      # stream, and outputs data to a buffer.
      def open_buffer(io = ::StringIO.new, create: false,
                      restore_ownership: DEFAULT_RESTORE_OPTIONS[:restore_ownership],
                      restore_permissions: DEFAULT_RESTORE_OPTIONS[:restore_permissions],
                      restore_times: DEFAULT_RESTORE_OPTIONS[:restore_times],
                      compression_level: ::Ziperu.default_compression,
                      suppress_extra_fields: false)
        unless IO_METHODS.map { |method| io.respond_to?(method) }.all? || io.kind_of?(String)
          raise 'Ziperu::File.open_buffer expects a String or IO-like argument' \
                "(responds to #{IO_METHODS.join(', ')}). Found: #{io.class}"
        end

        io = ::StringIO.new(io) if io.kind_of?(::String)

        zf = ::Ziperu::File.new(io, create: create, buffer: true,
                                 restore_ownership:     restore_ownership,
                                 restore_permissions:   restore_permissions,
                                 restore_times:         restore_times,
                                 compression_level:     compression_level,
                                 suppress_extra_fields: suppress_extra_fields)

        return zf unless block_given?

        yield zf

        begin
          zf.write_buffer(io)
        rescue IOError => e
          raise unless e.message == 'not opened for writing'
        end
      end

      # Iterates over the contents of the ZipFile.
      def foreach(zip_file_name, &block)
        ::Ziperu::File.open(zip_file_name) do |zip_file|
          zip_file.each(&block)
        end
      end

      # Count the entries in a zip archive without building entry objects.
      def count_entries(path_or_io)
        CentralDirectory.count_entries(path_or_io)
      end

      # Recursively adds the contents of `src_dir` to the new archive
      # `zip_file_name`, nested under `prefix` if given.
      def add_recursive(zip_file_name, src_dir, prefix: '', max_depth: 16, &continue_on_exists_proc)
        Ziperu::File.open(zip_file_name, create: true) do |zf|
          zf.add_recursive(src_dir, prefix: prefix, max_depth: max_depth, &continue_on_exists_proc)
        end
      end

      # Extracts every entry of the archive at `zip_file_name` into
      # `destination_directory`.
      def extract_all(zip_file_name, destination_directory = '.', &block)
        Ziperu::File.open(zip_file_name) do |zf|
          zf.extract_all(destination_directory, &block)
        end
      end
    end

    def comment=(comment)
      @dirty = true
      @comment = comment
    end

    # Returns an input stream to the specified entry. If a block is passed
    # the stream object is passed to the block and closed afterwards.
    def get_input_stream(entry, &a_proc)
      get_entry(entry).get_input_stream(&a_proc)
    end

    # Returns an output stream to the specified entry. If entry is not an
    # instance of Ziperu::Entry, a new Ziperu::Entry will be initialized using the
    # arguments specified. If a block is passed the stream object is passed
    # to the block and closed afterwards.
    def get_output_stream(entry, permissions: nil, comment: nil,
                          extra: nil, compressed_size: nil, crc: nil,
                          compression_method: nil, compression_level: nil,
                          size: nil, time: nil, &a_proc)
      new_entry =
        if entry.kind_of?(Entry)
          entry
        else
          Entry.new(
            @name, entry.to_s, comment: comment, extra: extra,
            compressed_size: compressed_size, crc: crc, size: size,
            compression_method: compression_method,
            compression_level: compression_level, time: time
          )
        end
      if new_entry.directory?
        raise ArgumentError,
              "cannot open stream to directory entry - '#{new_entry}'"
      end
      new_entry.unix_perms = permissions
      zip_streamable_entry = StreamableStream.new(new_entry)
      @cdir << zip_streamable_entry
      @dirty = true
      zip_streamable_entry.get_output_stream(&a_proc)
    end

    # Returns the name of the zip archive
    def to_s
      @name
    end

    # Returns a string containing the contents of the specified entry
    def read(entry)
      get_entry(entry).read_all
    end

    # Convenience method for adding the contents of a file to the archive
    def add(entry, src_path, &continue_on_exists_proc)
      continue_on_exists_proc ||= proc { ::Ziperu.continue_on_exists_proc }
      check_entry_exists(entry, continue_on_exists_proc, 'add')
      new_entry = if entry.kind_of?(::Ziperu::Entry)
                    entry
                  else
                    ::Ziperu::Entry.new(
                      @name, entry.to_s,
                      compression_level: @compression_level
                    )
                  end
      new_entry.gather_fileinfo_from_srcpath(src_path)
      @cdir << new_entry
      @dirty = true
      new_entry
    end

    # Convenience method for adding the contents of a file to the archive
    # in Stored format (uncompressed)
    def add_stored(entry, src_path, &continue_on_exists_proc)
      entry = ::Ziperu::Entry.new(
        @name, entry.to_s, compression_method: ::Ziperu::Entry::STORED
      )
      add(entry, src_path, &continue_on_exists_proc)
    end

    # Recursively adds the contents of `src_dir` to the archive, nested
    # under `prefix` if given. Symlinks are skipped with a warning;
    # `max_depth` limits how many directory levels are walked.
    def add_recursive(src_dir, prefix: '', max_depth: 16, &continue_on_exists_proc)
      raise Errno::ENOENT, src_dir unless ::File.directory?(src_dir)
      raise ArgumentError, 'max_depth must be at least 1' if max_depth < 1

      prefix = prefix.to_s
      prefix += '/' unless prefix.empty? || prefix.end_with?('/')

      add_recursive_dir(prefix, src_dir, 1, max_depth, continue_on_exists_proc)
      self
    end

    # Removes the specified entry.
    def remove(entry)
      found_entry = get_entry(entry)
      @dirty = true
      @cdir.delete(found_entry)
    end

    # Renames the specified entry.
    def rename(entry, new_name, &continue_on_exists_proc)
      found_entry = get_entry(entry)
      check_entry_exists(new_name, continue_on_exists_proc, 'rename')
      @cdir.delete(found_entry)
      found_entry.name = new_name
      @cdir << found_entry
      @dirty = true
      found_entry
    end

    # Replaces the specified entry with the contents of src_path (from
    # the file system).
    def replace(entry, src_path)
      check_file(src_path)
      remove(entry)
      add(entry, src_path)
    end

    # Extracts `entry` to a file at `entry_path`, with
    # `destination_directory` as the base. The block (or Ziperu.on_exists_proc)
    # decides whether an existing file is overwritten.
    def extract(entry, entry_path = nil, destination_directory: '.', &block)
      block ||= proc { ::Ziperu.on_exists_proc }
      found_entry = get_entry(entry)
      entry_path ||= found_entry.name
      found_entry.extract(entry_path, destination_directory: destination_directory, &block)
    end

    # Extracts every entry in the archive into `destination_directory`,
    # preserving the archive's directory structure. Symlink entries are
    # skipped with a warning; see `Entry#extract` for the path-safety checks
    # applied to every other entry.
    def extract_all(destination_directory = '.', &block)
      # Directories first, so files have somewhere to go.
      dirs, others = entries.partition(&:directory?)
      ordered = dirs + others

      # With no overwrite decision to make (no block, and Ziperu.on_exists_proc
      # left at its default of raising) the native core extracts every
      # qualifying entry in one call; the rest take the per-entry path.
      slow = if block.nil? && !::Ziperu.on_exists_proc && !@restore_ownership
               extract_all_native(ordered, destination_directory)
             else
               ordered
             end

      slow.each do |entry|
        if entry.symlink?
          warn "WARNING: skipped symlink '#{entry.name}' during extract_all."
          next
        end

        entry.extract(entry.name, destination_directory:     destination_directory,
                                  create_parent_directories: true, &block)
      end

      self
    end

    # Commits changes made since the previous commit to the zip archive: a
    # new archive is written beside the old one and renamed over it.
    def commit
      return if name.kind_of?(StringIO) || !commit_required?

      on_success_replace do |tmp_file|
        ::Ziperu::OutputStream.open(tmp_file, suppress_extra_fields: @suppress_extra_fields) do |zos|
          @cdir.each do |e|
            e.write_to_zip_output_stream(zos)
            e.clean_up
          end
          zos.comment = comment
        end
        true
      end
      initialize_cdir(@name)
    end

    # Writes the archive, with any changes, to `io` and returns it.
    def write_buffer(io = ::StringIO.new)
      return io unless commit_required?

      ::Ziperu::OutputStream.write_buffer(io, suppress_extra_fields: @suppress_extra_fields) do |zos|
        @cdir.each { |e| e.write_to_zip_output_stream(zos) }
        zos.comment = comment
      end
    end

    # Closes the zip file committing any changes that has been made.
    def close
      commit
      # A buffer stays readable after close (it is the caller's IO); a file
      # handle is released and reopened on demand by `native_archive`.
      release_native unless @buffer
    end

    # The open native archive behind this file, reopening it after `close`
    # so entries can still be read, as rubyzip allows.
    #
    # @api private
    def native_archive
      @native = InputStream.open_archive(@name) if @native.nil? || @native.closed?
      @native
    end

    # Returns true if any changes has been made to this archive since the
    # previous commit
    def commit_required?
      return true if @create || @dirty

      @cdir.each do |e|
        return true if e.dirty?
      end

      false
    end

    # Searches for entry with the specified name. Returns nil if no entry is
    # found. See also get_entry
    def find_entry(entry_name)
      selected_entry = @cdir.find_entry(entry_name)
      return if selected_entry.nil?

      selected_entry.restore_ownership   = @restore_ownership
      selected_entry.restore_permissions = @restore_permissions
      selected_entry.restore_times       = @restore_times
      selected_entry
    end

    # Searches for an entry just as find_entry, but throws Errno::ENOENT
    # if no entry is found.
    def get_entry(entry)
      selected_entry = find_entry(entry)
      raise Errno::ENOENT, entry if selected_entry.nil?

      selected_entry
    end

    # Creates a directory
    def mkdir(entry_name, permission = 0o755)
      raise Errno::EEXIST, "File exists - #{entry_name}" if find_entry(entry_name)

      entry_name = entry_name.dup.to_s
      entry_name << '/' unless entry_name.end_with?('/')
      new_entry = ::Ziperu::StreamableDirectory.new(@name, entry_name, nil, permission)
      @cdir << new_entry
      @dirty = true
      new_entry
    end

    private

    # Entries the native core cannot take are returned for the Ruby loop:
    # symlinks (skipped there with a warning), encrypted entries, entries
    # not read from this archive, and names it cannot represent.
    def extract_all_native(ordered, destination_directory)
      native = native_archive
      dest = ::File.absolute_path(destination_directory || '.')
      slow = []
      specs = []
      by_index = {}
      ordered.each do |entry|
        if entry.symlink? || entry.encrypted? || !native_extractable?(entry, native)
          slow << entry
        else
          specs << native_extract_spec(entry)
          by_index[entry.index] = entry
        end
      end

      # A few hundred entries per call, so an interrupt is noticed between
      # calls rather than after the whole archive.
      specs.each_slice(NATIVE_EXTRACT_BATCH) do |batch|
        native.extract_entries(dest, batch, ::Ziperu.validate_entry_sizes).each do |index, kind, path|
          entry = by_index[index]
          case kind
          when :unsafe
            warn "WARNING: skipped extracting '#{entry.name}' to '#{path}' as unsafe."
          when :oversize
            warn "WARNING: #{EntrySizeError.new(entry).message}"
          end
        end
      end

      slow
    end

    NATIVE_EXTRACT_BATCH = 256 # :nodoc:

    def native_extractable?(entry, native)
      return false unless entry.instance_of?(::Ziperu::Entry) && entry.index && entry.archive.equal?(native)
      return false unless entry.file? || entry.directory?

      name = entry.name
      name.ascii_only? || (name.encoding == ::Encoding::UTF_8 && name.valid_encoding?)
    end

    # What `Entry#extract` would do for the entry, as plain values:
    # [entry, index, name, mtime seconds, mtime nanoseconds, unix mode, directory?].
    def native_extract_spec(entry)
      mtime = entry.time if @restore_times
      mode = entry.unix_perms & 0o1777 if @restore_permissions && entry.fstype == FSTYPE_UNIX && entry.unix_perms
      [entry, entry.index, entry.name, mtime&.to_i, mtime&.nsec, mode, entry.directory?]
    end

    def add_recursive_dir(entry_prefix, src_dir, depth, max_depth, continue_on_exists_proc)
      ::Dir.children(src_dir).sort.each do |child|
        src_path = ::File.join(src_dir, child)

        if ::File.symlink?(src_path)
          warn "WARNING: skipped symlink '#{src_path}' while adding directory contents."
        elsif ::File.directory?(src_path)
          entry_name = "#{entry_prefix}#{child}/"
          add(entry_name, src_path, &continue_on_exists_proc)

          if depth < max_depth
            add_recursive_dir(entry_name, src_path, depth + 1, max_depth, continue_on_exists_proc)
          else
            warn "WARNING: max_depth (#{max_depth}) reached, not descending into '#{src_path}'."
          end
        elsif ::File.file?(src_path)
          add("#{entry_prefix}#{child}", src_path, &continue_on_exists_proc)
        else
          warn "WARNING: skipped '#{src_path}' - not a regular file or directory."
        end
      end
    end

    # (Re)reads the central directory, or starts an empty one for a new
    # archive.
    def initialize_cdir(path_or_io, buffer: false)
      release_native
      @buffer = buffer
      @cdir = ::Ziperu::EntrySet.new
      @comment = ''
      @dirty = false

      if ::File.size?(@name.to_s)
        # There is a file, which exists, that is associated with this zip.
        @create = false
        @file_permissions = ::File.stat(@name).mode
        read_archive(buffer ? path_or_io : @name)
      elsif buffer && path_or_io.size > 0
        # This zip is probably a non-empty StringIO.
        @create = false
        read_archive(path_or_io)
      elsif buffer && !@create
        raise Error, 'The buffer is empty. Did you mean to pass the create flag?'
      elsif !@create && ::File.empty?(@name)
        raise Error, "File #{@name} has zero size. Did you mean to pass the create flag?"
      elsif !@create
        raise Error, "File #{@name} not found"
      end
    end

    def read_archive(path_or_io)
      path_or_io.binmode if path_or_io.respond_to?(:binmode)
      @native = InputStream.open_archive(path_or_io)
      @comment = @native.comment # the stored bytes, as rubyzip reads them
      @native.entries.each { |meta| @cdir << Entry.from_meta(@native, meta, self) }
    end

    def release_native
      @native&.close
      @native = nil
    end

    # Windows refuses to replace a file that is still open. A stream the
    # caller forgot to close holds its own handle until the GC frees it, so
    # on failure collect garbage once and try again.
    def rename_over_original(tmp_filename)
      ::File.rename(tmp_filename, name)
    rescue Errno::EACCES
      raise unless ::Ziperu::RUNNING_ON_WINDOWS

      GC.start
      ::File.rename(tmp_filename, name)
    end

    def check_entry_exists(entry_name, continue_on_exists_proc, proc_name)
      return unless @cdir.include?(entry_name)

      continue_on_exists_proc ||= proc { Ziperu.continue_on_exists_proc }
      raise ::Ziperu::EntryExistsError.new proc_name, entry_name unless continue_on_exists_proc.call

      remove get_entry(entry_name)
    end

    def check_file(path)
      raise Errno::ENOENT, path unless ::File.readable?(path)
    end

    def on_success_replace
      dirname, basename = ::File.split(name)
      ::Dir::Tmpname.create(basename, dirname) do |tmp_filename|
        if yield tmp_filename
          # The native handle must be gone before the rename on Windows.
          release_native
          rename_over_original(tmp_filename)
          ::File.chmod(@file_permissions, name) unless @create
        end
      ensure
        FileUtils.rm_f(tmp_filename)
      end
    end
  end
end
