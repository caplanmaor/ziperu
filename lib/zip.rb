# frozen_string_literal: true

# rubyzip's entry point. Loading ziperu this way makes `Zip` an alias of
# `Ziperu`, so code written against rubyzip (`Zip::File`, `Zip.setup`, ...)
# runs unchanged. If another library already defines `Zip` (rubyzip itself,
# most likely), the two cannot share the name: load ziperu with
# `require "ziperu"` and use `Ziperu::` directly instead.
if defined?(Zip) && !(defined?(Ziperu) && Zip.equal?(Ziperu))
  raise LoadError, "ziperu cannot alias Zip = Ziperu: a Zip constant is already defined " \
                   "(by #{Object.const_source_location(:Zip)&.first || "another library"}). " \
                   "Remove rubyzip, or require \"ziperu\" and use Ziperu:: instead."
end

require "ziperu"
Zip = Ziperu unless defined?(Zip)

# The `zip/...` paths rubyzip's files live at (`require "zip/filesystem"`
# is the common one) are kept under lib/zip/ as one-line shims onto the
# matching lib/ziperu/ file.
