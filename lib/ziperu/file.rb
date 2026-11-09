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
    # rubyzip 2.x's `Zip::File.open(path, Zip::File::CREATE)`. Libraries
    # that branch on `Zip::VERSION >= "3"` (sablon, selenium-webdriver) see
    # ziperu's own version and take their 2.x path, so both forms work.
    CREATE = true

    def initialize(path_or_io, *legacy, create: false, buffer: false,
                   restore_ownership: DEFAULT_RESTORE_OPTIONS[:restore_ownership],
                   restore_permissions: DEFAULT_RESTORE_OPTIONS[:restore_permissions],
                   restore_times: DEFAULT_RESTORE_OPTIONS[:restore_times],
                   compression_level: ::Ziperu.default_compression,
                   suppress_extra_fields: false, password: nil, decrypter: nil,
                   write: true, threads: 1)
      super()

      # On commit, runs of files added from disk are compressed on this
      # many threads (see OutputStream#add_files).
      @threads = threads

      # Where changes go on commit. `true`: back into the archive opened,
      # as rubyzip does. `false`: nowhere; the archive is read-only and
      # any change raises. A path: a new archive is written there with the
      # changes, and the one opened is left as it was.
      @write_to = write.kind_of?(::String) || write.respond_to?(:to_path) ? IOExtras.path_of(write) : nil
      @read_only = write == false
      raise ArgumentError, 'create: true and write: false contradict each other' if @read_only && create
      raise ArgumentError, 'write: takes true, false or a path' unless write == true || @read_only || @write_to

      # One password for the archive: `read`, `get_input_stream`,
      # `extract`, `extract_all` and `verify` decrypt with it (AES or
      # ZipCrypto, whichever each entry uses). rubyzip only takes a
      # decrypter on `InputStream`; `decrypter:` is accepted here too.
      @password = password || decrypter&.password

      @name    = if IOExtras.path_like?(path_or_io)
                   IOExtras.path_of(path_or_io)
                 elsif path_or_io.respond_to?(:path)
                   path_or_io.path
                 else
                   path_or_io
                 end
      # rubyzip 2.x's positional form: `new(path, create, buffer, options)`,
      # the options being the restore_* and compression_level keywords.
      given = Compat.positional(legacy, %i[create buffer options], create: create, buffer: buffer)
      create = given[:create]
      buffer = given[:buffer]
      if (options = given[:options])
        restore_ownership   = options.fetch(:restore_ownership, restore_ownership)
        restore_permissions = options.fetch(:restore_permissions, restore_permissions)
        restore_times       = options.fetch(:restore_times, restore_times)
        compression_level   = options.fetch(:compression_level, compression_level)
      end
      @create  = create ? true : false # allow any truthy value to mean true

      initialize_cdir(path_or_io, buffer: buffer)

      @restore_ownership     = restore_ownership
      @restore_permissions   = restore_permissions
      @restore_times         = restore_times
      @compression_level     = compression_level
      @suppress_extra_fields = suppress_extra_fields
    end

    # Threads a commit compresses files added from disk on.
    attr_accessor :threads

    # Opened with `write: false`: nothing can be changed.
    def read_only?
      @read_only
    end

    # The path changes are written to on commit (`write: path`), or nil
    # when they go back into the archive opened.
    attr_reader :write_to

    class << self
      include FileSplit

      # Same as ::new (same keywords: `create:`, `restore_ownership:`,
      # `restore_permissions:`, `restore_times:`, `compression_level:`,
      # `suppress_extra_fields:`, `password:`, `decrypter:`). If a block is
      # passed the Ziperu::File object is passed to the block and is
      # automatically closed afterwards.
      def open(file_name, *legacy, **options)
        # rubyzip 2.x's `open(path, create, options)`.
        legacy.insert(1, nil) if legacy.size == 2 # no positional `buffer` here
        zf = ::Ziperu::File.new(file_name, *legacy, **options)

        return zf unless block_given?

        begin
          yield zf
        ensure
          zf.close
        end
      end

      # rubyzip 2.x's way to build an archive in memory (3.x dropped it):
      # yields a new archive over a StringIO and returns that StringIO,
      # written, when the block is done. `open_buffer(create: true)` is
      # the current form.
      def add_buffer
        io = ::StringIO.new
        zf = ::Ziperu::File.new(io, create: true, buffer: true)
        yield zf
        zf.write_buffer(io)
      end

      # Like #open (same keywords), but reads zip archive contents from a
      # String or open IO stream, and outputs data to a buffer.
      def open_buffer(io = ::StringIO.new, **options)
        if options[:write].kind_of?(::String) || options[:write].respond_to?(:to_path)
          raise ArgumentError, 'open_buffer takes write: true or false, not a path'
        end
        unless IO_METHODS.all? { |method| io.respond_to?(method) } || io.kind_of?(String)
          raise 'Ziperu::File.open_buffer expects a String or IO-like argument' \
                "(responds to #{IO_METHODS.join(', ')}). Found: #{io.class}"
        end

        io = ::StringIO.new(io) if io.kind_of?(::String)
        # A pipe or socket answers to seek but cannot: reading the central
        # directory would block forever. `InputStream` reads those.
        unless io.kind_of?(::StringIO) || IOExtras.seekable?(io)
          raise ArgumentError, 'Ziperu::File.open_buffer needs a seekable IO; '                                'use Ziperu::InputStream for a pipe or socket'
        end

        zf = ::Ziperu::File.new(io, buffer: true, **options)

        return zf unless block_given?

        yield zf
        return io if zf.read_only?

        begin
          zf.write_buffer(io)
        rescue IOError => e
          raise unless e.message == 'not opened for writing'
        end
      end

      # Yields each entry of the archive at `path_or_io`, in order, without
      # building the whole listing first: the way to walk an archive with
      # hundreds of thousands of entries, or to stop at the first match.
      # Each entry can be read (`get_input_stream`, `extract`) while the
      # block runs; the archive is closed when `foreach` returns. Without a
      # block, returns an Enumerator.
      def foreach(path_or_io, &block)
        return enum_for(:foreach, path_or_io) unless block

        native = InputStream.open_archive(path_or_io)
        begin
          native.each_entry { |meta| yield Entry.from_meta(native, meta, nil) }
        ensure
          native.close
        end
        nil
      end

      # Count the entries in a zip archive without building entry objects.
      def count_entries(path_or_io)
        CentralDirectory.count_entries(path_or_io)
      end

      # Recursively adds the contents of `src_dir` to the new archive
      # `zip_file_name`, nested under `prefix` if given.
      def add_recursive(zip_file_name, src_dir, prefix: '', max_depth: 16, threads: 1, &continue_on_exists_proc)
        Ziperu::File.open(zip_file_name, create: true, threads: threads) do |zf|
          zf.add_recursive(src_dir, prefix: prefix, max_depth: max_depth, &continue_on_exists_proc)
        end
      end

      # Extracts every entry of the archive at `zip_file_name` into
      # `destination_directory`.
      def extract_all(zip_file_name, destination_directory = '.', **options, &block)
        Ziperu::File.open(zip_file_name) do |zf|
          zf.extract_all(destination_directory, **options, &block)
        end
      end
    end

    def comment=(comment)
      check_writable!
      @dirty = true
      @comment_changed = true
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
    def get_output_stream(entry, *legacy, permissions: nil, compression_level: nil, **entry_opts,
                          &a_proc)
      check_writable!
      # rubyzip 2.x's positional form, `(name, 0o644)` mostly.
      given = Compat.positional(
        legacy, %i[permissions comment extra compressed_size crc compression_method size time],
        entry_opts.merge(permissions: permissions)
      )
      permissions = given.delete(:permissions)
      new_entry =
        if entry.kind_of?(Entry)
          entry
        else
          Entry.new(@name, entry.to_s, compression_level: compression_level, **given)
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
      check_writable!
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
      if src_path.respond_to?(:read)
        # An IO (File, StringIO, Tempfile, a socket): streamed at commit.
        new_entry.gather_fileinfo_from_io(src_path)
      else
        new_entry.gather_fileinfo_from_srcpath(src_path)
      end
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
    #
    # `progress:` is called with `(entry, done, nil)` after each file or
    # directory is added; the total is not known up front.
    def add_recursive(src_dir, prefix: '', max_depth: 16, progress: nil, &continue_on_exists_proc)
      raise Errno::ENOENT, src_dir unless ::File.directory?(src_dir)
      raise ArgumentError, 'max_depth must be at least 1' if max_depth < 1

      prefix = prefix.to_s
      prefix += '/' unless prefix.empty? || prefix.end_with?('/')

      done = 0
      report = ->(entry) { done += 1; progress&.call(entry, done, nil) }
      add_recursive_dir(prefix, src_dir, 1, max_depth, continue_on_exists_proc, report)
      self
    end

    # Removes the specified entry.
    def remove(entry)
      check_writable!
      found_entry = get_entry(entry)
      @dirty = true
      @cdir.delete(found_entry)
    end

    # Renames the specified entry.
    def rename(entry, new_name, &continue_on_exists_proc)
      check_writable!
      found_entry = get_entry(entry)
      new_name = new_name.to_path if new_name.respond_to?(:to_path)
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
      check_writable!
      check_file(src_path)
      remove(entry)
      add(entry, src_path)
    end

    # Extracts `entry` to a file at `entry_path`, with
    # `destination_directory` as the base. The block (or Ziperu.on_exists_proc)
    # decides whether an existing file is overwritten.
    def extract(entry, entry_path = nil, destination_directory: '.', symlinks: :skip, on_exists: nil,
                &block)
      found_entry = get_entry(entry)
      entry_path ||= found_entry.name
      found_entry.extract(entry_path, destination_directory: destination_directory,
                                      symlinks: symlinks, on_exists: on_exists, &block)
    end

    # Extracts every entry in the archive into `destination_directory`,
    # preserving the archive's directory structure. Symlink entries are
    # skipped with a warning; see `Entry#extract` for the path-safety checks
    # applied to every other entry.
    #
    # `symlinks:` is `:skip` (the default, with a warning per link, as in
    # rubyzip 3) or `:create`, which creates links whose target stays inside
    # `destination_directory`. `progress:` is called with
    # `(entry, done, total)` after each entry.
    # `threads: n` extracts the files on that many threads (the archive is
    # read through one handle per thread); a file or String archive only,
    # since an IO is driven from Ruby. Directories are made first, links
    # last, as before. An error is raised for the first entry (in archive
    # order) that failed, once every thread has stopped.
    #
    # The policies `unzip` has: `on_exists:` is `:raise` (the default),
    # `:overwrite` (`unzip -o`) or `:skip` (`unzip -n`) for a path already
    # taken, where rubyzip only offers a block; `exclude:` lists globs (or
    # Regexps) of entry names to leave out (`unzip -x`), matched against
    # the whole name, so `"*.log"` matches at any depth; `junk_paths: true`
    # drops the directories and puts every file in `destination_directory`
    # itself (`unzip -j`); `sanitize: :windows` rewrites names that Windows
    # refuses (`<>:"|?*`, control characters, a trailing dot or space,
    # `CON`, `NUL` and the like) so the archive extracts there at all.
    def extract_all(destination_directory = '.', symlinks: :skip, progress: nil, threads: 1,
                    on_exists: nil, exclude: nil, junk_paths: false, sanitize: nil, &block)
      # Directories first, so files have somewhere to go; links last, so
      # nothing is written through one. Of several records under one name
      # only the last is extracted, which is the one rubyzip would know.
      dirs, rest = @cdir.writable_entries.partition(&:directory?)
      links, others = rest.partition(&:symlink?)
      ordered = dirs + others + links
      ordered = ordered.reject { |e| excluded?(e.name, exclude) } if exclude
      ordered = ordered.reject(&:directory?) if junk_paths
      targets = ordered.map { |e| [e, extract_target(e.name, junk_paths, sanitize)] }
      total = targets.size
      done = 0
      report = ->(entry) { done += 1; progress&.call(entry, done, total) }

      # With no block to consult about paths already taken (the policy
      # says, or Ziperu.on_exists_proc), the native core extracts every
      # qualifying entry in one call; the rest take the per-entry path.
      policy = on_exists || (::Ziperu.on_exists_proc ? :overwrite : :raise)
      slow = if block.nil? && !@restore_ownership
               extract_all_native(targets, destination_directory, report, threads, policy)
             else
               targets
             end

      slow.each do |entry, target|
        if entry.symlink? && symlinks != :create
          warn "WARNING: skipped symlink '#{entry.name}' during extract_all."
        else
          entry.extract(target, destination_directory:     destination_directory,
                                create_parent_directories: true,
                                symlinks:                  symlinks,
                                on_exists:                 on_exists, &block)
        end
        report.call(entry)
      end

      self
    end

    # Whether `name` matches one of `patterns`: a glob (`File.fnmatch`
    # with `*` crossing `/`, as `unzip -x` has it) or a Regexp.
    def excluded?(name, patterns)
      Array(patterns).any? do |pattern|
        case pattern
        when ::Regexp then pattern.match?(name)
        else ::File.fnmatch?(pattern.to_s, name, ::File::FNM_EXTGLOB | ::File::FNM_DOTMATCH)
        end
      end
    end
    private :excluded?

    # The path under the destination an entry goes to.
    def extract_target(name, junk_paths, sanitize)
      name = ::File.basename(name) if junk_paths
      case sanitize
      when nil, false then name
      when :windows then self.class.sanitize_windows_name(name)
      else raise ArgumentError, "sanitize: takes :windows, not #{sanitize.inspect}"
      end
    end
    private :extract_target

    WINDOWS_RESERVED_NAMES = /\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\z)/i # :nodoc:

    # `name` as Windows will take it: in each component the characters it
    # refuses (`<>:"|?*` and controls) become `_`, a trailing dot or space
    # goes, and a reserved device name gets a leading `_`.
    def self.sanitize_windows_name(name)
      trailing = name.end_with?('/') ? '/' : ''
      parts = name.split('/').map do |part|
        part = part.gsub(/[<>:"|?*\x00-\x1f]/, '_').sub(/[. ]+\z/, '')
        part = "_#{part}" if part.match?(WINDOWS_RESERVED_NAMES)
        part.empty? ? '_' : part
      end
      parts.join('/') + trailing
    end

    # Inflates every entry (without writing anything) so that the CRC of
    # each is checked. Returns a Hash of the entries that failed to the
    # exception raised for them; empty when the archive is sound. Encrypted
    # entries are checked when a `decrypter` is given and skipped otherwise.
    def verify(decrypter: nil)
      native = native_archive
      password = (decrypter&.password || @password)&.b
      failures = {}
      entries.each do |entry|
        # An entry replaced from disk has nothing in the archive to check.
        next if entry.directory? || !entry.backed_by?(native)
        next if entry.encrypted? && password.nil?

        begin
          if entry.index
            native.verify_entry(entry.index, password)
          else
            native.verify_entry_at(entry.local_header_offset, entry.size, entry.compressed_size,
                                   entry.crc, password)
          end
        rescue Error, IOError => e
          failures[entry] = e
        end
      end
      failures
    end

    # Commits changes made since the previous commit to the zip archive: a
    # new archive is written beside the old one and renamed over it.
    def commit
      return if name.kind_of?(StringIO) || !commit_required?

      if @write_to
        # The changes go to a new archive; the one opened is not touched,
        # and keeps being what this object reads.
        ::Ziperu::OutputStream.open(@write_to, suppress_extra_fields: @suppress_extra_fields) do |zos|
          zos.put_entries(@cdir.writable_entries, threads: @threads)
          zos.comment = comment
        end
      elsif (appended = appended_entries)
        # Only additions: they go after the entries already there, which
        # are left untouched (see Ziperu.append_in_place). A failure puts
        # the archive back as it was.
        ::Ziperu::OutputStream.open(@name, append: true,
                                           suppress_extra_fields: @suppress_extra_fields) do |zos|
          zos.put_entries(appended, threads: @threads)
        end
      else
        on_success_replace do |tmp_file|
          ::Ziperu::OutputStream.open(tmp_file, suppress_extra_fields: @suppress_extra_fields) do |zos|
            zos.put_entries(@cdir.writable_entries, threads: @threads)
            zos.comment = comment
          end
          true
        end
      end
      # Only now are the changes on disk; until here the entries keep
      # their dirty state so a failed commit can be retried.
      @cdir.each(&:clean_up)
      initialize_cdir(@name)
    end

    # The entries to append, when the pending changes are additions and
    # nothing else: every entry the archive holds is still listed, in
    # place, unchanged, and the comment is as it was. Nil otherwise, and
    # the archive is rewritten.
    def appended_entries
      return nil if @create || @buffer || @native.nil? || @comment_changed || ::Ziperu.sort_entries
      return nil unless ::Ziperu.append_in_place

      all = @cdir.entries
      held = @native.entry_count
      return nil if all.size <= held || all.first(held).each_with_index.any? do |e, i|
        !(e.index == i && e.backed_by?(@native) && !e.dirty? && !e.needs_restream? &&
          !e.extra_changed? && !@cdir.shadowed?(e))
      end

      all.drop(held)
    end
    private :appended_entries

    # Writes the archive, with any changes, to `io` and returns it. `io`
    # may be a pipe, socket or response body: entries are streamed to it
    # as they are written, unless the archive holds ZipCrypto entries,
    # whose headers are patched at the end; such an archive is built in
    # memory first.
    def write_buffer(io = ::StringIO.new)
      return io unless commit_required?

      # Rewriting the archive into the very IO it is read from would
      # overwrite entries still to be copied; build it aside first.
      if @buffer && io.equal?(@io) && !io.kind_of?(::StringIO)
        built = write_buffer(::StringIO.new).string
        io.rewind
        io.write(built)
        io.truncate(built.bytesize) if io.respond_to?(:truncate)
        return io
      end

      # ZipCrypto entries are copied with patched headers, which a stream
      # (a pipe, say) cannot take: such an archive is built in memory first.
      memory = @cdir.writable_entries.any?(&:zipcrypto?)
      ::Ziperu::OutputStream.write_buffer(io, suppress_extra_fields: @suppress_extra_fields,
                                              memory: memory) do |zos|
        @cdir.each_writable { |e| e.write_to_zip_output_stream(zos) }
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
    # The archive's password, if one was given to `open`.
    def password # :nodoc:
      @password
    end

    # Raises when the archive was opened with `write: false`.
    def check_writable!
      raise Error, "#{name} was opened read-only (write: false)" if @read_only
    end
    private :check_writable!

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
      check_writable!
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
    def extract_all_native(targets, destination_directory, report, threads, on_exists)
      native = native_archive
      dest = ::File.absolute_path(destination_directory || '.')
      code = Entry.on_exists_code(on_exists)
      slow = []
      specs = []
      by_index = {}
      targets.each do |entry, target|
        if entry.symlink? || entry.encrypted? || !native_extractable?(entry, native)
          slow << [entry, target]
        else
          specs << native_extract_spec(entry, target)
          by_index[entry.index] = entry
        end
      end

      # A few hundred entries per call, so an interrupt is noticed between
      # calls rather than after the whole archive.
      specs.each_slice(NATIVE_EXTRACT_BATCH) do |batch|
        native.extract_entries(dest, batch, ::Ziperu.validate_entry_sizes, threads, code).each do |index, kind, path|
          entry = by_index[index]
          case kind
          when :unsafe
            warn "WARNING: skipped extracting '#{entry.name}' to '#{path}' as unsafe."
          when :oversize
            warn "WARNING: #{EntrySizeError.new(entry).message}"
          end
        end
        batch.each { |spec| report.call(spec[0]) }
      end

      slow
    end

    NATIVE_EXTRACT_BATCH = 256 # :nodoc:

    def native_extractable?(entry, native)
      return false unless entry.instance_of?(::Ziperu::Entry) && entry.index && entry.backed_by?(native)
      # An encrypted entry goes through the Ruby path, which has the password.
      return false if entry.encrypted?
      return false unless entry.file? || entry.directory?

      name = entry.name
      name.ascii_only? || (name.encoding == ::Encoding::UTF_8 && name.valid_encoding?)
    end

    # What `Entry#extract` would do for the entry, as plain values:
    # [entry, index, name, mtime seconds, mtime nanoseconds, unix mode, directory?].
    def native_extract_spec(entry, target = entry.name)
      mtime = entry.time if @restore_times
      mode = entry.unix_perms & 0o1777 if @restore_permissions && entry.fstype == FSTYPE_UNIX && entry.unix_perms
      [entry, entry.index, target, mtime&.to_i, mtime&.nsec, mode, entry.directory?]
    end

    def add_recursive_dir(entry_prefix, src_dir, depth, max_depth, continue_on_exists_proc, report)
      ::Dir.children(src_dir).sort.each do |child|
        src_path = ::File.join(src_dir, child)

        if ::File.symlink?(src_path)
          warn "WARNING: skipped symlink '#{src_path}' while adding directory contents."
        elsif ::File.directory?(src_path)
          entry_name = "#{entry_prefix}#{child}/"
          report.call(add(entry_name, src_path, &continue_on_exists_proc))

          if depth < max_depth
            add_recursive_dir(entry_name, src_path, depth + 1, max_depth, continue_on_exists_proc, report)
          else
            warn "WARNING: max_depth (#{max_depth}) reached, not descending into '#{src_path}'."
          end
        elsif ::File.file?(src_path)
          report.call(add("#{entry_prefix}#{child}", src_path, &continue_on_exists_proc))
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
      @io = (path_or_io if buffer)
      @cdir = ::Ziperu::EntrySet.new
      @comment = ''
      @dirty = false
      @comment_changed = false

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
      IOExtras.binmode(path_or_io)
      @native = InputStream.open_archive(path_or_io)
      @comment = @native.comment # the stored bytes, as rubyzip reads them
      @native.each_entry { |meta| @cdir.push_record(Entry.from_meta(@native, meta, self)) }
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
      begin
        ::File.rename(tmp_filename, name)
      rescue Errno::EACCES
        # Something else (another Ziperu::File, say) still has the archive
        # open. Renaming an open file is allowed where replacing one is
        # not, so move the old archive aside first; that handle keeps
        # reading the old bytes, as it would on Unix.
        aside = "#{name}.#{Process.pid}.#{rand(1 << 32).to_s(36)}.old"
        ::File.rename(name, aside)
        ::File.rename(tmp_filename, name)
        begin
          ::File.delete(aside)
        rescue SystemCallError
          warn "WARNING: could not remove '#{aside}' (still open elsewhere); delete it once it is closed."
        end
      end
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
