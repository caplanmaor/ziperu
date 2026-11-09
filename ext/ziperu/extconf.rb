# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

# On musl the extension needs libgcc_s.so.1 at run time: Rust's unwinder
# links it dynamically whenever the crate is a shared library, so no link
# flag here removes the dependency. Alpine's ruby images from 3.2 on ship
# it; ruby:3.1-alpine needs `apk add libgcc` (lib/ziperu.rb says so when
# the load fails).
create_rust_makefile("ziperu/ziperu")
