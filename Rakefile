# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("ziperu.gemspec")

RbSys::ExtensionTask.new("ziperu", GEMSPEC) do |ext|
  ext.lib_dir = "lib/ziperu"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: %i[compile test]
