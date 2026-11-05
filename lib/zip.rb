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

require_relative "zip/version"
require_relative "zip/errors"

# Prefer the precompiled, Ruby-version-specific binary shipped in native gems;
# fall back to the one rake-compiler builds for source installs.
begin
  require "ziperu/#{RUBY_VERSION[/\d+\.\d+/]}/ziperu"
rescue LoadError
  require "ziperu/ziperu"
end

require_relative "zip/constants"
require_relative "zip/dos_time"
require_relative "zip/central_directory"
require_relative "zip/ioextras"
require_relative "zip/dirtyable"
require_relative "zip/extra_field"
require_relative "zip/crypto"
require_relative "zip/null_input_stream"
require_relative "zip/input_stream"
require_relative "zip/output_stream"
require_relative "zip/entry"
require_relative "zip/entry_set"
require_relative "zip/streamable_stream"
require_relative "zip/streamable_directory"
require_relative "zip/file_split"
require_relative "zip/file"

# Drop-in replacement for rubyzip, backed by a Rust core.
#
# The main entry points are File, InputStream and OutputStream. Global
# behaviour is configured with Zip.setup, exactly as in rubyzip:
#
#   Zip.setup do |c|
#     c.on_exists_proc = true
#     c.unicode_names = true
#   end
module Zip
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
