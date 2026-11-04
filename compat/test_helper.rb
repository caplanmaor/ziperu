# frozen_string_literal: true

# Drop-in for rubyzip's test/test_helper.rb when its suite runs against
# ziperu (see rakelib/compat.rake). Fixtures are generated beforehand by
# compat/gen_fixtures.rb with the real rubyzip, so there is nothing to
# create or clean up here.

require 'minitest/autorun'
require 'zip'
require 'gentestfiles'

Minitest::Test.make_my_diffs_pretty!
