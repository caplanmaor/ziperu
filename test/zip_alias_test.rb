# frozen_string_literal: true

# `require "zip"` is the rubyzip-compatible entry point: it makes `Zip` an
# alias of `Ziperu`, or refuses when some other library owns `Zip`.

require_relative "test_helper"
require "open3"

class ZipAliasTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def run_ruby(script)
    Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)
  end

  def test_require_zip_aliases_the_namespace
    out, err, status = run_ruby(<<~RUBY)
      require "zip"
      print [Zip.equal?(Ziperu), Zip::File.equal?(Ziperu::File), Zip::Error.equal?(Ziperu::Error)].inspect
    RUBY
    assert status.success?, err
    assert_equal "[true, true, true]", out
  end

  def test_require_zip_after_ziperu_is_fine
    out, err, status = run_ruby(<<~RUBY)
      require "ziperu"
      require "zip"
      print Zip.equal?(Ziperu)
    RUBY
    assert status.success?, err
    assert_equal "true", out
  end

  def test_foreign_zip_constant_is_refused
    _out, err, status = run_ruby(<<~RUBY)
      module Zip; end
      require "zip"
    RUBY
    refute status.success?
    assert_match(/cannot alias Zip = Ziperu/, err)
    assert_match(/LoadError/, err)
    assert_match(/-e/, err, "should name where Zip was defined")
  end

def test_rubyzip_file_paths_still_load
  out, err, status = run_ruby(<<~RUBY)
    require "zip/filesystem"
    require "zip/version"
    require "zip/ioextras/fake_io"
    print [Zip::FileSystem.equal?(Ziperu::FileSystem), Zip::VERSION == Ziperu::VERSION].inspect
  RUBY
  assert status.success?, err
  assert_equal "[true, true]", out
end

  def test_rubyzip_api_works_through_the_alias
    out, err, status = run_ruby(<<~RUBY)
      require "zip"
      buffer = Zip::OutputStream.write_buffer do |zos|
        zos.put_next_entry("hello.txt")
        zos.write("hi")
      end
      Zip::File.open_buffer(buffer.string) { |zf| print zf.read("hello.txt") }
      begin
        Zip::File.open("missing.zip")
      rescue Zip::Error => e
        print " ", e.class.name
      end
    RUBY
    assert status.success?, err
    assert_equal "hi Ziperu::Error", out
  end
end
