# frozen_string_literal: true

# Differential fuzzing and benchmarks against rubyzip. Both use the
# rubyzip checkout that `rake compat:fetch` puts in tmp/rubyzip.

desc "Fuzz ziperu against Python's zipfile and rubyzip (ITERATIONS=200 or TIME=seconds, SEED=n)"
task fuzz: "compat:fetch" do
  args = []
  args += ["--seed", ENV["SEED"]] if ENV["SEED"]
  args += ["--time", ENV["TIME"]] if ENV["TIME"]
  args += ["--iterations", ENV["ITERATIONS"]] if ENV["ITERATIONS"]
  ruby "fuzz/differential.rb", *args
end

desc "Benchmark ziperu against rubyzip (RUNS=5, QUICK=1 for small sizes)"
task bench: "compat:fetch" do
  args = []
  args += ["--runs", ENV["RUNS"]] if ENV["RUNS"]
  args << "--quick" if ENV["QUICK"]
  ruby "-I", "tmp/rubyzip/lib", "-I", "lib", "bench/bench.rb", *args
end
