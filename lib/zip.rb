# frozen_string_literal: true

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
require_relative "zip/entry"
require_relative "zip/file"

# Drop-in replacement for rubyzip, backed by a Rust core.
module Zip
end
