# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).

module Ziperu
  # An entry whose contents are being written through `get_output_stream`:
  # the data goes to a tempfile until the archive is committed.
  class StreamableStream < DelegateClass(Entry) # :nodoc:all
    def initialize(entry)
      super
      @temp_file = Tempfile.new(::File.basename(name))
      @temp_file.binmode
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

      @temp_file.open # reopens tempfile from top
      @temp_file.binmode
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

    def write_to_zip_output_stream(output_stream)
      output_stream.put_next_entry(self)
      get_input_stream { |is| ::Ziperu::IOExtras.copy_stream(output_stream, is) }
    end

    def clean_up
      super
      @temp_file.unlink
    end
  end
end
