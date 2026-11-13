# frozen_string_literal: true

# Memory checks for the native extension, after wasmtime-rb's.
#
#   rake mem:growth   loops a representative workload and fails if the
#                     process keeps growing (a leak in the Rust core, or a
#                     Ruby object the native side never lets go of)
#   rake mem:check    the GC-boundary tests under valgrind, through the
#                     ruby_memcheck gem (Linux, valgrind >= 3.20)
#
# `mem:check` needs valgrind on the PATH and `BUNDLE_WITH=memcheck bundle`;
# ruby_memcheck is an optional Gemfile group because of its nokogiri dependency.
namespace :mem do
  desc "Loop a workload and fail if the process keeps growing (ITERATIONS=200)"
  task growth: :compile do
    ruby "-Ilib", "test/mem/growth.rb"
  end

  begin
    require "ruby_memcheck"

    RubyMemcheck.config(binary_name: "ziperu")
    RubyMemcheck::TestTask.new(check: :compile) do |t|
      t.libs << "test" << "lib"
      t.test_files = FileList[*NATIVE_BOUNDARY_TESTS, "test/append_test.rb", "test/parallel_test.rb"]
    end
  rescue LoadError
    desc "The GC-boundary tests under valgrind (needs `gem install ruby_memcheck`)"
    task :check do
      abort "mem:check needs the ruby_memcheck gem and valgrind: BUNDLE_WITH=memcheck bundle install"
    end
  end
end
