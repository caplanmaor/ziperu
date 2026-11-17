# frozen_string_literal: true

module Ziperu
  # Reading and extracting tar archives: plain, or compressed with gzip,
  # zstd, xz or bzip2. Which it is comes from the archive's first bytes,
  # not its name.
  #
  #   Ziperu::Tar.extract_all('release.tar.gz', 'out')
  #
  #   Ziperu::Tar.foreach('logs.tar.zst') do |entry|
  #     puts "#{entry.name} (#{entry.size} bytes)"
  #     process(entry.read) if entry.file?
  #   end
  #
  # A tar archive has no index: it is read from front to back, one entry
  # at a time, in constant memory. That is also why it can be read from a
  # pipe, a socket or a response body, anything with `read`.
  #
  # The limit settings apply as they do to a zip (`max_entries`,
  # `max_entry_size`, `max_total_size`, `max_compression_ratio`, and
  # `max_archive_size` for what is read from an IO), as keywords or as
  # the `Ziperu.*` globals:
  #
  #   Ziperu::Tar.foreach(upload, **Ziperu::Limits::UPLOAD) { |entry| ... }
  #
  # Sparse files and multi-volume archives are not read (Ziperu::Error).
  # Not in rubyzip.
  module Tar
    # Yields each entry of the archive at `path_or_io` (a path, or an IO
    # with `read`) in turn. An entry's data can be read only inside the
    # block, before the next entry is reached. Without a block, returns
    # an Enumerator.
    def self.foreach(path_or_io, **options, &block)
      return enum_for(:foreach, path_or_io, **options) unless block

      Reader.open(path_or_io, **options) { |reader| reader.each(&block) }
      nil
    end

    # One pass over a tar archive.
    #
    #   Ziperu::Tar::Reader.open(io) do |tar|
    #     tar.compression                # :none, :gzip, :zstd, :xz or :bzip2
    #     while (entry = tar.next_entry)
    #       ...
    #     end
    #   end
    class Reader
      include Enumerable

      # How much `Entry#read` asks for at a time when reading to the end.
      CHUNK = 1 << 20 # :nodoc:

      # With a block, yields the reader and closes it afterwards.
      def self.open(path_or_io, **options)
        reader = new(path_or_io, **options)
        return reader unless block_given?

        begin
          yield reader
        ensure
          reader.close
        end
      end

      # `path_or_io` is a path (a String or anything with `to_path`) or an
      # IO-like object with `read(length)`; it is read forward only, and
      # is not closed. The keywords are the limit settings.
      def initialize(path_or_io, **options)
        @settings = Settings.take!(options)
        raise ArgumentError, "unknown keyword: #{options.keys.map(&:inspect).join(', ')}" unless options.empty?

        ratio = @settings.max_compression_ratio&.to_f
        # A Pathname has a `read` of its own, which is not an IO's.
        @native =
          if !path_or_io.kind_of?(Pathname) && path_or_io.respond_to?(:read)
            Native::TarReader.open_io(path_or_io, ratio, @settings.max_archive_size)
          else
            Native::TarReader.open_path(::File.path(path_or_io), ratio, nil)
          end
        @count = 0
        @total = 0
        @current = nil
      end

      # How the archive is compressed: `:none`, `:gzip`, `:zstd`, `:xz` or
      # `:bzip2`.
      def compression
        @native.compression
      end

      # The next entry, or nil at the end of the archive. What was left
      # unread of the entry before it is skipped.
      def next_entry
        @current = nil
        fields = @native.next_entry or return nil

        @count += 1
        @total += fields[:size]
        check_limits(fields[:size])
        @current = Entry.new(self, fields)
      end

      # Yields each remaining entry.
      def each
        return enum_for(:each) unless block_given?

        while (entry = next_entry)
          yield entry
        end
        self
      end

      # What the extraction drives. :nodoc:
      attr_reader :native, :settings

      def close
        @current = nil
        @native.close
        nil
      end

      # Up to `length` bytes of `entry`'s data, or nil at its end.
      def read_from(entry, length) # :nodoc:
        raise IOError, "entry '#{entry.name}' can no longer be read: the archive has moved past it" \
          unless entry.equal?(@current)

        @native.read(length)
      end

      private

      def check_limits(size)
        if (limit = @settings.max_entries) && @count > limit
          raise LimitError.new('an entry count', @count, limit)
        end
        if (limit = @settings.max_entry_size) && size > limit
          raise LimitError.new('an entry with a declared size', size, limit)
        end
        return unless (limit = @settings.max_total_size) && @total > limit

        raise LimitError.new('a declared total size', @total, limit)
      end
    end

    # One entry of a tar archive: what its header says, and its data while
    # the reader stands at it.
    class Entry
      # The entry's name as the archive has it: UTF-8 when it is valid
      # UTF-8, binary otherwise. Not checked or cleaned: it may be
      # absolute or hold `..`.
      attr_reader :name

      # Bytes of data; zero for anything but a file.
      attr_reader :size

      # `:file`, `:directory`, `:symlink`, `:hardlink`,
      # `:character_device`, `:block_device`, `:fifo` or `:other`.
      attr_reader :type

      # Permission bits (the low twelve of the mode field).
      attr_reader :mode

      # Where a symlink or hardlink points, as the archive has it; nil for
      # anything else.
      attr_reader :link_target

      # Owner and group as recorded. Never applied by ziperu.
      attr_reader :uid, :gid, :uname, :gname

      def initialize(reader, fields) # :nodoc:
        @reader = reader
        @name = text(fields[:name])
        @size = fields[:size]
        @type = fields[:type]
        @mode = fields[:mode]
        @mtime_sec = fields[:mtime_sec]
        @mtime_nsec = fields[:mtime_nsec]
        @link_target = %i[symlink hardlink].include?(@type) ? text(fields[:linkname]) : nil
        @uid = fields[:uid]
        @gid = fields[:gid]
        @uname = text(fields[:uname])
        @gname = text(fields[:gname])
        @pos = 0
      end

      # The modification time, to the nanosecond where the archive has it.
      def mtime
        ::Time.at(@mtime_sec, @mtime_nsec, :nsec)
      end

      def file?
        @type == :file
      end

      def directory?
        @type == :directory
      end

      def symlink?
        @type == :symlink
      end

      def hardlink?
        @type == :hardlink
      end

      # As IO#read: with no `length`, the rest of the data (an empty String
      # at the end); with one, up to that many bytes, or nil at the end.
      # Always binary.
      def read(length = nil)
        return read_rest if length.nil?
        raise ArgumentError, "negative length #{length} given" if length.negative?
        return +'' if length.zero?

        chunk = @reader.read_from(self, length)
        @pos += chunk.bytesize if chunk
        chunk
      end

      # Yields the rest of the data in pieces of at most `size` bytes.
      def each_chunk(size = Reader::CHUNK)
        return enum_for(:each_chunk, size) unless block_given?

        while (chunk = read(size))
          yield chunk
        end
        self
      end

      # Bytes of the data read so far.
      attr_reader :pos

      def eof?
        @pos >= @size
      end

      def inspect
        "#<#{self.class.name} #{@name.inspect} #{@type} size=#{@size}>"
      end

      private

      def read_rest
        out = +''.b
        while (chunk = @reader.read_from(self, Reader::CHUNK))
          @pos += chunk.bytesize
          out << chunk
        end
        out
      end

      # A name from a header: bytes, which are UTF-8 if they can be.
      def text(bytes)
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : bytes
      end
    end
  end
end

require_relative 'tar/extraction'
