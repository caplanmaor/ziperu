# frozen_string_literal: true

# Makes ziperu answer for rubyzip in this process, whatever else is
# installed:
#
#   # config/boot.rb, or the first line of a script
#   require "ziperu/replace_rubyzip"
#
# From then on `require "zip"`, `require "rubyzip"` and every
# `require "zip/..."` load ziperu's files, so `Zip` is `Ziperu` and the
# gems written against rubyzip (roo, caxlsx, rubyXL, ...) run on it.
#
# Under Bundler this is what already happens, since ziperu's `lib` comes
# first on the load path. This file is for everywhere else: a script
# without Bundler, where RubyGems would activate the rubyzip gem a
# dependency asks for and put its files ahead of ziperu's on the load
# path. It must be required before anything loads rubyzip; if rubyzip is
# already loaded it raises LoadError rather than mix the two.
#
# Not in rubyzip.

module Ziperu
  # The `require` that sends rubyzip's files to ziperu's. Not in rubyzip.
  module ReplaceRubyzip
    # ziperu's own `lib`, where `zip.rb`, `rubyzip.rb` and `zip/` live.
    LIB = ::File.expand_path('..', __dir__)

    # The ziperu file that stands in for the rubyzip feature `name`, if
    # there is one.
    def self.substitute(name)
      name = name.to_s
      name = name.delete_suffix('.rb')
      return unless name == 'zip' || name == 'rubyzip' || name.start_with?('zip/')

      path = ::File.join(LIB, "#{name}.rb")
      path if ::File.file?(path)
    end

    # Whether rubyzip itself has already been loaded: a `Zip` that is not
    # ziperu's, or one of rubyzip's files among the loaded features.
    def self.rubyzip_loaded?
      return true if defined?(::Zip) && !(defined?(::Ziperu::File) && ::Zip.equal?(::Ziperu))

      ours = "#{LIB}/"
      $LOADED_FEATURES.any? do |feature|
        !feature.start_with?(ours) && feature.match?(%r{/(zip|rubyzip)\.rb\z|/zip/[^/]+\.rb\z}) &&
          feature.include?('rubyzip')
      end
    end

    private

    def require(name)
      path = ReplaceRubyzip.substitute(name)
      path ? super(path) : super
    end
  end
end

if Ziperu::ReplaceRubyzip.rubyzip_loaded?
  raise LoadError, 'rubyzip is already loaded, so ziperu cannot stand in for it: require ' \
                   '"ziperu/replace_rubyzip" before anything that loads rubyzip (first thing ' \
                   'in config/boot.rb, or at the top of the script)'
end

Kernel.prepend(Ziperu::ReplaceRubyzip)
require 'zip'
