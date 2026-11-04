# frozen_string_literal: true

# Drop-in for rubyzip's test/test_helper.rb when its suite runs against
# ziperu (see rakelib/compat.rake). Fixtures are generated beforehand by
# compat/gen_fixtures.rb with the real rubyzip, so there is nothing to
# create or clean up here.

require 'minitest/autorun'
require 'zip'
require 'gentestfiles'

Minitest::Test.make_my_diffs_pretty!

# If a `require "zip/..."` for a file this gem lacks falls through to an
# installed rubyzip gem, the run is measuring the wrong library.
Minitest.after_run do
  if Gem.loaded_specs['rubyzip']
    warn 'COMPAT LEAK: the rubyzip gem was activated during this run'
    exit!(99)
  end
end
