# frozen_string_literal: true

# The end-of-central-directory parsing is ported from rubyzip
# (Copyright (C) 2002-2026 the rubyzip authors).

module Ziperu
  # Reads just the end-of-central-directory records of an archive, in Ruby.
  #
  # The native core refuses archives whose EOCD declares more entries than
  # the central directory holds, so `Ziperu::File.open` raises on them
  # where rubyzip warns (or raises `EntryNumberMismatchError` when
  # `Ziperu.validate_declared_number_of_entries` is set). This gives
  # `Ziperu::File.count_entries` rubyzip's behaviour at least.
  class CentralDirectory # :nodoc:all
    END_OF_CD_SIG          = 0x06054b50
    ZIP64_END_OF_CD_SIG    = 0x06064b50
    ZIP64_EOCD_LOCATOR_SIG = 0x07064b50

    STATIC_EOCD_SIZE       = 22
    ZIP64_STATIC_EOCD_SIZE = 56
    ZIP64_EOCD_LOC_SIZE    = 20
    MAX_FILE_COMMENT_SIZE  = (1 << 16) - 1
    MAX_END_OF_CD_SIZE     =
      MAX_FILE_COMMENT_SIZE + STATIC_EOCD_SIZE + ZIP64_EOCD_LOC_SIZE

    include Enumerable

    attr_reader :size, :cdir_offset, :comment

    # rubyzip's way of listing an archive held in an IO without a
    # `Zip::File` (roo reads spreadsheets from a stream this way): the
    # entries are read, and each can be read or extracted afterwards.
    def read_from_stream(io)
      IOExtras.binmode(io)
      @native = InputStream.open_archive(io)
      @comment = @native.comment
      @entry_set = EntrySet.new
      @native.entries.each { |meta| @entry_set.push_record(Entry.from_meta(@native, meta)) }
      @size = @entry_set.size
      @cdir_offset = @native.central_directory_start if @native.respond_to?(:central_directory_start)
      self
    end

    def entries
      (@entry_set || EntrySet.new).entries
    end

    def each(&block)
      entries.each(&block)
    end

    # Number of entries declared by the EOCD of `path_or_io`.
    def self.count_entries(path_or_io)
      if path_or_io.respond_to?(:read)
        new.count_entries(path_or_io)
      else
        ::File.open(path_or_io.to_s, 'rb') { |io| new.count_entries(io) }
      end
    end

    def count_entries(io)
      if IOExtras.path_like?(io)
        return ::File.open(IOExtras.path_of(io), 'rb') { |f| count_entries(f) }
      end

      read_eocds(io)
      @size
    end

    private

    def unpack_64_e_o_c_d(buffer)
      _, # ZIP64_END_OF_CD_SIG. We know we have this at this point.
      _size_of_zip64_e_o_c_d,
      _version_made_by,
      _version_needed_for_extract,
      _number_of_this_disk,
      _number_of_disk_with_start_of_cdir,
      _total_number_of_entries_in_cdir_on_this_disk,
      @size,
      size_in_bytes,
      @cdir_offset = buffer.unpack('VQ<vvVVQ<Q<Q<Q<')

      validate_size!(@size, size_in_bytes)
    end

    def unpack_64_eocd_locator(buffer)
      _, _, zip64_eocd_offset, = buffer.unpack('VVQ<V')
      zip64_eocd_offset
    end

    # Returns true when the plain EOCD was complete (no zip64 needed).
    def unpack_e_o_c_d(buffer)
      _, # END_OF_CD_SIG. We know we have this at this point.
      number_of_this_disk,
      number_of_disk_with_start_of_cdir,
      total_number_of_entries_in_cdir_on_this_disk,
      @size,
      size_in_bytes,
      @cdir_offset,
      comment_length = buffer.unpack('VvvvvVVv')

      complete = !([number_of_this_disk, number_of_disk_with_start_of_cdir,
                    total_number_of_entries_in_cdir_on_this_disk, @size].any?(0xFFFF) ||
                    size_in_bytes == 0xFFFFFFFF || @cdir_offset == 0xFFFFFFFF)

      validate_size!(@size, size_in_bytes) if complete

      @comment = comment_length.positive? ? buffer.slice(STATIC_EOCD_SIZE, comment_length) : ''
      complete
    end

    def read_eocds(io)
      base_location, data = eocd_data(io)

      eocd_location = data.rindex([END_OF_CD_SIG].pack('V'))
      raise Error, 'Zip end of central directory signature not found' unless eocd_location

      return if unpack_e_o_c_d(data.slice(eocd_location..-1))

      zip64_eocd_locator = data.rindex([ZIP64_EOCD_LOCATOR_SIG].pack('V'), eocd_location)
      unless zip64_eocd_locator
        raise Error, 'Zip64 end of central directory locator signature expected but not found'
      end

      zip64_eocd_location = data.rindex([ZIP64_END_OF_CD_SIG].pack('V'), zip64_eocd_locator)

      zip64_eocd_data =
        if zip64_eocd_location
          data.slice(zip64_eocd_location..zip64_eocd_locator)
        else
          zip64_eocd_location = unpack_64_eocd_locator(
            data.slice(zip64_eocd_locator..eocd_location)
          )
          raise Error, 'Zip64 end of central directory signature not found' unless zip64_eocd_location

          io.seek(zip64_eocd_location, IO::SEEK_SET)
          io.read(base_location + zip64_eocd_locator - zip64_eocd_location)
        end

      unpack_64_e_o_c_d(zip64_eocd_data)
    end

    def eocd_data(io)
      IOExtras.binmode(io)
      begin
        io.seek(-MAX_END_OF_CD_SIZE, IO::SEEK_END)
      rescue Errno::EINVAL
        io.seek(0, IO::SEEK_SET)
      end

      [io.tell, io.read.to_s.b]
    end

    def validate_size!(size, size_in_bytes)
      return if size * CDIR_ENTRY_STATIC_HEADER_LENGTH <= size_in_bytes

      error = EntryNumberMismatchError.new(size, size_in_bytes)
      raise error if Ziperu.validate_declared_number_of_entries

      warn error.message
    end
  end
end
