# frozen_string_literal: true

# The release smoke test: installs, from a directory of built gems, the one
# RubyGems would pick for this machine, then loads it in a fresh process
# and round-trips an archive. No Rust toolchain is present where this runs,
# so a wrong pick (or a gem whose extension fails to load) is a failure.
#
#   ruby .github/scripts/smoke.rb gems/
require "rubygems/package"

dir = ARGV.fetch(0) { abort "usage: smoke.rb GEM_DIR" }
gems = Dir[File.join(dir, "*.gem")]
abort "no gems in #{dir}" if gems.empty?

local = Gem::Platform.local
candidates = gems.select do |f|
  spec = Gem::Package.new(f).spec
  spec.platform != Gem::Platform::RUBY && Gem::Platform.match_spec?(spec) &&
    spec.required_rubygems_version.satisfied_by?(Gem.rubygems_version)
end
abort "no native gem matches #{local} (RubyGems #{Gem.rubygems_version}) among: #{gems.map { |g| File.basename(g) }.join(', ')}" if candidates.empty?
abort "several gems match #{local}: #{candidates.join(', ')}" if candidates.size > 1

gem = candidates.first
puts "installing #{File.basename(gem)} on #{local} (RubyGems #{Gem.rubygems_version})"
system("gem", "install", "--local", "--ignore-dependencies", "--no-document", gem, exception: true)

check = <<~RUBY
  require "zip"
  out = Zip::OutputStream.write_buffer { |z| z.put_next_entry("a.txt"); z.write("ok") }
  Zip::File.open_buffer(out.string) { |zf| abort "round trip failed" unless zf.read("a.txt") == "ok" }
  spec = Gem.loaded_specs["ziperu"]
  puts "ziperu \#{Ziperu::VERSION} (\#{spec.platform}) loaded as Zip on \#{RUBY_PLATFORM}"
RUBY
system("ruby", "-e", check, exception: true)
