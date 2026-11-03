# frozen_string_literal: true

require_relative "lib/zip/version"

Gem::Specification.new do |spec|
  spec.name = "ziperu"
  spec.version = Zip::VERSION
  spec.authors = ["Maor Caplan"]
  spec.email = ["caplanmaor@gmail.com"]

  spec.summary = "A drop-in rubyzip replacement backed by Rust."
  spec.description = "Zip reading and writing for Ruby with rubyzip's API, " \
                     "implemented on the Rust `zip` crate via Magnus. " \
                     "Precompiled binaries, no C toolchain needed."
  spec.homepage = "https://github.com/maorcaplan/ziperu"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,rb,toml}",
    "Cargo.toml",
    "Cargo.lock",
    "LICENSE.txt",
    "README.md"
  ]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/ziperu/extconf.rb"]

  # Only needed to compile from source; the precompiled gems drop it.
  spec.add_dependency "rb_sys", "~> 0.9.130"
end
