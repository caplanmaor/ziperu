# frozen_string_literal: true

module Ziperu
  # Ready-made sets of the limit settings (`max_entries`,
  # `max_total_size`, `max_entry_size`, `max_compression_ratio`,
  # `max_archive_size`), as keywords for one archive or for every one:
  #
  #   Ziperu::File.open(upload, **Ziperu::Limits::UPLOAD) { |zf| ... }
  #   Ziperu::Limits.apply(Ziperu::Limits::UPLOAD)   # the Ziperu.* globals
  #
  # Every limit is checked before an entry is read, and raises
  # Ziperu::LimitError. A profile is a frozen Hash: merge it to change one
  # value (`Ziperu::Limits::UPLOAD.merge(max_entries: 50_000)`).
  # Not in rubyzip.
  module Limits
    # For archives users upload: room for real projects, spreadsheets and
    # photo sets, not for a zip bomb (which runs to a ratio of a million).
    UPLOAD = {
      max_entries:           10_000,
      max_total_size:        2 << 30,   # 2 GiB uncompressed in all
      max_entry_size:        1 << 30,   # 1 GiB for any one entry
      max_compression_ratio: 1_000,
      max_archive_size:      2 << 30    # 2 GiB read from a pipe or IO
    }.freeze

    # For small documents from anyone (an office file, a config bundle).
    STRICT = {
      max_entries:           1_000,
      max_total_size:        256 << 20, # 256 MiB
      max_entry_size:        64 << 20,  # 64 MiB
      max_compression_ratio: 100,
      max_archive_size:      256 << 20
    }.freeze

    # No limits: the default.
    NONE = UPLOAD.transform_values { nil }.freeze

    # Sets the `Ziperu.*` limit globals from `profile` (one of the above,
    # or a Hash with any of their keys; a key left out is left alone).
    def self.apply(profile)
      unknown = profile.keys - NONE.keys
      raise ArgumentError, "not a limit: #{unknown.join(', ')}" unless unknown.empty?

      profile.each { |name, value| ::Ziperu.public_send(:"#{name}=", value) }
      profile
    end
  end
end
