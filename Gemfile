# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
gem "minitest", "~> 5.25"
# rubyzip itself is deliberately not a dependency: `rake compat` works from
# a source checkout in tmp/, and an installed rubyzip gem would let
# `require "zip/..."` fall through to it for files this gem lacks.
