# frozen_string_literal: true

module Zip
  # Metadata for one entry. A plain Ruby object built from the Hash the
  # native core returns; the archive is only consulted (by index) for bytes.
  class Entry
    attr_reader :name, :size, :compressed_size, :crc, :compression_method,
                :comment, :extra, :header_offset, :data_offset, :unix_mode,
                :index

    # @api private
    def initialize(zipfile, meta)
      @zipfile = zipfile
      @index = meta[:index]
      @name = meta[:name].force_encoding(Encoding::UTF_8)
      @size = meta[:size]
      @compressed_size = meta[:compressed_size]
      @crc = meta[:crc]
      @compression_method = meta[:compression_method]
      @directory = meta[:directory]
      @encrypted = meta[:encrypted]
      @unix_mode = meta[:unix_mode]
      @dos_date = meta[:dos_date]
      @dos_time = meta[:dos_time]
      @comment = meta[:comment].force_encoding(Encoding::UTF_8)
      @extra = meta[:extra]
      @header_offset = meta[:header_offset]
      @data_offset = meta[:data_offset]
    end

    alias to_s name

    def directory?
      @directory
    end
    alias is_directory directory?

    def file?
      !directory?
    end

    def encrypted?
      @encrypted
    end

    def time
      @time ||= DOSTime.parse_binary_dos_format(@dos_date, @dos_time)
    end
    alias mtime time

    def ftype
      directory? ? :directory : :file
    end

    def get_input_stream
      io = StringIO.new(get_raw_input_string)
      io.set_encoding(Encoding::BINARY)
      return io unless block_given?

      yield io
    end

    # Decompressed contents as a binary String.
    def get_raw_input_string
      @zipfile.send(:native).read_entry(@index)
    end

    def ==(other)
      other.is_a?(Entry) && name == other.name && size == other.size &&
        crc == other.crc && compression_method == other.compression_method
    end

    def <=>(other)
      to_s <=> other.to_s
    end

    def inspect
      "#<#{self.class.name}:#{name} size=#{size} crc=#{format("%08x", crc)}>"
    end
  end
end
