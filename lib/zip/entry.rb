# frozen_string_literal: true

module Zip
  # Metadata for one entry. A plain Ruby object built from the Hash the
  # native core returns; the archive is only consulted (by index) for bytes.
  class Entry
    attr_reader :name, :size, :compressed_size, :crc, :compression_method,
                :comment, :extra, :header_offset, :data_offset, :unix_mode,
                :index

    # @api private
    def initialize(archive, meta)
      @archive = archive
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
    alias local_header_offset header_offset

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

    # Always false: sizes come from the central directory, so an entry is
    # never missing the metadata needed to read it.
    def incomplete?
      false
    end

    def time
      @time ||= DOSTime.parse_binary_dos_format(@dos_date, @dos_time)
    end
    alias mtime time

    def ftype
      directory? ? :directory : :file
    end

    # An IO-like stream over the entry's decompressed contents. Yields it and
    # closes it afterwards when given a block.
    def get_input_stream(decrypter: nil, &block)
      if directory?
        yield ::Zip::NullInputStream if block
        return ::Zip::NullInputStream
      end

      zis = ::Zip::InputStream.new(@archive, offset: @header_offset, decrypter: decrypter)
      zis.get_next_entry
      return zis unless block

      begin
        yield zis
      ensure
        zis.close
      end
    end

    # Decompressed contents as a binary String.
    def get_raw_input_string
      return ''.b if directory?

      @archive.read_entry(@index)
    rescue Native::SizeLimitError
      raise EntrySizeError, self
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
