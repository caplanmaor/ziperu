# frozen_string_literal: true

module Ziperu
  class OutputStream
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
    # The archive must then be written the same way: stored entries with
    # `Entry.new(name, size: n, compression_method: STORED)` (or
    # `put_next_entry(name, nil, nil, STORED)` with the size set), deflated
    # ones with a compressed size known from an earlier run, the names in
    # the same encoding, no extra fields beyond the default extended
    # timestamp (`Ziperu.write_extended_timestamps`, read when the
    # estimate is made) and no comments. It mirrors what the native
    # writer emits for a stream: a data descriptor after every file's
    # data, zip64 records only for a 4 GiB entry or 65,535 entries.
    class SizeEstimator
      LOCAL_HEADER = 30
      CENTRAL_HEADER = 46
      END_OF_CENTRAL_DIRECTORY = 22
      ZIP64_END_OF_CENTRAL_DIRECTORY = 56 + 20 # the record and its locator
      ZIP64_THRESHOLD = 0xFFFFFFFF
      ZIP64_ENTRY_THRESHOLD = 0xFFFF

      def initialize
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
        fields = default_fields(name)
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
        central_start = @data
        zip64 = @entries > ZIP64_ENTRY_THRESHOLD || central_start > ZIP64_THRESHOLD ||
                @central > ZIP64_THRESHOLD
        total = @data + @central + END_OF_CENTRAL_DIRECTORY + @comment
        total += ZIP64_END_OF_CENTRAL_DIRECTORY if zip64
        total
      end

      private

      def add_file(name, size, compressed_size)
        fields = default_fields(name)
        name = name.to_s.b
        large = size >= ZIP64_THRESHOLD || compressed_size >= ZIP64_THRESHOLD
        offset_large = @data >= ZIP64_THRESHOLD
        @entries += 1
        # The local header, with a zip64 extra (two 8-byte sizes) for a
        # large entry; the data; the descriptor, 16 bytes or 24 with
        # 64-bit sizes.
        @data += LOCAL_HEADER + name.bytesize + fields + (large ? 20 : 0) + compressed_size + (large ? 24 : 16)
        # The central record: a zip64 extra holds the sizes for a large
        # entry and the offset for one past 4 GiB.
        zip64_extra = 0
        zip64_extra += 16 if large
        zip64_extra += 8 if offset_large
        zip64_extra += 4 unless zip64_extra.zero?
        @central += CENTRAL_HEADER + name.bytesize + fields + zip64_extra
        self
      end

      # The extra field the writer adds by default: the extended timestamp
      # (4 + 1 + 4 bytes).
      def default_fields(_name)
        ::Ziperu.write_extended_timestamps ? 9 : 0
      end
    end

    class << self
      # The size an archive streamed with `body` or `write_buffer` will
      # come to; see SizeEstimator.
      # Not in rubyzip.
      def estimated_size
        estimator = SizeEstimator.new
        yield estimator
        estimator.size
      end
    end
  end
end
