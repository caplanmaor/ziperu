# frozen_string_literal: true

# Same standard-library surface rubyzip loads, since code downstream tends
# to rely on it being there.
require "English"
require "delegate"
require "digest"
require "fileutils"
require "forwardable"
require "pathname"
require "rbconfig"
require "singleton"
require "stringio"
require "tempfile"
require "zlib"

require_relative "ziperu/version"
require_relative "ziperu/compat"
require_relative "ziperu/errors"

# Prefer the precompiled, Ruby-version-specific binary shipped in native gems;
# fall back to the one rake-compiler builds for source installs.
begin
  require "ziperu/#{RUBY_VERSION[/\d+\.\d+/]}/ziperu"
rescue LoadError => e
  begin
    require "ziperu/ziperu"
  rescue LoadError
    # RubyGems hands the glibc Linux gem to musl systems (Alpine) and the
    # bare error names a missing ld-linux; say what to do instead.
    hint = if e.message.include?("libgcc_s")
             # Rust's unwinder links libgcc_s dynamically on musl; Alpine's
             # ruby images from 3.2 on ship it, 3.1 does not.
             " The native extension needs libgcc_s.so.1: on Alpine run `apk add libgcc`."
           elsif e.message.include?("ld-linux") || e.message.include?("musl")
             " The installed ziperu gem was built for another libc; on Alpine (musl) use " \
               "`gem install ziperu --platform #{RUBY_PLATFORM}` or " \
               "`bundle lock --add-platform #{RUBY_PLATFORM}`, or install the source gem with " \
               "`gem install ziperu --platform ruby` (needs a Rust toolchain)."
           else
             " The native extension for Ruby #{RUBY_VERSION} is missing from the installed gem; " \
               "install the source gem with `gem install ziperu --platform ruby` (needs a Rust toolchain)."
           end
    raise LoadError, e.message + hint
  end
end

require_relative "ziperu/constants"
require_relative "ziperu/settings"
require_relative "ziperu/dos_time"
require_relative "ziperu/central_directory"
require_relative "ziperu/ioextras"
require_relative "ziperu/dirtyable"
require_relative "ziperu/extra_field"
require_relative "ziperu/crypto"
require_relative "ziperu/null_input_stream"
require_relative "ziperu/input_stream"
require_relative "ziperu/output_stream"
require_relative "ziperu/entry"
require_relative "ziperu/entry_set"
require_relative "ziperu/streamable_stream"
require_relative "ziperu/compressor"
require_relative "ziperu/decompressor"
require_relative "ziperu/null_compressor"
require_relative "ziperu/null_decompressor"
require_relative "ziperu/pass_thru_compressor"
require_relative "ziperu/pass_thru_decompressor"
require_relative "ziperu/inflater"
require_relative "ziperu/deflater"
require_relative "ziperu/streamable_directory"
require_relative "ziperu/file_split"
require_relative "ziperu/file"
require_relative "ziperu/size_estimator"

# Drop-in replacement for rubyzip, backed by a Rust core.
#
# The main entry points are File, InputStream and OutputStream. Global
# behaviour is configured with Ziperu.setup, exactly as in rubyzip:
#
#   Ziperu.setup do |c|
#     c.on_exists_proc = true
#     c.unicode_names = true
#   end
module Ziperu
  # Loaded on first use, so net/http is only required by those who read
  # archives over HTTP.
  autoload :RemoteIO, ::File.expand_path("ziperu/remote_io", __dir__)

  # Used by the ported Deflater only; kept because rubyzip exposes it.
  ZLIB_FLUSHING_STRATEGY = defined?(JRUBY_VERSION) ? Zlib::SYNC_FLUSH : Zlib::NO_FLUSH

  extend self

  # rubyzip's settings, with rubyzip's defaults.
  attr_accessor :unicode_names,
                :on_exists_proc,
                :continue_on_exists_proc,
                :sort_entries,
                :default_compression,
                :write_zip64_support,
                :warn_invalid_date,
                :case_insensitive_match,
                :force_entry_names_encoding,
                :validate_entry_sizes,
                :validate_declared_number_of_entries

  # ziperu's own settings; each is described where `reset!` gives it its
  # default.
  # Not in rubyzip.
  attr_accessor :max_entries,
                :max_archive_size,
                :max_total_size,
                :max_entry_size,
                :max_compression_ratio,
                :append_in_place,
                :write_extended_timestamps,
                :source_date_epoch

  DEFAULT_RESTORE_OPTIONS = {
    restore_ownership:   false,
    restore_permissions: true,
    restore_times:       true
  }.freeze # :nodoc:

  def reset! # :nodoc:
    @_ran_once = false
    @unicode_names = false
    @on_exists_proc = false
    @continue_on_exists_proc = false
    @sort_entries = false
    @default_compression = Zlib::DEFAULT_COMPRESSION
    # Zip64 for file entries: true writes the 64-bit fields when they may be
    # needed (a size unknown up front, or over 4 GiB), as rubyzip 3 does;
    # false only when the size leaves no choice; :always for every file
    # entry, to test readers. An entry's own `zip64:` overrides it.
    @write_zip64_support = true
    @warn_invalid_date = true
    @case_insensitive_match = false
    @force_entry_names_encoding = nil
    @validate_entry_sizes = true
    @validate_declared_number_of_entries = false
    # Opening an archive with more entries, or more declared uncompressed
    # bytes, than these raises Ziperu::LimitError. Nil means no limit. With
    # `validate_entry_sizes` on, no entry inflates past its declared size,
    # so the total is a real bound on what can be extracted.
    @max_entries = nil
    @max_total_size = nil
    # The most bytes read from a pipe or socket (an upload's `rack.input`,
    # say) before the archive is rejected. Its central directory is at the
    # end, so such an input is read whole before the other limits can be
    # checked; this bounds the memory that takes. A file or seekable IO is
    # never read whole and is not affected.
    @max_archive_size = nil
    # The largest uncompressed size any one entry may declare.
    @max_entry_size = nil
    # The highest uncompressed-to-compressed size ratio any entry may
    # declare (the archive's overall ratio can be no higher). A zip bomb
    # runs to a million or more; ordinary data rarely passes 100, though
    # a file of zeros deflates about 1000:1, so pick with that in mind.
    @max_compression_ratio = nil
    # When a commit only adds entries to an existing archive on disk, they
    # are appended in place, after the entries already there, instead of
    # the whole archive being rewritten through a temporary file: adding
    # one file to a large archive costs that file, not the archive. A
    # failure in the middle puts the archive back as it was; a crash in
    # the middle may not. Set to false to always rewrite.
    @append_in_place = true
    # With this on, every new entry gets Info-ZIP's extended timestamp
    # field (the modification time in UTC to the second), as Info-ZIP and
    # 7-Zip write; the DOS time in the header is local and has 2-second
    # resolution. Off by default, as in rubyzip (which writes one only
    # after `Entry#time=`): an extra field changes the bytes, and an EPUB's
    # first entry, for one, must have none.
    @write_extended_timestamps = false
    # Reproducible archives: with a Unix time here, every new entry's
    # timestamp is that instant (or the file's own, when earlier) in UTC,
    # whatever the clock and zone say, and the "made by" host system is
    # Unix on every platform, so the same input gives the same bytes on
    # every run and machine. Read from the SOURCE_DATE_EPOCH environment
    # variable, the convention build tools follow; set it here to apply
    # it without the variable, or to nil to ignore the variable.
    @source_date_epoch = ENV["SOURCE_DATE_EPOCH"]&.then { |v| Integer(v, exception: false) }
  end

  # The time a new entry gets by default: `source_date_epoch` when set,
  # the clock otherwise. `mtime` is the source file's own, which wins
  # when it is earlier (the SOURCE_DATE_EPOCH convention).
  # Not in rubyzip.
  def default_entry_time(mtime = nil)
    entry_time(source_date_epoch, mtime)
  end

  def entry_time(epoch, mtime) # :nodoc:
    return DOSTime.from_time(mtime || Time.now) unless epoch

    clamped = Time.at(epoch).utc
    clamped = mtime.utc if mtime && mtime < clamped
    DOSTime.from_time(clamped)
  end

  # Set options in one block. The block runs only the first time.
  def setup
    yield self unless @_ran_once
    @_ran_once = true
  end

  reset!
end
