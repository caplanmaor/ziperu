# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).

module Ziperu
  class EntrySet # :nodoc:all
    include Enumerable

    attr_reader :entry_set
    protected   :entry_set

    def initialize(an_enumerable = [])
      super()
      # Keyed by name for lookup, as in rubyzip; `@all` keeps every entry
      # in order, which only differs when an archive holds several records
      # under one name (see `push_record`).
      @entry_set = {}
      @all = []
      @shadowed = 0
      an_enumerable.each { |o| push(o) }
    end

    def include?(entry)
      @entry_set.include?(to_key(entry))
    end

    def find_entry(entry)
      @entry_set[to_key(entry)]
    end

    def <<(entry)
      return unless entry

      key = to_key(entry)
      old = @entry_set[key]
      return if old.equal?(entry)

      @entry_set[key] = entry
      # A replacement keeps the old entry's place, as a Hash assignment
      # does in rubyzip: formats such as EPUB depend on the order.
      at = old && @all.index { |e| e.equal?(old) }
      if at
        @all[at] = entry
      else
        remove_from_all(old) if old
        @all << entry
      end
    end

    alias push <<

    # Adds a record read from an archive. Unlike `<<`, an earlier record
    # of the very same name stays listed (and readable); the lookup by name
    # finds the later one, as rubyzip's does. Names that only share a key
    # (`Ziperu.case_insensitive_match`, or a trailing slash) collapse to
    # the later one, as in rubyzip.
    def push_record(entry)
      key = to_key(entry)
      old = @entry_set[key]
      return self << entry if old.nil? || old.name.b != entry.name.b

      @shadowed += 1
      @entry_set[key] = entry
      @all << entry
    end

    # True for a record that a later one of the same name hides from the
    # lookup by name: it is listed and readable, but not written back.
    def shadowed?(entry)
      return false if @shadowed.zero?

      current = @entry_set[to_key(entry)]
      !current.nil? && !current.equal?(entry)
    end

    def size
      @all.size
    end

    alias length size

    def delete(entry)
      key = to_key(entry)
      removed = @entry_set.delete(key)
      return if removed.nil?

      remove_from_all(removed)
      # A record this one shadowed takes over its name.
      if @shadowed.positive? && (shadowed = @all.reverse_each.find { |e| to_key(e) == key })
        @shadowed -= 1
        @entry_set[key] = shadowed
      end
      entry
    end

    def each(&block)
      entries.each(&block)
    end

    def entries
      sorted_entries
    end

    # deep clone
    def dup
      copy = EntrySet.new
      @all.each { |e| copy.push_record(e.dup) }
      copy
    end

    def ==(other)
      return false unless other.kind_of?(EntrySet)

      entries == other.entries
    end

    def parent(entry)
      @entry_set[to_key(entry.parent_as_string)]
    end

    def glob(pattern, flags = ::File::FNM_PATHNAME | ::File::FNM_DOTMATCH | ::File::FNM_EXTGLOB)
      entries.filter_map do |entry|
        next nil unless ::File.fnmatch(pattern, entry.name.chomp('/'), flags)

        yield(entry) if block_given?
        entry
      end
    end

    protected

    # A copy: callers rename or remove entries while iterating.
    def sorted_entries
      ::Ziperu.sort_entries ? @all.sort_by { |e| to_key(e) } : @all.dup
    end

    private

    # Removes `entry` itself (not another of the same name) from `@all`.
    def remove_from_all(entry)
      i = @all.index { |e| e.equal?(entry) }
      @all.delete_at(i) if i
    end

    # Keyed by name bytes: entry names are binary strings (as in rubyzip),
    # and a lookup with the same bytes in another encoding should find
    # them (which in rubyzip it does not).
    def to_key(entry)
      k = entry.to_s
      k = k.b unless k.encoding == ::Encoding::BINARY
      k = k.chomp('/') if k.end_with?('/')
      k = k.downcase if ::Ziperu.case_insensitive_match
      k
    end
  end
end
