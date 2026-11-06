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
- Archives compressed with bzip2, Deflate64, zstd, LZMA, XZ, PPMd or the
  PKZIP 1.x methods (Shrink, Reduce, Implode) read normally; rubyzip raises
  `Ziperu::CompressionMethodError` for anything but Stored and Deflate.
  Entries can also be *written* with bzip2 or zstd
  (`put_next_entry(name, "", ExtraField.new, Ziperu::Entry::ZSTD, 3)`), which
  rubyzip, Windows Explorer and Java cannot read, so those are opt-in.
- AES entries of 20 bytes or more are written as AE-1 (with a real CRC in the
  header) rather than rubyzip's always-AE-2 with a zero CRC; both are read
  by every AES-aware tool, and AE-1 adds an integrity check.
- Entry names and comments come back as UTF-8 strings when the entry's
  language-encoding flag is set (which is how most tools, and ziperu
  itself, write non-ASCII names); rubyzip returns the raw bytes as binary
  strings. Entries without the flag, or whose flagged name is not valid
  UTF-8, stay binary as in rubyzip, and `Ziperu.force_entry_names_encoding`
  overrides both. A lookup (`find_entry`, `get_entry`, `read`) accepts the
  name in any encoding with the same bytes, so neither `.b` nor
  `force_encoding` is needed to find an entry.
- Writing two entries with the same name to one `OutputStream` raises
  `Ziperu::Error`; rubyzip writes both and the last one wins.
- A CRC mismatch while reading raises `Ziperu::DecompressionError`;
  rubyzip hands back the bytes.
- Every written file entry carries Unix permissions in its external
  attributes (0644 by default), and such permissions are read back whatever
  the entry's host system byte says; rubyzip leaves `unix_perms` nil for
  entries written on Windows. Setuid, setgid and sticky bits are not
  written, and a symlink added from disk is written as a regular file
  holding the link target.
- Editing an existing entry's comment, time or extra fields and committing
  rewrites that entry's data under a fresh header; a rename or a chmod on
  its own keeps the byte-for-byte copy. So does an untouched entry, unless
  it carries an extended-timestamp, NTFS or Info-ZIP unix extra field, which
  the native copy would not carry over intact. An encrypted entry is always
  copied as is: its name and permissions can change, and any other edit
  raises `Ziperu::Error` at commit rather than vanishing, which is what
  rubyzip does for compression methods it cannot write.
- Several entries with the same name in one archive: `Ziperu::File` lists
  them all and reads the last; `Ziperu::InputStream` yields only the last,
  where rubyzip walks every local header.
- `Ziperu::InputStream` over something that is not a zip archive at all
  returns `nil` from the first `get_next_entry`, as rubyzip does; a corrupt
  archive raises `Ziperu::Error` from `Ziperu::File.open` in both.
- `Zip::VERSION` is ziperu's own version, not rubyzip's. Code that gates on
  it (`Gem::Version.new(Zip::VERSION) >= "3"`) should check
  `Ziperu::RUBYZIP_COMPAT_VERSION` instead.
- An open `Ziperu::File` holds its file open until `close`. On Windows that
  blocks a commit by *another* `Ziperu::File` on the same path with
  `Errno::EACCES`; rubyzip closes the file between operations.
- Using one `InputStream`, `OutputStream` or `Zip::File` from two threads
  at the same time raises `ThreadError` ("in use by another thread")
  rather than corrupting state; rubyzip's objects are not thread-safe
  either, they just fail less loudly.
- Class names are `Ziperu::...` even when loaded through the `Zip` alias:
  `Zip::Entry.name` is `"Ziperu::Entry"`, and so are `inspect` output and
  exception messages. Comparisons against the string `"Zip::Entry"` need
  updating; comparisons against the constant do not.
- Extraction never creates symlinks unless asked to (see below; rubyzip 3.x
  never does) and refuses paths that resolve outside the destination
  directory, checking the resolved absolute path with a trailing separator,
  the fix for CVE-2026-85396.

### Beyond rubyzip

Everything here is additive: code that does not use it behaves as above.

- **Archive limits.** `Ziperu.max_entries` and `Ziperu.max_total_size`
  (declared uncompressed bytes) make `Ziperu::File.open` and
  `Ziperu::InputStream.open` raise `Ziperu::LimitError` before any entry is
  read. With `validate_entry_sizes` on (the default) no entry inflates past
  its declared size, so the total is a real bound on what an extraction can
  write.
- **Integrity check.** `Ziperu::File#verify` inflates every entry to nowhere
  so the CRC of each is checked, releasing the GVL meanwhile, and returns a
  Hash of failing entries to the exception each raised (empty when sound).
  Encrypted entries are checked when a `decrypter:` is given.
- **Symlink entries.** `add` of a symlink stores a link entry (target as
  content, `S_IFLNK` in the attributes) instead of a copy of the target.
  `extract_all(dir, symlinks: :create)` and `extract(..., symlinks: :create)`
  create such links, after the links' targets have been checked to resolve
  inside the destination; links are created after everything else so no
  file is written through one. The default stays `:skip`, with rubyzip's
  warning. `add_recursive` still skips links on disk.
- **Progress.** `extract_all(dir, progress: ->(entry, done, total) {})` and
  `add_recursive(dir, progress: ->(entry, done, nil) {})` report after each
  entry; `extract_all` keeps its native fast path and reports per batch.
- **More compression methods.** bzip2 and zstd on write; LZMA, XZ, PPMd,
  Deflate64 and the PKZIP 1.x methods on read (see above).
- **Streaming reads and writes through any IO.** `open_buffer(io)` reads an
  IO lazily and `write_buffer(io)` writes entry by entry, so neither holds
  the archive in memory.

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
| open and list 10000 entries | 298 ms | 130 ms | 2.3x |
| read 1000 x 8 KB deflated entries | 196 ms | 23 ms | 8.4x |
| InputStream over 1000 entries | 111 ms | 64 ms | 1.7x |
| inflate one 64 MB entry | 106 ms | 54 ms | 2.0x |
| extract_all 1000 entries | 984 ms | 459 ms | 2.1x |
| write 1000 x 8 KB entries (OutputStream) | 89 ms | 39 ms | 2.3x |
| deflate one 64 MB entry (OutputStream) | 245 ms | 58 ms | 4.3x |
| open_buffer(String) and read 1000 entries | 69 ms | 15 ms | 4.5x |
| Zip::File add 100 files and commit | 40 ms | 33 ms | 1.2x |

Inflating and deflating are where the Rust core pays off. Listing a large
central directory is dominated by building Ruby `Entry` objects, which both
libraries do in Ruby. `extract_all` writes every entry in one native call
(one open per file, with its mtime set on that handle) and is left bounded
by file creation itself, which is slow on Windows.

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
