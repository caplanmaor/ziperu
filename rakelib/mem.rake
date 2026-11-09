# frozen_string_literal: true

# Memory checks for the native extension, after wasmtime-rb's.
#
#   rake mem:growth   loops a representative workload and fails if the
#                     process keeps growing (a leak in the Rust core, or a
#                     Ruby object the native side never lets go of)
#   rake mem:check    the GC-boundary tests under valgrind, through the
#                     ruby_memcheck gem (Linux, valgrind >= 3.20)
#
# `mem:check` needs `gem install ruby_memcheck` and valgrind on the PATH;
# it is not in the Gemfile because of its nokogiri dependency.
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
      t.test_files = FileList[
        "test/io_source_test.rb", "test/extract_all_native_test.rb", "test/duplicate_names_test.rb",
        "test/review_regressions_test.rb", "test/streaming_test.rb", "test/append_test.rb",
        "test/parallel_test.rb"
      ]
    end
  rescue LoadError
    desc "The GC-boundary tests under valgrind (needs `gem install ruby_memcheck`)"
    task :check do
      abort "mem:check needs the ruby_memcheck gem and valgrind: gem install ruby_memcheck"
    end
  end
end
