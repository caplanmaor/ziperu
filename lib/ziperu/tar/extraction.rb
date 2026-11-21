# frozen_string_literal: true

module Ziperu # rubocop:disable Style/Documentation -- documented in ziperu.rb
  module Tar # rubocop:disable Style/Documentation -- documented in tar.rb
    # Extracts every entry of the tar archive at `path_or_io` (a path, or
    # an IO with `read`, which may be a pipe) into `destination_directory`:
    #
    #   Ziperu::Tar.extract_all(upload, 'out', **Ziperu::Limits::UPLOAD)
    #   Ziperu::Tar.extract_all('release.tar.gz', 'src', strip_components: 1)
    #
    # The rules are the ones a zip is extracted by. An entry whose name
    # resolves outside the destination is skipped with a warning, and
    # nothing is written through a link already on disk. Times and
    # permission bits are restored (never setuid or setgid); owners are
    # not.
    #
    # - `symlinks:` is `:skip` (the default, with a warning per link) or
    #   `:create`, which creates the links whose target stays inside the
    #   destination.
    # - A hard link is created when its target is a file this extraction
    #   wrote; any other is skipped with a warning.
    # - Devices and fifos are skipped with a warning.
    # - `on_exists:` is `:raise` (the default), `:overwrite` or `:skip`
    #   for a path taken before the extraction began. Within one archive
    #   the last entry of a name wins, as `tar` has it.
    # - `exclude:` lists globs or Regexps of entry names to leave out.
    # - `strip_components: n` drops the first `n` directories of every
    #   name (`tar --strip-components`); entries with no more than that
    #   are left out.
    # - `sanitize: :windows` rewrites names Windows refuses.
    # - `progress:` is called with `(entry, done, nil)` after each entry;
    #   a tar archive does not say how many it holds.
    #
    # The other keywords are the limit settings, as for `foreach`.
    # Links are created last, after every file. Not in rubyzip.
    def self.extract_all(path_or_io, destination_directory = '.', symlinks: :skip, on_exists: nil, exclude: nil,
                         sanitize: nil, strip_components: 0, progress: nil, **limits)
      Reader.open(path_or_io, **limits) do |reader|
        Extraction.new(reader, destination_directory, symlinks: symlinks, on_exists: on_exists, exclude: exclude,
                                                      sanitize: sanitize, strip_components: strip_components,
                                                      progress: progress).run
      end
      nil
    end

    # The first bytes of gzip, zstd and xz data.
    COMPRESSED_MAGIC = ["\x1f\x8b".b, "\x28\xb5\x2f\xfd".b, "\xfd7zXZ\x00".b].freeze # :nodoc:
    BZIP2_MAGIC = /\ABZh[1-9](?:1AY&SY|\x17\x72\x45\x38\x50\x90)/n # :nodoc:

    # Whether `head`, the first 512 bytes of some input, begins a tar
    # archive: compressed data (which a zip never starts with), a tar
    # header whose checksum holds, or the zeros an empty archive is.
    def self.head?(head) # :nodoc:
      return true if COMPRESSED_MAGIC.any? { |magic| head.start_with?(magic) } || head.match?(BZIP2_MAGIC)
      return false unless head.bytesize == 512
      return true if head.count("\0") == 512

      stored = head[148, 8][/[0-7]+/]&.to_i(8) or return false
      bytes = head.bytes
      bytes[148, 8] = [32] * 8
      stored == bytes.sum || stored == bytes.sum { |byte| byte > 127 ? byte - 256 : byte }
    end

    # One run of `Tar.extract_all`.
    class Extraction # :nodoc:
      include LinkSafety

      SKIPPED_TYPES = {
        character_device: 'a character device',
        block_device:     'a block device',
        fifo:             'a fifo'
      }.freeze

      def initialize(reader, destination_directory, symlinks:, on_exists:, exclude:, sanitize:, strip_components:,
                     progress:)
        raise ArgumentError, "symlinks: takes :skip or :create, not #{symlinks.inspect}" \
          unless %i[skip create].include?(symlinks)
        raise ArgumentError, "sanitize: takes :windows, not #{sanitize.inspect}" \
          unless [nil, false, :windows].include?(sanitize)
        raise ArgumentError, "strip_components: takes a count, not #{strip_components.inspect}" \
          unless strip_components.kind_of?(::Integer) && strip_components >= 0

        @reader = reader
        @native = reader.native
        @dest = ::File.absolute_path(destination_directory || '.')
        @policy = on_exists || (reader.settings.on_exists_proc ? :overwrite : :raise)
        @code = ::Ziperu::Entry.on_exists_code(@policy)
        @symlinks = symlinks
        @exclude = exclude
        @sanitize = sanitize
        @strip = strip_components
        @progress = progress
        # The files this run wrote, by path: one of them may be replaced
        # by a later entry of the same name, or be a hard link's target.
        @written = {}
        # The links to create once the files are in, by path, so that a
        # later entry of the same name takes a link's place.
        @links = {}
      end

      def run
        @native.extract_begin(@dest, @code)
        done = 0
        finished = false
        begin
          @reader.each do |entry|
            extract(entry)
            done += 1
            @progress&.call(entry, done, nil)
          end
          create_links
          finished = true
        ensure
          # The directories get their times and modes whatever happened,
          # as far as that goes; a failure here matters only when nothing
          # failed before it.
          begin
            @native.extract_finish
          rescue StandardError
            raise if finished
          end
        end
      end

      private

      def extract(entry)
        unless IOExtras.native_text?(entry.name)
          warn "WARNING: skipped '#{entry.name.inspect[1..-2]}': its name is not valid UTF-8."
          return
        end
        return if @exclude && ::Ziperu::File::ExtractionPlan.excluded?(@exclude, entry.name)

        name = target_for(entry.name) or return
        case entry.type
        when :file, :other then place(entry, name, false)
        when :directory then place(entry, name, true)
        when :hardlink then defer(entry, name)
        when :symlink
          if @symlinks == :create
            defer(entry, name)
          else
            warn "WARNING: skipped symlink '#{entry.name}' during extract_all."
          end
        else
          warn "WARNING: skipped '#{entry.name}': #{SKIPPED_TYPES.fetch(entry.type)} is not extracted."
        end
      end

      # The path under the destination a name in the archive goes to, or
      # nil when nothing is left of it: the archive's own root (`./`), or
      # a name `strip_components:` uses up.
      def target_for(name)
        parts = name.split('/').reject { |part| part.empty? || part == '.' }
        return nil if parts.size <= @strip

        name = parts.drop(@strip).join('/')
        @sanitize == :windows ? ::Ziperu::File.sanitize_windows_name(name) : name
      end

      def path_of(name)
        ::File.absolute_path(::File.join(@dest, name))
      end

      # What a path is known by: Windows takes names in any case.
      def key_of(path)
        ::Ziperu::RUNNING_ON_WINDOWS ? path.downcase : path
      end

      def inside?(path)
        path.start_with?(@dest + ::File::SEPARATOR) || @dest == ::File::SEPARATOR
      end

      def place(entry, name, directory)
        key = key_of(path_of(name))
        mtime = entry.mtime
        mode = entry.mode & ::Ziperu::Entry::SAFE_PERMISSION_BITS
        outcome = @native.extract_entry([name, mtime.to_i, mtime.nsec, mode, directory, @written.key?(key)])
        case outcome
        when ::Array
          warn_left_out(entry, *outcome)
        when ::Integer
          @written[key] = true
          @links.delete(key)
        else
          # A directory stands there now, or the entry was left out.
          if directory
            @links.delete(key)
            @written.delete(key)
          end
        end
      end

      def warn_left_out(entry, kind, path)
        if kind == :unsafe
          warn "WARNING: skipped extracting '#{entry.name}' to '#{path}' as unsafe."
        else
          warn "WARNING: skipped extracting '#{entry.name}' through the link '#{path}'."
        end
      end

      def defer(entry, name)
        path = path_of(name)
        key = key_of(path)
        @links.delete(key)
        @links[key] = [entry, path]
      end

      # Hard links first, so that none is made through a symlink of this
      # archive's.
      def create_links
        hard, soft = @links.partition { |_, (entry, _)| entry.hardlink? }
        hard.each { |key, (entry, path)| create_hardlink(entry, path, key) }
        soft.each { |key, (entry, path)| create_symlink(entry, path, key) }
      end

      def create_symlink(entry, path, key)
        return if kept?(path, key)
        return unless link_site?(entry, path)

        target = entry.link_target
        if (why = symlink_refusal(target, path, @dest))
          warn "WARNING: skipped symlink '#{entry.name}' to '#{target}' as #{why}."
          return
        end
        return unless clear_way(path, key)

        ::File.symlink(target, path)
      rescue NotImplementedError, Errno::EACCES, Errno::EPERM => e
        warn "WARNING: could not create symlink '#{path}': #{e.message}"
      end

      def create_hardlink(entry, path, key)
        return if kept?(path, key)

        target_name = target_for(entry.link_target)
        target = target_name && path_of(target_name)
        unless target && @written.key?(key_of(target)) && real_file?(target)
          warn "WARNING: skipped hard link '#{entry.name}' to '#{entry.link_target}': " \
               'its target is not a file this extraction wrote.'
          return
        end
        return if key_of(target) == key
        return unless link_site?(entry, path) && clear_way(path, key)

        ::File.link(target, path)
        @written[key] = true
      rescue NotImplementedError, Errno::EACCES, Errno::EPERM, Errno::EXDEV, Errno::EMLINK => e
        warn "WARNING: could not create hard link '#{path}': #{e.message}"
      end

      # Whether `on_exists: :skip` leaves what is at `path` alone: there
      # is then nothing to say about the link that would have gone there.
      def kept?(path, key)
        @policy == :skip && !@written.key?(key) && inside?(path) &&
          (::File.symlink?(path) || ::File.exist?(path))
      end

      def real_file?(path)
        !link_on_the_way(@dest, path) && ::File.lstat(path).file?
      rescue SystemCallError
        false
      end

      # Whether a link may stand at `path`: inside the destination, with
      # no link on disk on the way there.
      def link_site?(entry, path)
        unless inside?(path) && !IOExtras.windows_stream_name?(path.delete_prefix(@dest))
          warn_left_out(entry, :unsafe, path)
          return false
        end
        if (link = link_on_the_way(@dest, path, leaf: false))
          warn_left_out(entry, :link, link)
          return false
        end
        true
      end

      # Makes the directories down to `path` and removes what stands
      # there, if the policy allows; false when the link is to be left out.
      def clear_way(path, key)
        ::FileUtils.mkdir_p(::File.dirname(path))
        return true unless ::File.symlink?(path) || ::File.exist?(path)

        unless @written.key?(key)
          return false if @policy == :skip
          raise DestinationExistsError, path if @policy == :raise
        end
        raise DestinationExistsError, path if ::File.directory?(path) && !::File.symlink?(path)

        ::File.unlink(path)
        @written.delete(key)
        true
      end
    end
  end

  # Extracts the archive at `path_or_io` into `destination_directory`,
  # whichever kind it is: a zip, or a tar archive (plain, or compressed
  # with gzip, zstd, xz or bzip2). Which is told from its first bytes.
  #
  #   Ziperu.extract(upload, 'out', **Ziperu::Limits::UPLOAD)
  #
  # The keywords are those of `Ziperu::File.extract_all` for a zip and of
  # `Ziperu::Tar.extract_all` for a tar archive. `symlinks:`, `on_exists:`,
  # `exclude:`, `sanitize:`, `progress:` and the limits are common to both;
  # one that the archive's kind does not take is an ArgumentError.
  #
  # A zip has to be sought in, so one that comes from a pipe or socket is
  # read into memory first (`max_archive_size:` bounds that); a tar
  # archive never is.
  # Not in rubyzip.
  def self.extract(path_or_io, destination_directory = '.', **options)
    input, head = Tar::Sniffed.of(path_or_io)
    if Tar.head?(head)
      Tar.extract_all(input, destination_directory, **options)
    elsif IOExtras.path_like?(input)
      ::Ziperu::File.extract_all(input, destination_directory, **options)
    else
      how, open_options = options.partition { |name, _| ::Ziperu::File::EXTRACT_ALL_OPTIONS.include?(name) }.map(&:to_h)
      input = input.whole(Settings.take!(open_options.dup).max_archive_size) if input.kind_of?(Tar::Sniffed::Replay)
      ::Ziperu::File.open_buffer(input, write: false, **open_options) do |zip|
        zip.extract_all(destination_directory, **how)
      end
    end
    nil
  end

  module Tar
    # The first block of an input, and the input to read it all from
    # afterwards.
    module Sniffed # :nodoc:
      HEAD = 512

      # `[input, head]`: for a path or an IO that can seek, the input as
      # it was; for one that cannot, a reader that gives the head again
      # before the rest.
      def self.of(path_or_io)
        if path_or_io.kind_of?(::Pathname) || !path_or_io.respond_to?(:read)
          [path_or_io, ::File.binread(::File.path(path_or_io), HEAD) || ''.b]
        elsif IOExtras.seekable?(path_or_io)
          start = path_or_io.tell
          head = path_or_io.read(HEAD) || ''.b
          path_or_io.seek(start)
          [path_or_io, head.b]
        else
          head = read_head(path_or_io)
          [Replay.new(head, path_or_io), head]
        end
      end

      def self.read_head(io)
        head = ''.b
        while head.bytesize < HEAD
          chunk = io.read(HEAD - head.bytesize) or break
          break if chunk.empty?

          head << chunk
        end
        head
      end

      # Reads `head`, then what `io` has left.
      class Replay # :nodoc:
        def initialize(head, io)
          @head = head.dup
          @io = io
        end

        def read(length = nil, buffer = nil)
          chunk =
            if @head.empty?
              @io.read(length)
            elsif length.nil?
              head = @head
              @head = ''.b
              head + (@io.read || '')
            else
              @head.slice!(0, length)
            end
          return chunk if buffer.nil? || chunk.nil?

          buffer.replace(chunk)
        end

        # Everything, in memory, as long as it is no more than `limit`
        # bytes (nil for any amount).
        def whole(limit)
          data = ''.b
          while (chunk = read(1 << 20)) && !chunk.empty?
            data << chunk
            raise LimitError.new('an archive size', data.bytesize, limit) if limit && data.bytesize > limit
          end
          ::StringIO.new(data)
        end
      end
    end
  end
end
