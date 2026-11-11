# frozen_string_literal: true

# The rubyzip 3.x exception hierarchy, with rubyzip's constructor signatures
# and messages so rescue clauses and error output are unchanged.
#
# The native core looks these up by name, so every class here must exist
# before the extension raises.
module Ziperu
  # The superclass for all error types. Simply rescue this one if you don't
  # need to know what sort of error has been raised.
  class Error < StandardError; end

  # Error raised if an unsupported compression method is used.
  class CompressionMethodError < Error
    attr_reader :compression_method

    def initialize(method)
      super()
      @compression_method = method
    end

    def message
      "Unsupported compression method: #{COMPRESSION_METHODS[@compression_method]}."
    end
  end

  # Error raised if there is a problem while decompressing an archive entry.
  class DecompressionError < Error
    attr_reader :zlib_error

    def initialize(zlib_error)
      super()
      @zlib_error = zlib_error
    end

    def message
      "Zlib error ('#{@zlib_error.message}') while inflating."
    end
  end

  # Error raised when trying to extract an archive entry over an existing file.
  class DestinationExistsError < Error
    def initialize(destination)
      super()
      @destination = destination
    end

    def message
      "Cannot create file or directory '#{@destination}'. " \
        'A file already exists with that name.'
    end
  end

  # Error raised when adding an entry whose name already exists.
  class EntryExistsError < Error
    def initialize(source, name)
      super()
      @source = source
      @name = name
    end

    def message
      "'#{@source}' failed. Entry #{@name} already exists."
    end
  end

  # Error raised when an entry name is invalid.
  class EntryNameError < Error
    def initialize(name = nil)
      super()
      @name = name
    end

    def message
      if @name.nil?
        'Illegal entry name. Names must have fewer than 65,536 characters.'
      else
        "Illegal entry name '#{@name}'. Names must not start with '/'."
      end
    end
  end

  # Error raised if an entry is larger on extraction than advertised.
  class EntrySizeError < Error
    attr_reader :entry

    def initialize(entry)
      super()
      @entry = entry
    end

    def message
      "Entry '#{@entry.name}' should be #{@entry.size}B, but is larger when inflated."
    end
  end

  class EntryNumberMismatchError < Error
    def initialize(size, size_in_bytes)
      super()
      @size = size
      @size_in_bytes = size_in_bytes
    end

    def message
      "Zip consistency problem: an impossibly high number of entries (#{@size}) " \
        'is declared in this file, compared to the size of the central directory ' \
        "(#{@size_in_bytes} bytes)."
    end
  end

  # Error raised if a split archive is read.
  class SplitArchiveError < Error
    def message
      'Rubyzip cannot extract from split archives at this time.'
    end
  end

  # Error raised if there is not enough metadata for the entry to be streamed.
  class StreamingError < Error
    attr_reader :entry

    def initialize(entry)
      super()
      @entry = entry
    end

    def message
      "The local header of this entry ('#{@entry.name}') does not contain " \
        'the correct metadata for `Ziperu::InputStream` to be able to ' \
        'uncompress it. Please use `Ziperu::File` instead of `Ziperu::InputStream`.'
    end
  end

  class GPFBit3Error < Error; end
  class InternalError < Error; end

  # rubyzip 1.x's names, which 2.x still carried and code written back
  # then rescues; 3.0 removed them.
  ZipError = Error
  ZipEntryExistsError = EntryExistsError
  ZipDestinationFileExistsError = DestinationExistsError
  ZipCompressionMethodError = CompressionMethodError
  ZipEntryNameError = EntryNameError
  ZipInternalError = InternalError

  # Raised when an archive exceeds `Ziperu.max_entries`,
  # `Ziperu.max_total_size`, `Ziperu.max_entry_size` or
  # `Ziperu.max_compression_ratio` on open.
  class LimitError < Error
    def initialize(what, actual, limit)
      super("archive has #{what} of #{actual}, over the limit of #{limit}")
    end
  end

  PASSWORD_REQUIRED_MESSAGE = 'A password is required to decode this zip file.'

  # Raised by the Rust core where it lacks the domain object a rubyzip
  # exception wants; the Ruby layer re-raises the rubyzip-shaped error.
  # An entry object outlived a commit that moved its record; what it holds
  # from the central directory is still good, its local header is gone.
  class EntryMovedError < Error # :nodoc:
  end

  module Native
    class SizeLimitError < Ziperu::Error; end
    class PasswordError < Ziperu::Error; end
    class UnsupportedError < Ziperu::Error; end
    # A second entry under a name the stream already holds; the Ruby
    # layer re-raises it as `EntryExistsError`.
    class DuplicateEntryError < Ziperu::Error; end
  end
end
