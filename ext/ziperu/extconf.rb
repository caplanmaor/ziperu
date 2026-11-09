# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("ziperu/ziperu") do |r|
  # The musl builds link the GCC unwinder statically: Alpine images do not
  # all ship libgcc_s.so.1 (ruby:3.1-alpine does not), and an extension
  # that needs it fails to load there. rb-sys exports RUSTFLAGS itself, so
  # a .cargo/config.toml would not be honoured; this is the place.
  target = [ENV["CARGO_BUILD_TARGET"], RbConfig::CONFIG["arch"]].compact.join(" ")
  r.extra_rustflags = %w[-C link-arg=-static-libgcc] if target.include?("musl")
end
