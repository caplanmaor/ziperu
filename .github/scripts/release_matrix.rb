# frozen_string_literal: true

# The release matrix is a committed snapshot, .github/release-matrix.json:
# the platforms a release builds a native gem for, and the Rubies each
# holds an extension for. release.yml builds exactly that, so a release
# never gains or loses a Ruby or a platform because upstream's list moved
# on the day of the tag; it changes when the snapshot is changed, in a
# commit someone reviewed.
#
# This script compares the snapshot with what oxidize-rb's fetch-ci-data
# offers today (its JSON in the CI_DATA environment variable):
#
#   ruby .github/scripts/release_matrix.rb           # exit 1 and a diff when they differ
#   ruby .github/scripts/release_matrix.rb --write   # rewrite the snapshot

require "json"

SNAPSHOT = File.expand_path("../release-matrix.json", __dir__)
# The gemspec promises 3.1 and up; fetch-ci-data's stable set starts at the
# oldest Ruby still maintained, so the end-of-life minors are added here.
EOL_RUBIES = %w[3.1 3.2].freeze

data = JSON.parse(ENV.fetch("CI_DATA"))
live = {
  "platforms" => data.fetch("supported-ruby-platforms").sort,
  "rubies"    => (EOL_RUBIES | data.fetch("stable-ruby-versions")).sort_by { |v| v.split(".").map(&:to_i) }
}

if ARGV.include?("--write")
  File.write(SNAPSHOT, "#{JSON.pretty_generate(live)}\n")
  puts "wrote #{SNAPSHOT}"
  exit
end

snapshot = JSON.parse(File.read(SNAPSHOT))
drift = live.keys.flat_map do |key|
  (live[key] - snapshot[key]).map { |v| "  + #{key}: #{v} is available and not in the snapshot" } +
    (snapshot[key] - live[key]).map { |v| "  - #{key}: #{v} is in the snapshot and no longer offered" }
end

if drift.empty?
  puts "release matrix is current: #{snapshot['platforms'].size} platforms, Ruby #{snapshot['rubies'].join(', ')}"
else
  puts "The release matrix has drifted from .github/release-matrix.json:", drift
  puts "Releases keep building the snapshot. To adopt the change, run this script with --write and commit."
  exit 1
end
