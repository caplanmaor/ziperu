# frozen_string_literal: true

module Ziperu
  class OutputStream # rubocop:disable Style/Documentation -- documented in output_stream.rb
    # Works out, to the byte, how large an archive will be when streamed
    # (`OutputStream.body`, `write_buffer` to a pipe or socket), from the
    # names and sizes of its entries, so a download can carry a
    # `Content-Length` before a byte of it exists:
    #
    #   size = Ziperu::OutputStream.estimated_size do |e|
    #     e.add_stored("report.csv", csv.bytesize)
    #     e.add_deflated("big.bin", compressed_size: 12_345, size: 99_999)
    #     e.add_directory("logs/")
    #   end
    #
    # The archive must then be written the same way: each file through
    # `put_next_entry(Entry.new(name, size: n, compression_method: STORED))`
    # (or DEFLATED, with a compressed size known from an earlier run); an
    # entry given without its size is written zip64-ready, 28 bytes more
    # than estimated, so the size must be set. The names in the same
    # encoding, no extra fields beyond the default extended timestamp, and
    # no comments. Pass the stream's settings to `estimated_size` as
    # keywords, as to `body` (`write_extended_timestamps: true`), so the
    # estimate sees the same ones. It mirrors what the native writer emits
    # for a stream: a data descriptor after every file's data, zip64
    # records only for a 4 GiB entry or 65,535 entries.
    class SizeEstimator
      LOCAL_HEADER = LOCAL_ENTRY_STATIC_HEADER_LENGTH
      CENTRAL_HEADER = CDIR_ENTRY_STATIC_HEADER_LENGTH
      END_OF_CENTRAL_DIRECTORY = 22
      ZIP64_END_OF_CENTRAL_DIRECTORY = 56 + 20 # the record and its locator
      ZIP64_THRESHOLD = ZIP64_SIZE_LIMIT
      ZIP64_ENTRY_THRESHOLD = 0xFFFF
      # After a file's data: signature, CRC and two sizes, 32-bit or 64-bit.
      DATA_DESCRIPTOR = 16
      ZIP64_DATA_DESCRIPTOR = 24
      # Every extra field starts with an ID and a length.
      EXTRA_FIELD_HEADER = 4
      # A local header's zip64 field: its header and two 8-byte sizes.
      ZIP64_LOCAL_EXTRA = EXTRA_FIELD_HEADER + 16
      # The extended timestamp field: its header, flags and the mtime.
      EXTENDED_TIMESTAMP = EXTRA_FIELD_HEADER + 1 + 4

      def initialize(settings = ::Ziperu)
        @settings = settings
        @entries = 0
        @data = 0 # local headers, data and descriptors
        @central = 0
        @comment = 0
      end

      # A file stored as is: `size` bytes.
      def add_stored(name, size)
        add_file(name, size, size)
      end

      # A file deflated (or otherwise compressed) to `compressed_size`.
      def add_deflated(name, compressed_size:, size:)
        add_file(name, size, compressed_size)
      end

      # A directory entry (`name` ends with `/`).
      def add_directory(name)
        fields = default_fields
        name = name.to_s.b
        @entries += 1
        @data += LOCAL_HEADER + name.bytesize + fields
        @central += CENTRAL_HEADER + name.bytesize + fields
        self
      end

      # The archive comment, if one will be set.
      def comment(text)
        @comment = text.to_s.bytesize
        self
      end

      # The archive's size in bytes.
      def size
        # `@data` is also where the central directory starts.
        zip64 = @entries > ZIP64_ENTRY_THRESHOLD || @data > ZIP64_THRESHOLD ||
                @central > ZIP64_THRESHOLD
        total = @data + @central + END_OF_CENTRAL_DIRECTORY + @comment
        total += ZIP64_END_OF_CENTRAL_DIRECTORY if zip64
        total
      end

      private

      def add_file(name, size, compressed_size)
        fields = default_fields
        name = name.to_s.b
        large = size >= ZIP64_THRESHOLD || compressed_size >= ZIP64_THRESHOLD
        offset_large = @data >= ZIP64_THRESHOLD
        @entries += 1
        # The local header, with a zip64 extra for a large entry; the data;
        # the descriptor.
        @data += LOCAL_HEADER + name.bytesize + fields + (large ? ZIP64_LOCAL_EXTRA : 0) +
                 compressed_size + (large ? ZIP64_DATA_DESCRIPTOR : DATA_DESCRIPTOR)
        # The central record: a zip64 extra holds the two 8-byte sizes for a
        # large entry and the 8-byte offset for one past 4 GiB.
        zip64_extra = 0
        zip64_extra += 16 if large
        zip64_extra += 8 if offset_large
        zip64_extra += EXTRA_FIELD_HEADER unless zip64_extra.zero?
        @central += CENTRAL_HEADER + name.bytesize + fields + zip64_extra
        self
      end

      # The size of the extra field the writer adds by default.
      def default_fields
        @settings.write_extended_timestamps ? EXTENDED_TIMESTAMP : 0
      end
    end

    class << self
      # The size an archive streamed with `body` or `write_buffer` will
      # come to; see SizeEstimator.
      # Not in rubyzip.
      def estimated_size(**settings)
        estimator = SizeEstimator.new(Settings.take!(settings))
        raise ArgumentError, "unknown keyword: #{settings.keys.map(&:inspect).join(', ')}" unless settings.empty?

        yield estimator
        estimator.size
      end
    end
  end
end
