# frozen_string_literal: true

require_relative "lib/ziperu/version"

Gem::Specification.new do |spec|
  spec.name = "ziperu"
  spec.version = Ziperu::VERSION
  spec.authors = ["Maor Caplan"]
  spec.email = ["caplanmaor@gmail.com"]

  spec.summary = "A drop-in rubyzip replacement backed by Rust."
  spec.description = "Zip reading and writing for Ruby with rubyzip's API under the " \
                     "Ziperu namespace, implemented on the Rust `zip` crate via Magnus. " \
                     "`require \"zip\"` aliases Zip = Ziperu so rubyzip code runs unchanged. " \
                     "Precompiled binaries, no C toolchain needed."
  spec.homepage = "https://github.com/caplanmaor/ziperu"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Named one by one under ext/, so a build directory there is never swept in.
  spec.files = Dir.glob(
    [
      "lib/**/*.rb",
      "ext/ziperu/{extconf.rb,build.rs,Cargo.toml}",
      "ext/ziperu/src/**/*.rs",
      "Cargo.toml",
      "Cargo.lock",
      "LICENSE.txt",
      "LICENSE-rubyzip.txt",
      "README.md",
      "CHANGELOG.md"
    ],
    base: __dir__
  )
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/ziperu/extconf.rb"]

  # Only needed to compile from source; the precompiled gems drop it.
  spec.add_dependency "rb_sys", "~> 0.9.130"
end
