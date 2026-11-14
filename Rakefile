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
# GC per allocation makes the whole suite take hours, so only these on
# every push; the nightly CI run does the rest (test:gc_stress_all).
Rake::TestTask.new("test:gc_stress") do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList[*NATIVE_BOUNDARY_TESTS, "test/streaming_read_test.rb"]
end

# The scale tests: archives of thousands of entries and inputs of
# megabytes built in Ruby. Each takes more than a quarter of an hour on its
# own under GC stress, so the nightly stress run leaves them out. They run
# without stress everywhere else, and the native code they reach is
# covered by the smaller suites.
GC_STRESS_TOO_SLOW = %w[
  test/listing_test.rb test/line_reading_test.rb test/input_stream_test.rb test/parallel_test.rb
  test/remote_io_test.rb test/perf_paths_test.rb test/size_estimator_test.rb
].freeze

# The whole suite but GC_STRESS_TOO_SLOW, under GC stress, in one of
# several shards: SHARD=2/4 takes every fourth file from the second on.
Rake::TestTask.new("test:gc_stress_all") do |t|
  t.libs << "test" << "lib"
  shard, of = ENV.fetch("SHARD", "1/1").split("/").map { |n| Integer(n) }
  files = (FileList["test/**/*_test.rb"].to_a - GC_STRESS_TOO_SLOW).sort
  t.test_files = files.select.with_index { |_, i| i % of == shard - 1 }
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  desc "Lint the Ruby code (needs `bundle config set with lint`)"
  task(:rubocop) { abort "rubocop is not installed: bundle config set with lint && bundle install" }
end

task default: %i[compile test]
