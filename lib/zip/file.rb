# frozen_string_literal: true

require "stringio"

module Zip
  # Read side of rubyzip's `Zip::File`. Writing (`commit`, `add`, `remove`)
  # comes in a later step.
  class File
    include Enumerable

    attr_reader :name, :comment

    def self.open(path, create: false, **)
      raise NotImplementedError, "create: true is not supported yet" if create

      zf = new(path)
      return zf unless block_given?

      begin
        yield zf
      ensure
        zf.close
      end
    end

    def self.open_buffer(io, **)
      bytes = io.respond_to?(:read) ? io.read : io.to_str
      zf = new(nil, bytes: bytes)
      return zf unless block_given?

      yield zf
      zf
    end

    def self.foreach(path, &block)
      open(path) { |zf| zf.each(&block) }
    end

    def initialize(path, bytes: nil)
      @name = path
      @native =
        if bytes
          Native::Archive.open_bytes(bytes.b)
        else
          Native::Archive.open_path(path.to_s)
        end
      @comment = @native.comment.force_encoding(Encoding::UTF_8)
      @entries = @native.entries.map { |meta| Entry.new(self, meta) }
    end

    def entries
      @entries.dup
    end

    def each(&block)
      @entries.each(&block)
    end

    def size
      @entries.size
    end

    def find_entry(name)
      name = name.to_s
      @entries.find { |e| e.name == name } ||
        (@entries.find { |e| e.name == "#{name}/" } unless name.end_with?("/"))
    end

    def get_entry(name)
      find_entry(name) or raise Errno::ENOENT, name.to_s
    end

    def glob(*patterns, flags: ::File::FNM_PATHNAME | ::File::FNM_DOTMATCH | ::File::FNM_EXTGLOB)
      matches = @entries.select { |e| patterns.any? { |p| ::File.fnmatch(p, e.name, flags) } }
      return matches unless block_given?

      matches.each { |e| yield e }
    end

    def read(name)
      get_entry(name).get_raw_input_string
    end

    def get_input_stream(name, &block)
      get_entry(name).get_input_stream(&block)
    end

    def close
      @native = nil
    end

    def to_s
      @name.to_s
    end

    private

    def native
      @native or raise Error, "zip file is closed"
    end
  end
end
