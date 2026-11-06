# ziperu

A drop-in replacement for [rubyzip](https://github.com/rubyzip/rubyzip) with a
Rust core. Same `Ziperu::File` / `Ziperu::Entry` / `Ziperu::InputStream` /
`Ziperu::OutputStream` API, backed by the [`zip`](https://github.com/zip-rs/zip2)
crate through [Magnus](https://github.com/matsadler/magnus).

```ruby
require "ziperu"   # or require "zip" to get the Zip alias

Ziperu::File.open("archive.zip") do |zf|
  zf.each { |entry| puts "#{entry.name} (#{entry.size} bytes)" }
  puts zf.read("README.txt")
end
```

**Status: early.** `Ziperu::File` (read, `extract`/`extract_all`, `add`,
`add_recursive`, `get_output_stream`, `remove`, `rename`, `replace`,
`mkdir`, `commit`, `write_buffer`/`open_buffer`), `Ziperu::InputStream` and
`Ziperu::OutputStream` (with AES) and `Ziperu::FileSystem` work. ZipCrypto
writing and a few corners are still missing; see [COMPAT.md](COMPAT.md)
for what rubyzip's own test suite says. Tracks the rubyzip 3.x API
(`Ziperu::RUBYZIP_COMPAT_VERSION`).

### Migrating from rubyzip

The library lives in the `Ziperu` namespace. `require "zip"` loads it and
sets `Zip = Ziperu`, so existing code keeps working with a one-line change
to the Gemfile:

```ruby
gem "ziperu"   # instead of gem "rubyzip"
```

If rubyzip has to stay installed during the migration (another gem depends
on it, say), the two cannot share the `Zip` name: `require "zip"` raises a
`LoadError` naming the file that already defined `Zip`. Use `require "ziperu"`
and `Ziperu::` for the code you have switched, and leave `Zip::` to rubyzip
until it goes. Exception classes follow the namespace, so rescue
`Ziperu::Error` (or `Zip::Error`, which is the same class once aliased).

### Deliberate differences from rubyzip

- `Ziperu::InputStream` locates entries through the central directory instead
  of walking local headers, so archives written in streaming mode (general
  purpose bit 3, e.g. by macOS Archive Utility) read normally instead of
  raising `Ziperu::StreamingError`.
- Every read path stops at the entry's declared size, so a header that lies
  can't inflate into a zip bomb; a `Ziperu::EntrySizeError` is raised instead.
  (rubyzip only checks this in `extract`, not in `InputStream`.)
  `Ziperu.validate_entry_sizes = false` restores rubyzip's behaviour of
  extracting the full data with a warning.
- Writing ZipCrypto ("traditional") encryption is not supported: the Rust
  crate deliberately keeps that broken cipher read-only. `AESEncrypter`
  works; `TraditionalEncrypter` raises `Ziperu::Error` on the first entry.
- Archives compressed with bzip2, Deflate64 or zstd read normally; rubyzip
  raises `Ziperu::CompressionMethodError` for anything but Stored and Deflate.
- AES entries of 20 bytes or more are written as AE-1 (with a real CRC in the
  header) rather than rubyzip's always-AE-2 with a zero CRC; both are read
  by every AES-aware tool, and AE-1 adds an integrity check.
- Class names are `Ziperu::...` even when loaded through the `Zip` alias:
  `Zip::Entry.name` is `"Ziperu::Entry"`, and so are `inspect` output and
  exception messages. Comparisons against the string `"Zip::Entry"` need
  updating; comparisons against the constant do not.
- Extraction never creates symlinks (same as rubyzip 3.x) and refuses paths
  that resolve outside the destination directory, checking the resolved
  absolute path with a trailing separator, the fix for CVE-2026-85396.

## Why

rubyzip is pure Ruby and does per-entry work in Ruby objects. ziperu parses
the central directory once in Rust and hands Ruby a flat metadata dump, reads
entries in large chunks, copies unchanged entries byte-for-byte on `commit`,
and releases the GVL while inflating from a file or String buffer and while
deflating, so other Ruby threads keep running. An archive opened from any
other IO object (`open_buffer(io)`, `InputStream.open(io)`) is read through
it lazily, under the GVL; a pipe is read to its end first. The intent is
precompiled gems for every platform rubyzip runs on, zero runtime dependencies,
and stricter defaults on path traversal and declared-size checks.

## Development

Needs Ruby >= 3.1 and Rust >= 1.88.

```
bundle install
bundle exec rake compile test
```

### Windows

RubyInstaller is MinGW-based, so the extension builds for the GNU Rust
target and bindgen needs clang's resource headers. Once:

```
winget install RubyInstallerTeam.RubyWithDevKit.3.4
rustup target add x86_64-pc-windows-gnu
```

then in each shell:

```
. .\bin\windows-env.ps1
bundle exec rake compile test
```

### rubyzip compatibility

`rake compat` downloads rubyzip's source into `tmp/`, generates its fixtures
with the real rubyzip, then runs rubyzip's own test suite with
`require "zip"` resolving to this gem, so it also proves the `Zip` alias is
complete. The per-file scorecard is written to
[COMPAT.md](COMPAT.md); per-file logs land in `tmp/compat-logs/`. Use
`ONLY=input_stream rake compat` to run a subset.

## Layout

- `ext/ziperu/` — the Rust extension (`Ziperu::Native::*`): a few primitive,
  positional-argument methods.
- `lib/ziperu/` — the rubyzip-shaped API in Ruby: kwargs, blocks, `Enumerable`,
  the error hierarchy, extra-field parsing.
- `test/` — minitest; `test/data/` holds fixture archives.

## License

MIT.
