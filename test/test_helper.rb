# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ziperu"
require "minitest/autorun"

# CI runs the suite once more under GC stress to catch unmarked Ruby values
# held from Rust.
GC.stress = true if ENV["GC_STRESS"] == "true"

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
