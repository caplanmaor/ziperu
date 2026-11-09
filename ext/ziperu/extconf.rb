# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("ziperu/ziperu") do |r|
  # The musl builds link the GCC unwinder statically: Alpine images do not
  # all ship libgcc_s.so.1 (ruby:3.1-alpine does not), and an extension
  # that needs it fails to load there. rb-sys exports RUSTFLAGS itself, so
  # a .cargo/config.toml would not be honoured; this is the place. The
  # target is named differently by rb-sys-dock (RUBY_TARGET), rb-sys
  # (CARGO_BUILD_TARGET / RUST_TARGET) and a native build (the host arch).
  target = [r.target, ENV["CARGO_BUILD_TARGET"], ENV["RUST_TARGET"], ENV["RUBY_TARGET"],
            RbConfig::CONFIG["arch"]].compact.join(" ")
  if target.include?("musl")
    puts "ziperu: musl target (#{target.split.uniq.join(', ')}), linking libgcc statically"
    r.extra_rustflags = %w[-C link-arg=-static-libgcc]
  end
end
