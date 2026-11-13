# Development

Needs Ruby >= 3.1 and Rust >= 1.88.

```
bundle install
bundle exec rake compile test
```

`bundle exec rake rubocop` lints the Ruby code; it needs the optional
`lint` group (`bundle config set with lint`, then `bundle install`). The
Rust code is checked with `cargo fmt --all --check` and
`cargo clippy --all-targets -- -D warnings`. CI runs all three.

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

The Rust layer is not thin. Beyond the `zip` crate (which has its own
fuzzing) it holds a raw central-directory parser, a streaming reader with
its own descriptor handling, a writer with ZipCrypto and in-place append,
and the native extractor's path checks (`extract.rs`, `place.rs`). Most
of it is reachable only through the Ruby API, which is what the
differential fuzzer drives. The pure pieces have seeded property tests
under `cargo test`: the path check, the zip64 extra field parser and the
ZipCrypto round trip. The Linux `openat2` containment is tested there
against a real swapped-in link. A cargo-fuzz harness for the raw parsers
would be the next step.

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
loaded side by side (`RUNS=5`, `QUICK=1` for small sizes). Labelling a pull
request `bench`, or running the Bench workflow from the Actions tab, runs
it on Linux, macOS and Windows and puts each table in the job summary.
[benchmarks.md](benchmarks.md) is the published page: update it from such
a run, naming the run, when a release changes the numbers.

## Releasing

A `v*` tag runs [release.yml](../.github/workflows/release.yml): the source
gem plus one precompiled gem per platform (built with
[oxidize-rb/actions/cross-gem](https://github.com/oxidize-rb/actions), each
holding the extension for every stable Ruby), a smoke test that installs
the right gem on Linux, macOS and Windows without a Rust toolchain, and a
draft GitHub release with the gems attached. With trusted publishing
set up (below) the `publish` job then pushes them to rubygems.org, native
gems first and the source gem last; without it, pushing is a manual
`gem push` of each gem in the draft. Either way, publish the draft
release afterwards.

Setting up trusted publishing, once:

1. On rubygems.org, ziperu's **Trusted publishers** page: add a GitHub
   Actions publisher for `caplanmaor/ziperu`, workflow `release.yml`,
   environment `rubygems`.
2. In the GitHub repository's settings, **Environments**: create
   `rubygems` (optionally with yourself as a required reviewer, so each
   push waits for a click), and under **Variables** set
   `RUBYGEMS_TRUSTED_PUBLISHING` to `true`.

After that, no API key is needed, and the one in
`~/.local/share/gem/credentials` can be revoked.

Which platforms and Rubies a release builds is a committed snapshot,
[.github/release-matrix.json](../.github/release-matrix.json), so a
patch release ships exactly what the release before it did. The weekly
[release-matrix.yml](../.github/workflows/release-matrix.yml) run fails
when upstream offers something the snapshot lacks (a new Ruby, say) or
has dropped something it has. To adopt the change, in a minor release:

    CI_DATA='<the fetch-ci-data JSON from that run>' ruby .github/scripts/release_matrix.rb --write

and commit the file.

## API conventions

Three kinds of method, told apart in the source:

- **rubyzip's API.** A public method with no marker has rubyzip's name,
  arguments and behaviour; `docs/migrating.md` lists the deliberate
  differences. It changes only when rubyzip's does.
- **ziperu's additions.** A public method, class or setting rubyzip does
  not have carries the line `Not in rubyzip.` at the end of its comment
  (`grep -rn "Not in rubyzip" lib` lists them). Keywords added to a
  rubyzip method (`password:`, `write:`, `threads:`, `progress:`,
  `on_exists:` and so on) are described in that method's comment. These
  follow semantic versioning like the rest.
- **Internals.** Anything marked `# :nodoc:` (and everything under
  `Ziperu::Native` and `Entry::Source`) is for the library's own classes
  to call each other with, even where Ruby leaves it public. It can
  change in any release.

## Layout

- `ext/ziperu/` — the Rust extension (`Ziperu::Native::*`): a few primitive,
  positional-argument methods.
- `lib/ziperu/` — the rubyzip-shaped API in Ruby: kwargs, blocks, `Enumerable`,
  the error hierarchy, extra-field parsing.
- `test/` — minitest; `test/data/` holds fixture archives.
- `fuzz/` — the differential fuzzer and its Python and rubyzip oracles.
- `bench/` — the rubyzip comparison benchmark.
