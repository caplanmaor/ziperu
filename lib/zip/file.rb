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
      zf = new(nil, archive: InputStream.open_archive(io.respond_to?(:read) ? io : StringIO.new(io.to_str)))
      return zf unless block_given?

      yield zf
      zf
    end

    def self.foreach(path, &block)
      open(path) { |zf| zf.each(&block) }
    end

    # Extracts every entry of the archive at `zip_file_name` into
    # `destination_directory`.
    def self.extract_all(zip_file_name, destination_directory = '.', &block)
      open(zip_file_name) do |zf|
        zf.extract_all(destination_directory, &block)
      end
    end

    def initialize(path, archive: nil)
      @name = path
      @native = archive || InputStream.open_archive(path.to_s)
      @comment = @native.comment.force_encoding(Encoding::UTF_8)
      @entries = @native.entries.map { |meta| Entry.from_meta(@native, meta, self) }
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

    # Returns an input stream to the specified entry. If a block is passed
    # the stream object is passed to the block and closed afterwards.
    def get_input_stream(entry, &block)
      entry = get_entry(entry) unless entry.is_a?(Entry)
      entry.get_input_stream(&block)
    end

    # Extracts `entry` to a file at `entry_path`, with
    # `destination_directory` as the base. The block (or Zip.on_exists_proc)
    # decides whether an existing file is overwritten.
    def extract(entry, entry_path = nil, destination_directory: '.', &block)
      block ||= proc { ::Zip.on_exists_proc }
      found_entry = get_entry(entry)
      entry_path ||= found_entry.name
      found_entry.extract(entry_path, destination_directory: destination_directory, &block)
    end

    # Extracts every entry in the archive into `destination_directory`,
    # preserving the archive's directory structure. Symlink entries are
    # skipped with a warning; see `Entry#extract` for the path-safety checks
    # applied to every other entry.
    def extract_all(destination_directory = '.', &block)
      # Directories first, so files have somewhere to go.
      dirs, others = entries.partition(&:directory?)

      (dirs + others).each do |entry|
        if entry.symlink?
          warn "WARNING: skipped symlink '#{entry.name}' during extract_all."
          next
        end

        entry.extract(entry.name, destination_directory:     destination_directory,
                                  create_parent_directories: true, &block)
      end

      self
    end

    def close
      @native = nil
    end

    def to_s
      @name.to_s
    end
  end
end
