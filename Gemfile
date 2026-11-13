# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
# rubyzip itself is deliberately not a dependency: `rake compat` works from
# a source checkout in tmp/, and an installed rubyzip gem would let
# `require "zip/..."` fall through to it for files this gem lacks.
# Used by fuzz/differential.rb; a bundled, not default, gem since Ruby 3.4.
gem "base64"
# `rake mem:check`; optional because of its nokogiri dependency. The CI
# memcheck job turns it on with BUNDLE_WITH=memcheck.
group :memcheck, optional: true do
  gem "ruby_memcheck"
end
# `rake rubocop`; optional so the test matrix does not install it. The CI
# lint job turns it on with BUNDLE_WITH=lint.
group :lint, optional: true do
  gem "rubocop", "~> 1.92", require: false
end
