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
deflating, so other Ruby threads keep running. A StringIO is read from its
string directly; an archive opened from any other IO object
(`open_buffer(io)`, `InputStream.open(io)`) is read through it lazily,
under the GVL; a pipe is read to its end first. The intent is
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

### Fuzzing

`rake fuzz` runs [fuzz/differential.rb](fuzz/differential.rb): random
archives go through ziperu and Python's `zipfile` (plus rubyzip, once
`rake compat:fetch` has run) in both directions, random edits are made
through the `Zip::File` API and checked by the oracles, and corrupted
archives must fail with ziperu's own error classes while agreeing with the
oracle on anything both still accept. CI runs three minutes of it per push
with a fresh seed; a failure is saved under `tmp/fuzz/failures/` with the
seed that reproduces it (`SEED=n ITERATIONS=m rake fuzz`).

There is deliberately no cargo-fuzz harness: the Rust layer is thin
wrappers over the `zip` crate, which has its own fuzzing, and the code
that is ours (entry ownership, the chunked reader, the Ruby IO source) is
only reachable through the Ruby API, which is what the differential fuzzer
drives.

### Benchmarks

`rake bench` runs [bench/bench.rb](bench/bench.rb) with rubyzip and ziperu
loaded side by side. On one Windows machine (Ruby 3.4, median of 5):

| scenario | rubyzip 3.7.0 | ziperu 0.1.0 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 300 ms | 206 ms | 1.5x |
| read 1000 x 8 KB deflated entries | 207 ms | 51 ms | 4.1x |
| InputStream over 1000 entries | 106 ms | 66 ms | 1.6x |
| inflate one 64 MB entry | 106 ms | 40 ms | 2.6x |
| extract_all 1000 entries | 992 ms | 859 ms | 1.2x |
| write 1000 x 8 KB entries (OutputStream) | 89 ms | 34 ms | 2.6x |
| deflate one 64 MB entry (OutputStream) | 269 ms | 58 ms | 4.6x |
| open_buffer(String) and read 1000 entries | 62 ms | 20 ms | 3.0x |
| Zip::File add 100 files and commit | 40 ms | 33 ms | 1.2x |

Inflating and deflating are where the Rust core pays off. Listing a large
central directory and `extract_all` are dominated by building Ruby `Entry`
objects and creating files, which both libraries do in Ruby.

### Releasing

A `v*` tag runs [release.yml](.github/workflows/release.yml): the source
gem plus one precompiled gem per platform (built with
[oxidize-rb/actions/cross-gem](https://github.com/oxidize-rb/actions), each
holding the extension for every stable Ruby), a smoke test that installs
the right gem on Linux, macOS and Windows without a Rust toolchain, and a
draft GitHub release with the gems attached. Pushing to rubygems.org is a
manual `gem push` from that draft.

## Layout

- `ext/ziperu/` — the Rust extension (`Ziperu::Native::*`): a few primitive,
  positional-argument methods.
- `lib/ziperu/` — the rubyzip-shaped API in Ruby: kwargs, blocks, `Enumerable`,
  the error hierarchy, extra-field parsing.
- `test/` — minitest; `test/data/` holds fixture archives.
- `fuzz/` — the differential fuzzer and its Python and rubyzip oracles.
- `bench/` — the rubyzip comparison benchmark.

## License

MIT, see [LICENSE.txt](LICENSE.txt). The Ruby layer ports a good part of
rubyzip (the extra-field, filesystem, DOS time, entry-set and split code,
and the test fixtures under `test/data/rubyzip/`), which is BSD-2-Clause;
its notice is in [LICENSE-rubyzip.txt](LICENSE-rubyzip.txt) and the ported
files say so at the top.
