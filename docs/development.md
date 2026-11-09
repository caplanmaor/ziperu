# Development

Needs Ruby >= 3.1 and Rust >= 1.88.

```
bundle install
bundle exec rake compile test
```

## Windows

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

## rubyzip compatibility

`rake compat` downloads rubyzip's source into `tmp/`, generates its fixtures
with the real rubyzip, then runs rubyzip's own test suite with
`require "zip"` resolving to this gem, so it also proves the `Zip` alias is
complete. The per-file scorecard is written to
[COMPAT.md](../COMPAT.md); per-file logs land in `tmp/compat-logs/`. Use
`ONLY=input_stream rake compat` to run a subset.

## Fuzzing

`rake fuzz` runs [fuzz/differential.rb](../fuzz/differential.rb): random
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

## Memory checks

```bash
bundle exec rake mem:growth          # loop the whole API, fail if RSS keeps growing
gem install ruby_memcheck            # once; needs valgrind >= 3.20 (Linux)
bundle exec rake mem:check           # the GC-boundary tests under valgrind
```

`mem:growth` (test/mem/growth.rb) runs a workload that crosses the native
boundary every way the gem offers (files, IOs, streams, AES, ZipCrypto,
threads, append) and samples the resident size after a full GC every 20
iterations; it fails if the process has grown more than 8 MiB since it
warmed up. `mem:check` runs the tests that hand Ruby objects to the core
under valgrind through ruby_memcheck, which filters Ruby's own noise.
CI runs both on Linux (the `memcheck` job), and `cargo test` for the
pure-Rust parts.

## Benchmarks

`rake bench` runs [bench/bench.rb](../bench/bench.rb) with rubyzip and ziperu
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

## Releasing

A `v*` tag runs [release.yml](../.github/workflows/release.yml): the source
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
