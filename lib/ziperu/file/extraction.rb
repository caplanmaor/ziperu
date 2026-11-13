# frozen_string_literal: true

module Ziperu
  # Extraction: `extract`, `extract_all`, and the native fast path that
  # `extract_all` hands most entries to.
  class File
    # Entries handed to the native extractor per call, so an interrupt is
    # noticed between calls rather than after the whole archive.
    NATIVE_EXTRACT_BATCH = 256
    private_constant :NATIVE_EXTRACT_BATCH

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
      targets = ExtractionPlan.new(@cdir.writable_entries, exclude: exclude, junk_paths: junk_paths,
                                                            sanitize: sanitize).targets
      report = progress_reporter(progress, targets.size)

      # With no block to consult about paths already taken (the policy
      # says, or Ziperu.on_exists_proc), the native core extracts every
      # qualifying entry in one call; the rest take the per-entry path.
      policy = on_exists || (@settings.on_exists_proc ? :overwrite : :raise)
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

    # Which entries an `extract_all` writes, in what order, and to which
    # name under the destination: decided from the archive and the options
    # alone, before anything touches the disk.
    class ExtractionPlan # :nodoc:
      # `entries` are the archive's writable entries (of several records
      # under one name only the last, the one rubyzip would know).
      def initialize(entries, exclude: nil, junk_paths: false, sanitize: nil)
        unless [nil, false, :windows].include?(sanitize)
          raise ArgumentError, "sanitize: takes :windows, not #{sanitize.inspect}"
        end

        @entries = entries
        @exclude = exclude
        @junk_paths = junk_paths
        @sanitize = sanitize
      end

      # `[entry, target]` pairs. Directories first, so files have
      # somewhere to go; links last, so nothing is written through one.
      def targets
        dirs, rest = @entries.partition(&:directory?)
        links, others = rest.partition(&:symlink?)
        ordered = dirs + others + links
        ordered = ordered.reject { |e| excluded?(e.name) } if @exclude
        ordered = ordered.reject(&:directory?) if @junk_paths
        ordered.map { |e| [e, target_for(e.name)] }
      end

      private

      # Whether `name` matches one of the `exclude:` patterns: a glob
      # (`File.fnmatch` with `*` crossing `/`, as `unzip -x` has it) or a
      # Regexp.
      def excluded?(name)
        Array(@exclude).any? do |pattern|
          case pattern
          when ::Regexp then pattern.match?(name)
          else ::File.fnmatch?(pattern.to_s, name, ::File::FNM_EXTGLOB | ::File::FNM_DOTMATCH)
          end
        end
      end

      # The path under the destination an entry goes to.
      def target_for(name)
        name = ::File.basename(name) if @junk_paths
        @sanitize == :windows ? ::Ziperu::File.sanitize_windows_name(name) : name
      end
    end

    WINDOWS_RESERVED_NAMES = /\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\z)/i # :nodoc:

    # `name` as Windows will take it: in each component the characters it
    # refuses (`<>:"|?*` and controls) become `_`, a trailing dot or space
    # goes, and a reserved device name gets a leading `_`.
    # Not in rubyzip.
    def self.sanitize_windows_name(name)
      trailing = name.end_with?('/') ? '/' : ''
      parts = name.split('/').map do |part|
        part = part.gsub(/[<>:"|?*\x00-\x1f]/, '_').sub(/[. ]+\z/, '')
        part = "_#{part}" if part.match?(WINDOWS_RESERVED_NAMES)
        part.empty? ? '_' : part
      end
      parts.join('/') + trailing
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
        if native_extractable?(entry, native)
          specs << native_extract_spec(entry, target)
          by_index[entry.index] = entry
        else
          slow << [entry, target]
        end
      end

      specs.each_slice(NATIVE_EXTRACT_BATCH) do |batch|
        native.extract_entries(dest, batch, @settings.validate_entry_sizes, threads, code).each do |index, kind, path|
          entry = by_index[index]
          case kind
          when :unsafe
            warn "WARNING: skipped extracting '#{entry.name}' to '#{path}' as unsafe."
          when :link
            warn "WARNING: skipped extracting '#{entry.name}' through the link '#{path}'."
          when :oversize
            warn "WARNING: #{EntrySizeError.new(entry).message}"
          end
        end
        batch.each { |spec| report.call(spec[0]) }
      end

      slow
    end

    def native_extractable?(entry, native)
      return false unless entry.instance_of?(::Ziperu::Entry) && entry.index && entry.backed_by?(native)
      # An encrypted entry goes through the Ruby path, which has the password.
      return false if entry.encrypted?
      return false unless entry.file? || entry.directory?

      IOExtras.native_text?(entry.name)
    end

    # What `Entry#extract` would do for the entry, as plain values:
    # [entry, index, name, mtime seconds, mtime nanoseconds, unix mode, directory?].
    def native_extract_spec(entry, target)
      mtime = entry.time if @restore_times
      if @restore_permissions && entry.fstype == FSTYPE_UNIX && entry.unix_perms
        mode = entry.unix_perms & Entry::SAFE_PERMISSION_BITS
      end
      [entry, entry.index, target, mtime&.to_i, mtime&.nsec, mode, entry.directory?]
    end
  end
end
