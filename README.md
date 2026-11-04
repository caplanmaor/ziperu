# ziperu

A drop-in replacement for [rubyzip](https://github.com/rubyzip/rubyzip) with a
Rust core. Same `Zip::File` / `Zip::Entry` / `Zip::InputStream` /
`Zip::OutputStream` API, backed by the [`zip`](https://github.com/zip-rs/zip2)
crate through [Magnus](https://github.com/matsadler/magnus).

```ruby
require "zip"   # or require "ziperu"

Zip::File.open("archive.zip") do |zf|
  zf.each { |entry| puts "#{entry.name} (#{entry.size} bytes)" }
  puts zf.read("README.txt")
end
```

**Status: early.** Read-only `Zip::File`, `Zip::InputStream` and
`get_input_stream` (with ZipCrypto/AES passwords) work; extraction, writing
and `commit` are in progress. Tracks the rubyzip 3.x API
(`Zip::RUBYZIP_COMPAT_VERSION`).

### Deliberate differences from rubyzip

- `Zip::InputStream` locates entries through the central directory instead
  of walking local headers, so archives written in streaming mode (general
  purpose bit 3, e.g. by macOS Archive Utility) read normally instead of
  raising `Zip::StreamingError`.
- Every read path stops at the entry's declared size, so a header that lies
  can't inflate into a zip bomb; a `Zip::EntrySizeError` is raised instead.

## Why

rubyzip is pure Ruby and does per-entry work in Ruby objects. ziperu parses
the central directory once in Rust and hands Ruby a flat metadata dump, reads
entries in large chunks, copies unchanged entries byte-for-byte on `commit`,
and releases the GVL while inflating from a real file. The intent is
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
`require "zip"` resolving to this gem. The per-file scorecard is written to
[COMPAT.md](COMPAT.md); per-file logs land in `tmp/compat-logs/`. Use
`ONLY=input_stream rake compat` to run a subset.

## Layout

- `ext/ziperu/` — the Rust extension (`Zip::Native::*`): a few primitive,
  positional-argument methods.
- `lib/zip/` — the rubyzip-shaped API in Ruby: kwargs, blocks, `Enumerable`,
  the error hierarchy, extra-field parsing.
- `test/` — minitest; `test/data/` holds fixture archives.

## License

MIT.
