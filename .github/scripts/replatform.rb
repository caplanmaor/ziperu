# frozen_string_literal: true

# Relabels a glibc Linux gem (platform `x86_64-linux` or `aarch64-linux`) as
# `-gnu`. RubyGems treats the bare platform as "any libc" and hands it to
# musl systems (Alpine) too, where the binary cannot load; with the libc in
# the platform, musl gets the `-musl` gem and glibc the `-gnu` one. Only
# RubyGems 3.3.22 and later know these suffixes, so the gem says so.
#
#   ruby .github/scripts/replatform.rb pkg/ziperu-0.1.1-x86_64-linux.gem
#
# Writes the `-gnu` gem beside the original and removes the original.
require "rubygems/package"
require "fileutils"
require "tmpdir"

path = File.expand_path(ARGV.fetch(0) { abort "usage: replatform.rb GEM" })
pkg = Gem::Package.new(path)
spec = pkg.spec
unless spec.platform.to_s.match?(/\A(x86_64|aarch64|arm)-linux\z/)
  abort "#{File.basename(path)}: not a bare Linux platform gem (#{spec.platform})"
end

out = Dir.mktmpdir do |dir|
  pkg.extract_files(dir)
  spec.platform = Gem::Platform.new("#{spec.platform}-gnu")
  spec.required_rubygems_version = Gem::Requirement.new(">= 3.3.22")
  Dir.chdir(dir) do
    built = Gem::Package.build(spec)
    FileUtils.mv(built, File.join(File.dirname(path), built))
    File.join(File.dirname(path), built)
  end
end
File.delete(path)
puts out
