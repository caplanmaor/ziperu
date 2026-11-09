<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/caplanmaor/ziperu/main/docs/logo-dark.png">
    <img src="https://raw.githubusercontent.com/caplanmaor/ziperu/main/docs/logo.png" alt="ziperu" width="440">
  </picture>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/ziperu"><img src="https://img.shields.io/gem/v/ziperu" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/ziperu"><img src="https://img.shields.io/gem/dt/ziperu" alt="Downloads"></a>
  <a href="https://github.com/caplanmaor/ziperu/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://github.com/caplanmaor/ziperu/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

**A drop-in replacement for [rubyzip](https://github.com/rubyzip/rubyzip) with a Rust core.**

Same `Ziperu::File` / `Entry` / `InputStream` / `OutputStream` API, backed by
the [`zip`](https://github.com/zip-rs/zip2) crate through
[Magnus](https://github.com/matsadler/magnus). `require "zip"` aliases
`Zip = Ziperu`, so existing code runs unchanged.

- **Precompiled** for Linux (glibc and musl), macOS and Windows, Ruby 3.1 to 4.0. No toolchain, no runtime dependencies.
- **Fast**: entries inflate and deflate in Rust with the GVL released, the central directory is parsed once, unchanged entries are copied byte for byte on commit, and a commit that only adds entries appends them in place.
- **Reads everything**: Stored, Deflate, Deflate64, bzip2, zstd, LZMA, XZ, PPMd and the PKZIP 1.x methods; AES and ZipCrypto. Writes Deflate, Stored, bzip2, zstd, XZ, PPMd, AES and ZipCrypto.
- **Safe by default**: no entry inflates past its declared size, extraction never escapes the destination, symlinks are opt-in, and limits on entry count, entry size, total size and compression ratio can be set up front. [SECURITY.md](SECURITY.md) has the details.
- **Friendlier than rubyzip where it costs nothing**: a password on the archive (`File.open(path, password: ...)`), `add` from an IO, Pathname arguments, `File#verify`, progress callbacks, and errors that fail at the call site.
- **Checked against the field**: rubyzip's own test suite, differential fuzzing against Python's `zipfile` and rubyzip, interoperability runs with Info-ZIP, 7-Zip and Python, and the test suites of gems built on rubyzip (roo, caxlsx, rubyXL, docx, write_xlsx, sablon, gepub) run with ziperu in its place.

## Installation

In the Gemfile, in place of rubyzip:

```ruby
gem "ziperu"
```

Or on its own:

```bash
gem install ziperu
```

Bundler and `gem install` pick the precompiled gem for the platform
(`x86_64-linux-gnu`, `x86_64-linux-musl`, `aarch64-linux-gnu`,
`aarch64-linux-musl`, `arm-linux-musl`, `x86_64-darwin`, `arm64-darwin`,
`x64-mingw-ucrt`, `aarch64-mingw-ucrt`), each holding the extension for
Ruby 3.1 through 4.0. The glibc gems need RubyGems 3.3.22 or later (Ruby
3.1.4 ships it); the musl gems need `libgcc` (`apk add libgcc`, already in
the `ruby:3.2-alpine` and later images). Anywhere else the source gem
builds with Rust 1.88+.

JRuby and TruffleRuby are not supported: the core is a native extension
against the CRuby API. rubyzip remains the library for those.

## Quick start

```ruby
require "ziperu"   # or require "zip" for the Zip alias

Ziperu::File.open("archive.zip") do |zf|
  zf.each { |entry| puts "#{entry.name} (#{entry.size} bytes)" }
  puts zf.read("README.txt")
  zf.extract_all("out/")
end

Ziperu::File.open("new.zip", create: true) do |zf|
  zf.add("report.pdf", "tmp/report.pdf")
  zf.get_output_stream("notes.txt") { |io| io.puts "written at #{Time.now}" }
end

Ziperu::OutputStream.write_buffer(socket) do |zos|   # any IO; a pipe, socket or
  zos.put_next_entry("hello.txt")                    # response body is streamed,
  zos.write("hello")                                 # nothing buffered to the end
end

body = Ziperu::OutputStream.body do |zos|   # a Rack body: an Enumerator of
  zos.put_next_entry("export.csv")          # the archive's bytes, produced
  zos.write(csv)                            # as the server consumes them
end
[200, { "content-type" => "application/zip" }, body]

Ziperu::File.foreach("huge.zip") do |entry|   # one entry at a time, constant
  puts entry.name if entry.size > 1 << 30      # memory, however many there are
end

Ziperu::File.open("secret.zip", password: "s3cret") do |zf|   # AES or ZipCrypto
  zf.extract_all("out/")
  zf.add("upload.bin", StringIO.new(bytes))   # any IO, streamed on commit
end
```

## Cookbook

Zip a directory, unzip into one:

```ruby
Ziperu::File.add_recursive("site.zip", "public", threads: 8)   # what is under public/,
                                                               # compressed on 8 threads
Ziperu::File.open("site.zip") do |zf|
  zf.extract_all("restored/", threads: 8)   # never writes outside restored/
  zf.extract_all("restored/", on_exists: :overwrite, exclude: ["*.log"])
end
```

Build an archive in memory and hand it out, or take one in:

```ruby
bytes = Ziperu::OutputStream.write_buffer do |zos|
  zos.put_next_entry("report.csv")
  zos.write(csv)
end.string

Ziperu::File.open_buffer(params[:upload].read) do |zf|
  zf.each { |e| puts "#{e.name}: #{e.size} bytes" }
end
```

Stream a zip download without a temp file (Rack; in Rails, write to
`response.stream` inside `ActionController::Live` the same way):

```ruby
body = Ziperu::OutputStream.body do |zos|
  attachments.each do |att|
    zos.put_next_entry(att.filename)
    att.download { |chunk| zos.write(chunk) }
  end
end
[200, Ziperu::RailsStreaming.headers("attachments.zip"), body]   # require "ziperu/rails_streaming"

class ExportsController < ApplicationController           # in Rails: headers, body, no Live
  include Ziperu::RailsStreaming
  def show = zip_stream("export.zip") { |zos| zos.put_next_entry("a.csv"); zos.write(csv) }
end
```

Add files to an archive you already have (appended in place, the rest is
not rewritten), or replace one; or keep the original and write the
changed archive elsewhere:

```ruby
Ziperu::File.open("backup.zip") do |zf|
  zf.add("logs/today.log", "/var/log/app/today.log")
  zf.get_output_stream("manifest.json") { |io| io.write(manifest.to_json) }
end

Ziperu::File.open("backup.zip", write: "backup-2.zip") { |zf| zf.remove("old.log") }
Ziperu::File.open("backup.zip", write: false) { |zf| zf.read("manifest.json") }  # read-only
```

Pick one entry out of a large archive, or read it all as a stream:

```ruby
entry = Ziperu::File.foreach("huge.zip").find { |e| e.name.end_with?(".sig") }

Ziperu::InputStream.open(socket) do |zis|           # any IO, no seeking needed
  while (entry = zis.get_next_entry)
    process(entry.name, zis.read)
  end
end
```

Passwords, both ways:

```ruby
Ziperu::File.open("secret.zip", password: "s3cret") { |zf| zf.extract_all("out/") }

Ziperu::OutputStream.open("secret.zip", encrypter: Ziperu::AESEncrypter.new("s3cret")) do |zos|
  zos.put_next_entry("plan.txt")
  zos.write("...")
end
```

Keep hostile archives in check before reading a byte of them:

```ruby
Ziperu.max_entries = 10_000
Ziperu.max_total_size = 2 << 30          # 2 GiB uncompressed
Ziperu.max_compression_ratio = 1_000     # a zip bomb runs to a million
```

## Migrating from rubyzip

Change the Gemfile line and keep `require "zip"`: the `Zip` constant and
its classes (`Zip::File`, `Zip::Entry`, `Zip::Error`, ...) point at the
`Ziperu` ones. Class names read `Ziperu::...` in `inspect` output and
exception messages, which only matters to code comparing against the
string `"Zip::Entry"`.

> [!NOTE]
> rubyzip and ziperu cannot both own the `Zip` constant. While another gem
> still depends on rubyzip, use `require "ziperu"` and `Ziperu::` for the
> code you have switched and leave `Zip::` to rubyzip.

ziperu tracks the rubyzip 3.x API (`Ziperu::RUBYZIP_COMPAT_VERSION`), and
diverges on purpose where rubyzip is lax: `InputStream` reads through the
central directory so streamed archives work; every read stops at the
declared size (`Ziperu::EntrySizeError`); a CRC mismatch raises; names
flagged UTF-8 come back as UTF-8 strings; duplicate names in one
`OutputStream` raise. The full list, and what ziperu adds (archive limits,
`File#verify`, symlink entries, progress callbacks, more compression
methods), is in [docs/migrating.md](docs/migrating.md). What rubyzip's own
test suite makes of ziperu is in [COMPAT.md](COMPAT.md).

## Why

rubyzip is pure Ruby and does per-entry work in Ruby objects. ziperu
parses the central directory once in Rust and hands Ruby a flat metadata
dump, reads entries in large chunks, copies unchanged entries byte for
byte on `commit`, and releases the GVL while inflating from a file or
String buffer and while deflating, so other Ruby threads keep running.

`rake bench` runs [bench/bench.rb](bench/bench.rb) with both libraries
loaded. On one Windows machine (Ruby 3.4, median of 5):

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
libraries do in Ruby (ziperu parses their extra fields and timestamps only
when asked), and `extract_all` is bounded by file creation itself.

## Development

```bash
bundle install
bundle exec rake compile test   # build the extension, run the suite
bundle exec rake compat         # rubyzip's own test suite against ziperu
bundle exec rake fuzz           # differential fuzzing (TIME=180 for three minutes)
bundle exec rake bench          # the table above
```

Needs Ruby 3.1+ and Rust 1.88+. Windows setup, the fuzzer, the compat
run, the release pipeline and the code layout are described in
[docs/development.md](docs/development.md).

## Links

- [RubyGems](https://rubygems.org/gems/ziperu)
- [Changelog](CHANGELOG.md)
- [Migrating from rubyzip](docs/migrating.md): every deliberate difference, and what ziperu adds
- [rubyzip compatibility report](COMPAT.md)

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/caplanmaor/ziperu/issues). Run
`bundle exec rake compile test` before opening one; CI also runs clippy,
rubyzip's suite, the fuzzer and the interoperability check.

## License

The gem is available as open source under the terms of the
[MIT License](LICENSE.txt). The Ruby layer ports a good part of rubyzip
(the extra-field, filesystem, DOS time, entry-set and split code, and the
test fixtures under `test/data/rubyzip/`), which is BSD-2-Clause; its
notice is in [LICENSE-rubyzip.txt](LICENSE-rubyzip.txt) and the ported
files say so at the top.
