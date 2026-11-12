# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).

module Ziperu
  # An entry whose contents are being written through `get_output_stream`:
  # the data is held until the archive is committed. It starts in memory
  # and moves to a tempfile once the archive's entries hold more than
  # `SpoolIO::BUDGET` bytes in memory between them; rubyzip opens a
  # tempfile for every entry, which costs more than writing a small one.
  class StreamableStream < DelegateClass(Entry) # :nodoc:all
    def initialize(entry, budget = SpoolIO::Budget.new)
      super(entry)
      @temp_file = SpoolIO.new(::File.basename(name), budget)
    end

    def get_output_stream
      if block_given?
        begin
          yield(@temp_file)
        ensure
          @temp_file.close
        end
      else
        @temp_file
      end
    end

    def read_all # :nodoc:
      get_input_stream(&:read)
    end

    def get_input_stream
      unless @temp_file.closed?
        raise StandardError, "cannot open entry for reading while its open for writing - #{name}"
      end

      io = @temp_file.reader
      if block_given?
        begin
          yield(io)
        ensure
          io.close
        end
      else
        io
      end
    end

    def write_to_zip_output_stream(output_stream)
      output_stream.put_next_entry(self)
      get_input_stream { |is| ::Ziperu::IOExtras.copy_stream(output_stream, is) }
    end

    def clean_up
      super
      @temp_file.unlink
    end
  end

  # What `get_output_stream` hands out: a StringIO that becomes a Tempfile
  # (with what was written so far) when its archive's in-memory budget
  # runs out. Everything else is the IO's own.
  class SpoolIO < SimpleDelegator # :nodoc:all
    # Bytes the pending `get_output_stream` entries of one archive may hold
    # in memory between them.
    BUDGET = 8 * 1024 * 1024

    # The bytes left to the entries of one archive.
    class Budget
      attr_accessor :left

      def initialize(left = BUDGET)
        @left = left
      end
    end

    def initialize(basename, budget)
      @basename = basename
      @budget = budget
      @held = 0
      @file = nil
      super(::StringIO.new(+''.b))
    end

    # Every call goes to the IO; afterwards, the memory it holds is
    # counted, and past the budget moved to a tempfile.
    def method_missing(name, *args, &block)
      result = super
      account unless @file
      result.equal?(__getobj__) ? self : result
    end
    ruby2_keywords(:method_missing)

    def respond_to_missing?(name, include_private = false)
      __getobj__.respond_to?(name, include_private)
    end

    # An IO over what was written, from its start.
    def reader
      if @file
        @file.open
        @file.binmode
        @file
      else
        ::StringIO.new(__getobj__.string, 'rb')
      end
    end

    def unlink
      if @file
        @file.close
        @file.unlink
      else
        __getobj__.string.clear unless __getobj__.string.frozen?
        @budget.left += @held
        @held = 0
      end
    end

    def path
      spill
      @file.path
    end

    private

    def account
      size = __getobj__.string.bytesize
      grown = size - @held
      return if grown.zero?

      if grown > @budget.left
        spill
      else
        @budget.left -= grown
        @held = size
      end
    end

    def spill
      return if @file

      io = __getobj__
      file = ::Tempfile.new(@basename)
      file.binmode
      file.write(io.string)
      if io.closed?
        file.close
      else
        file.pos = io.pos
      end
      @budget.left += @held
      @held = 0
      @file = file
      __setobj__(file)
    end
  end
end
