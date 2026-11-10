# frozen_string_literal: true

module Ziperu
  # The `Ziperu.*` settings as one archive sees them. `Ziperu::File`,
  # `Ziperu::InputStream` and `Ziperu::OutputStream` take any of NAMES as a
  # keyword; a setting given that way holds for that archive alone, and
  # the rest keep following the global, so two archives in one process can
  # differ:
  #
  #   Ziperu::File.open(upload, max_entries: 1_000, max_total_size: 2**30) { ... }
  #   Ziperu::OutputStream.open(path, write_extended_timestamps: true) { ... }
  #
  # With no setting given the archive consults `Ziperu` itself, which
  # answers to the same names.
  # Not in rubyzip.
  class Settings
    NAMES = %i[
      unicode_names on_exists_proc continue_on_exists_proc sort_entries
      write_zip64_support warn_invalid_date case_insensitive_match
      force_entry_names_encoding validate_entry_sizes
      max_entries max_total_size max_entry_size max_compression_ratio
      append_in_place write_extended_timestamps source_date_epoch
    ].freeze

    # Takes the settings out of `options` (leaving the other keywords) and
    # returns what the archive should consult.
    def self.take!(options) # :nodoc:
      given = {}
      NAMES.each { |name| given[name] = options.delete(name) if options.key?(name) }
      given.empty? ? ::Ziperu : new(given)
    end

    # The settings `settings` holds of its own, as keywords, to hand on
    # (from a `Ziperu::File` to the stream it writes through).
    def self.overrides(settings) # :nodoc:
      settings.equal?(::Ziperu) ? {} : settings.overrides
    end

    attr_reader :overrides # :nodoc:

    def initialize(overrides) # :nodoc:
      @overrides = overrides.freeze
    end

    NAMES.each do |name|
      define_method(name) { @overrides.fetch(name) { ::Ziperu.public_send(name) } }
    end

    # See Ziperu.default_entry_time.
    def default_entry_time(mtime = nil)
      ::Ziperu.entry_time(source_date_epoch, mtime)
    end
  end
end
