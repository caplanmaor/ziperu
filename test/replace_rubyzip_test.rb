# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# `require "ziperu/replace_rubyzip"` keeps rubyzip's files from loading,
# even when they come first on the load path (as RubyGems puts a gem it
# activates later, without Bundler).
class ReplaceRubyzipTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def setup
    @dir = Dir.mktmpdir("ziperu-replace")
    # A stand-in for an installed rubyzip gem.
    @fake = File.join(@dir, "gems", "rubyzip-9.9.9", "lib")
    FileUtils.mkdir_p(File.join(@fake, "zip"))
    File.write(File.join(@fake, "zip.rb"), "module Zip; FAKE_RUBYZIP = true; end\n")
    File.write(File.join(@fake, "rubyzip.rb"), "require 'zip'\n")
    File.write(File.join(@fake, "zip", "filesystem.rb"), "module Zip; FAKE_FILESYSTEM = true; end\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def run_ruby(script, *load_path)
    args = load_path.flat_map { |p| ["-I", p] }
    Open3.capture3(RbConfig.ruby, *args, "-e", script)
  end

  def test_ziperu_answers_even_with_rubyzip_first_on_the_load_path
    out, err, status = run_ruby(<<~RUBY, LIB)
      require "ziperu/replace_rubyzip"
      $LOAD_PATH.unshift(#{@fake.inspect})  # rubyzip activated later
      require "zip"
      require "rubyzip"
      require "zip/filesystem"
      print [Zip.equal?(Ziperu), defined?(Zip::FAKE_RUBYZIP).nil?,
             defined?(Zip::FAKE_FILESYSTEM).nil?, defined?(Zip::FileSystem) ? true : false].inspect
    RUBY
    assert status.success?, err
    assert_equal "[true, true, true, true]", out
  end

  def test_other_requires_are_untouched
    out, err, status = run_ruby(<<~RUBY, LIB)
      require "ziperu/replace_rubyzip"
      require "zlib"
      require "set"
      print defined?(Zlib::Deflate) ? "ok" : "missing"
    RUBY
    assert status.success?, err
    assert_equal "ok", out
  end

  def test_refuses_once_rubyzip_is_loaded
    _out, err, status = run_ruby(<<~RUBY, @fake, LIB)
      require "zip"
      require "ziperu/replace_rubyzip"
    RUBY
    refute status.success?
    assert_includes err, "rubyzip is already loaded"
  end
end
