# frozen_string_literal: true

# Same standard-library surface rubyzip loads, since code downstream tends
# to rely on it being there.
require 'English'
require 'delegate'
require 'digest'
require 'fileutils'
require 'forwardable'
require 'pathname'
require 'rbconfig'
require 'singleton'
require 'stringio'
require 'tempfile'
require 'zlib'

require_relative "ziperu/version"
require_relative "ziperu/errors"

# Prefer the precompiled, Ruby-version-specific binary shipped in native gems;
# fall back to the one rake-compiler builds for source installs.
begin
  require "ziperu/#{RUBY_VERSION[/\d+\.\d+/]}/ziperu"
rescue LoadError
  require "ziperu/ziperu"
end

require_relative "ziperu/constants"
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
  # Used by the ported Deflater only; kept because rubyzip exposes it.
  ZLIB_FLUSHING_STRATEGY = defined?(JRUBY_VERSION) ? Zlib::SYNC_FLUSH : Zlib::NO_FLUSH

  extend self

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
    @write_zip64_support = true
    @warn_invalid_date = true
    @case_insensitive_match = false
    @force_entry_names_encoding = nil
    @validate_entry_sizes = true
    @validate_declared_number_of_entries = false
  end

  # Set options in one block. The block runs only the first time.
  def setup
    yield self unless @_ran_once
    @_ran_once = true
  end

  reset!
end
