# frozen_string_literal: true

require 'securerandom'

module Ziperu
  module Tar # rubocop:disable Style/Documentation -- documented in tar.rb
    # Writes a tar archive at `path_or_io` (a path, or an IO with `write`,
    # which may be a pipe or a socket), yielding a Tar::Writer:
    #
    #   Ziperu::Tar.create('backup.tar.zst') do |tar|
    #     tar.add('report.pdf', 'tmp/report.pdf')        # a file from disk
    #     tar.add('upload.bin', io)                      # any IO
    #     tar.add_data('notes.txt', "written #{Time.now}\n")
    #     tar.add_recursive('public', prefix: 'site/')
    #   end
    #
    # `compression:` is `:none`, `:gzip`, `:zstd`, `:xz` or `:bzip2`. For a
    # path it defaults to what the name ends in (`.tar.gz` and `.tgz`,
    # `.tar.zst`, `.tar.xz`, `.tar.bz2` and their short forms), for an IO
    # to `:none`. `level:` is the codec's own (gzip and xz 0 to 9, zstd 1
    # to 22, bzip2 1 to 9).
    #
    # A path is written beside itself and renamed into place once the
    # block returns, so a failure leaves what was there. An IO is left
    # open. Returns `path_or_io`. Not in rubyzip.
    def self.create(path_or_io, **options)
      raise ArgumentError, 'a block that adds the entries is required' unless block_given?

      writer = Writer.new(path_or_io, **options)
      begin
        yield writer
      rescue Exception # rubocop:disable Lint/RescueException -- whatever it is, the half-written archive goes
        writer.abandon
        raise
      end
      writer.close
      path_or_io
    end

    # Archives what is under `src_dir` into a new tar archive at
    # `path_or_io`: `Ziperu::Tar.add_recursive('site.tar.gz', 'public')`.
    # Takes the options of `create` and of `Writer#add_recursive`.
    def self.add_recursive(path_or_io, src_dir, compression: nil, level: nil, **options)
      create(path_or_io, compression: compression, level: level) { |tar| tar.add_recursive(src_dir, **options) }
    end

    # A tar archive as a body to stream (Rack's `each`): the block adds the
    # entries, and the archive's bytes are yielded as they are made.
    #
    #   [200, { 'content-type' => 'application/gzip' },
    #    Ziperu::Tar.body(compression: :gzip) { |tar| tar.add_data('a.csv', csv) }]
    def self.body(**options, &block)
      raise ArgumentError, 'a block that adds the entries is required' unless block

      Enumerator.new { |yielder| create(::Ziperu::OutputStream::Yielder.new(yielder), **options, &block) }
    end

    # What `Tar.create` yields.
    #
    # Every entry's size goes ahead of its data, so it has to be known when
    # the entry starts: a file's is its size on disk, an IO's is what it
    # has left (`size - pos`), and an IO that cannot say is copied to a
    # temporary file first.
    #
    # Entries are written as given: owners are not recorded (uid and gid
    # 0, no names), times are whole seconds, and with
    # `Ziperu.source_date_epoch` set no time is later than it, so the same
    # input gives the same bytes.
    class Writer
      EXTENSIONS = {
        /\.(tar\.gz|tgz|taz)\z/i       => :gzip,
        /\.(tar\.zst|tzst)\z/i         => :zstd,
        /\.(tar\.xz|txz)\z/i           => :xz,
        /\.(tar\.bz2|tbz2|tbz|tb2)\z/i => :bzip2
      }.freeze
      private_constant :EXTENSIONS

      # The levels each codec takes.
      LEVELS = { none: nil, gzip: 0..9, zstd: 1..22, xz: 0..9, bzip2: 1..9 }.freeze # :nodoc:

      FILE = '0'.ord
      HARDLINK = '1'.ord
      SYMLINK = '2'.ord
      DIRECTORY = '5'.ord
      private_constant :FILE, :HARDLINK, :SYMLINK, :DIRECTORY

      CHUNK = 1 << 16
      PIECE = 1 << 20
      private_constant :CHUNK, :PIECE

      # See Tar.create. Without a block there, `close` ends the archive and
      # `abandon` throws it away.
      def initialize(path_or_io, compression: nil, level: nil, **options)
        @settings = Settings.take!(options)
        raise ArgumentError, "unknown keyword: #{options.keys.map(&:inspect).join(', ')}" unless options.empty?

        to_io = !path_or_io.kind_of?(::Pathname) && path_or_io.respond_to?(:write)
        @path = ::File.absolute_path(::File.path(path_or_io)) unless to_io
        @compression = compression || (@path ? compression_of(@path) : :none)
        check_compression(level)
        @native =
          if to_io
            Native::TarWriter.open_io(path_or_io, @compression.to_s, level)
          else
            @staging = staging_path
            Native::TarWriter.open_path(@staging, @compression.to_s, level)
          end
        @open = true
      end

      # `:none`, `:gzip`, `:zstd`, `:xz` or `:bzip2`.
      attr_reader :compression

      # Adds `source` under `name`: a path (a file, or a directory, which
      # is added alone, without what is in it) or an IO with `read`.
      # `mode:` and `mtime:` default to the file's own for a path, and to
      # 0644 and now for an IO.
      def add(name, source, mode: nil, mtime: nil)
        if !source.kind_of?(::Pathname) && source.respond_to?(:read)
          add_io(name, source, mode || 0o644, mtime)
        else
          add_path(name, ::File.path(source), mode, mtime)
        end
        self
      end

      # Adds a file named `name` holding `data`, a String.
      def add_data(name, data, mode: 0o644, mtime: nil)
        data = data.to_str
        entry(file_name(name), FILE, data.bytesize, mode, mtime)
        # In pieces: the native side copies what it is given.
        (0...data.bytesize).step(PIECE) { |at| @native.write(data.byteslice(at, PIECE)) }
        self
      end

      # Adds a directory entry.
      def mkdir(name, mode: 0o755, mtime: nil)
        entry("#{file_name(name)}/", DIRECTORY, 0, mode, mtime)
        self
      end

      # Adds a symbolic link named `name` that points at `target`.
      def symlink(name, target, mtime: nil)
        entry(file_name(name), SYMLINK, 0, 0o777, mtime, link: target.to_s)
        self
      end

      # Adds a hard link named `name` to `target`, the name of an entry
      # already in the archive.
      def link(name, target, mode: 0o644, mtime: nil)
        entry(file_name(name), HARDLINK, 0, mode, mtime, link: file_name(target))
        self
      end

      # Adds everything under `src_dir`, in name order, as `prefix` plus
      # its path below `src_dir`.
      #
      # `symlinks:` is `:skip` (the default, with a warning per link) or
      # `:store`, which records each link as a link; none is followed.
      # `exclude:` lists globs or Regexps of names in the archive to leave
      # out, a directory with what is under it. `progress:` is called with
      # `(name, done, nil)` after each entry. Anything that is not a file,
      # a directory or a link (a socket, a device) is skipped with a
      # warning, and so is the archive being written, if it is in there.
      def add_recursive(src_dir, prefix: '', symlinks: :skip, exclude: nil, progress: nil)
        raise ArgumentError, "symlinks: takes :skip or :store, not #{symlinks.inspect}" \
          unless %i[skip store].include?(symlinks)

        src_dir = ::File.path(src_dir)
        raise ArgumentError, "#{src_dir} is not a directory" unless ::File.directory?(src_dir)

        walk = Walk.new(self, symlinks, exclude, progress, [@path, @staging].compact)
        walk.directory(src_dir, prefix.to_s)
        self
      end

      # Ends the archive; for a path, puts it in place.
      def close
        return unless @open

        @open = false
        begin
          @native.close
        rescue Exception # rubocop:disable Lint/RescueException -- see Tar.create
          discard
          raise
        end
        put_in_place if @staging
        nil
      end

      # Stops without ending the archive. A path is left as it was before;
      # what an IO was already given stays given.
      def abandon
        return unless @open

        @open = false
        @native.abandon
        discard
        nil
      end

      def closed?
        !@open
      end

      private

      def discard
        ::File.unlink(@staging) if @staging && ::File.exist?(@staging)
      rescue SystemCallError
        nil
      end

      def put_in_place
        ::File.rename(@staging, @path)
      rescue SystemCallError
        discard
        raise
      end

      def compression_of(path)
        EXTENSIONS.each { |pattern, compression| return compression if path.match?(pattern) }
        :none
      end

      def check_compression(level)
        unless LEVELS.key?(@compression)
          raise ArgumentError,
                "compression: takes #{LEVELS.keys.map(&:inspect).join(', ')}, not #{@compression.inspect}"
        end
        return if level.nil?

        range = LEVELS[@compression] or raise ArgumentError, 'level: needs a compression to apply to'
        return if level.kind_of?(::Integer) && range.cover?(level)

        raise ArgumentError, "level: for #{@compression} is #{range.first} to #{range.last}, not #{level.inspect}"
      end

      # A name beside the archive's own, in the same directory so that the
      # rename at the end cannot cross a file system.
      def staging_path
        dir, base = ::File.split(@path)
        ::File.join(dir, ".#{base}.ziperu-#{::Process.pid}-#{::SecureRandom.hex(8)}")
      end

      # A name as the archive takes it: not empty, no NUL, and no slash at
      # the end (which is how a directory is told).
      def file_name(name)
        name = name.to_s
        raise ArgumentError, 'an entry needs a name' if name.empty? || name.delete('/').empty?
        raise ArgumentError, 'an entry name cannot hold a NUL' if name.include?("\0")

        name.end_with?('/') ? name.sub(%r{/+\z}, '') : name
      end

      # The seconds an entry is stamped with: no later than the
      # reproducible-build epoch, when there is one.
      def stamp(mtime)
        seconds = (mtime || ::Time.now).to_i
        epoch = @settings.source_date_epoch
        epoch && (mtime.nil? || seconds > epoch) ? epoch : seconds
      end

      def entry(name, type, size, mode, mtime, link: '')
        raise IOError, 'closed tar writer' unless @open
        raise ArgumentError, 'a link needs a target' if [SYMLINK, HARDLINK].include?(type) && link.empty?

        @native.entry(header(name, type, size, mode, mtime, link))
      end

      # What the native side takes for an entry.
      def header(name, type, size, mode, mtime, link = '')
        [name.b, link.b, type, size, Integer(mode) & 0o7777, stamp(mtime), 0, 0, '', '']
      end

      def add_path(name, path, mode, mtime)
        stat = ::File.stat(path)
        if stat.directory?
          mkdir(name, mode: mode || stat.mode, mtime: mtime || stat.mtime)
        elsif stat.file?
          add_file(file_name(name), path, stat, mode, mtime)
        else
          raise ArgumentError, "#{path} is not a file or a directory"
        end
      end

      public

      # A file of known size, read by the native side, which opens it
      # before it writes anything: one that cannot be read raises and the
      # archive goes on without it. :nodoc:
      def add_file(name, path, stat, mode = nil, mtime = nil)
        raise IOError, 'closed tar writer' unless @open

        given = @native.add_file(header(name, FILE, stat.size, mode || stat.mode, mtime || stat.mtime), path)
        return if given == stat.size

        warn "WARNING: '#{path}' shrank from #{stat.size} to #{given} bytes while it was read; " \
             "'#{name}' is made up with zeros."
      end

      private

      def add_io(name, io, mode, mtime)
        size = remaining_in(io)
        return spooled(io) { |file| add_io(name, file, mode, mtime) } if size.nil?

        entry(file_name(name), FILE, size, mode, mtime)
        left = size
        while left.positive?
          chunk = io.read([left, CHUNK].min)
          break if chunk.nil? || chunk.empty?

          @native.write(chunk)
          left -= chunk.bytesize
        end
      end

      # What `io` has left to read, when it can say.
      def remaining_in(io)
        return nil unless io.respond_to?(:size) && io.respond_to?(:pos)

        left = io.size - io.pos
        left.negative? ? nil : left
      rescue SystemCallError, IOError, NotImplementedError, TypeError
        nil
      end

      # Copies `io` to a temporary file, to learn how much it holds.
      def spooled(io)
        ::Tempfile.create('ziperu-tar') do |file|
          file.binmode
          # Not IO.copy_stream: that wants `read(length, buffer)`, which
          # a response body may not have.
          while (chunk = io.read(CHUNK)) && !chunk.empty?
            file.write(chunk)
          end
          file.rewind
          yield file
        end
      end

      # One `add_recursive`.
      class Walk # :nodoc:
        def initialize(writer, symlinks, exclude, progress, own)
          @writer = writer
          @symlinks = symlinks
          @exclude = exclude
          @progress = progress
          @own = own
          @done = 0
        end

        def directory(dir, prefix)
          ::Dir.children(dir).sort.each do |child|
            name = "#{prefix}#{child}"
            next if @exclude && ::Ziperu::File::ExtractionPlan.excluded?(@exclude, name)

            add(::File.join(dir, child), name)
          end
        end

        private

        def add(path, name)
          stat = ::File.lstat(path)
          if stat.symlink?
            return warn("WARNING: skipped symlink '#{path}'.") unless @symlinks == :store

            @writer.symlink(name, ::File.readlink(path), mtime: stat.mtime)
          elsif stat.directory?
            @writer.mkdir(name, mode: stat.mode, mtime: stat.mtime)
            report(name)
            return directory(path, "#{name}/")
          elsif stat.file?
            return if @own.include?(::File.absolute_path(path))

            @writer.add_file(name, path, stat)
          else
            return warn("WARNING: skipped '#{path}': not a file, a directory or a link.")
          end
          report(name)
        end

        def report(name)
          @done += 1
          @progress&.call(name, @done, nil)
        end
      end
    end
  end
end
