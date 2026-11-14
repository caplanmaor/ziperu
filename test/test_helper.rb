# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ziperu"
require "minitest/autorun"

# CI runs the suite once more under GC stress to catch unmarked Ruby values
# held from Rust. Stress is on from each test's setup to its teardown only:
# with it on from the start, loading Bundler, minitest and the gem a GC per
# allocation cost most of a minute per file, which made the nightly run of
# the whole suite overrun GitHub's six hours.
if ENV["GC_STRESS"] == "true"
  module GCStressPerTest
    def before_setup
      super
      GC.stress = true
    end

    def after_teardown
      GC.stress = false
      super
    end
  end
  Minitest::Test.prepend(GCStressPerTest)
end

module TestHelper
  DATA_DIR = File.expand_path("data", __dir__)

  def fixture(name)
    File.join(DATA_DIR, name)
  end

  # The Python interpreter to cross-check archives with, or nil.
  def python
    return @python if defined?(@python)

    @python = %w[python3 python].find do |cmd|
      system(cmd, "-c", "import zipfile", out: File::NULL, err: File::NULL)
    end
  end
end
