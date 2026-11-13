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

# The tests that hand Ruby objects to the native core and back; the
# GC-stress and valgrind (rakelib/mem.rake) tasks run these.
NATIVE_BOUNDARY_TESTS = %w[
  test/io_source_test.rb test/extract_all_native_test.rb test/duplicate_names_test.rb
  test/failure_recovery_test.rb test/io_semantics_test.rb test/streaming_test.rb
].freeze

# Run with `GC.stress` on (see test_helper.rb) to catch unmarked values. A
# GC per allocation makes the full suite take half an hour, so only these
# on every push; the nightly CI run does the whole suite.
Rake::TestTask.new("test:gc_stress") do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList[*NATIVE_BOUNDARY_TESTS, "test/streaming_read_test.rb"]
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  desc "Lint the Ruby code (needs `bundle config set with lint`)"
  task(:rubocop) { abort "rubocop is not installed: bundle config set with lint && bundle install" }
end

task default: %i[compile test]
