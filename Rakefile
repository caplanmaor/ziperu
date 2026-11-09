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

# The tests that hand Ruby objects to the native core and back, run with
# `GC.stress` on (see test_helper.rb) to catch unmarked values. A GC per
# allocation makes the full suite take half an hour, so only these on
# every push; the nightly CI run does the whole suite.
Rake::TestTask.new("test:gc_stress") do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList[
    "test/io_source_test.rb", "test/extract_all_native_test.rb", "test/duplicate_names_test.rb",
    "test/review_regressions_test.rb", "test/streaming_test.rb"
  ]
end

task default: %i[compile test]
