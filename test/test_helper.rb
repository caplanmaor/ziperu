# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "zip"
require "minitest/autorun"

# CI runs the suite once more under GC stress to catch unmarked Ruby values
# held from Rust.
GC.stress = true if ENV["GC_STRESS"] == "true"

module TestHelper
  DATA_DIR = File.expand_path("data", __dir__)

  def fixture(name)
    File.join(DATA_DIR, name)
  end
end
