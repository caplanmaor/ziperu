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

ziperu 0.2.3 on GitHub's Linux runners (Ruby 3.4, median of 5), against
rubyzip 3.7.0:

| scenario | rubyzip | ziperu | speedup |
|---|---:|---:|---:|
| read 1000 x 8 KB deflated entries | 110 ms | 18 ms | 6.1x |
| inflate one 64 MB entry | 112 ms | 38 ms | 3.0x |
| open and list 10000 entries | 184 ms | 75 ms | 2.5x |
| deflate one 64 MB entry | 323 ms | 101 ms | 3.2x |
| `get_output_stream` 1000 entries and commit | 310 ms | 84 ms | 3.7x |
| append one entry to a 10000-entry archive | 1.16 s | 148 ms | 7.8x |
| add 1000 files from disk (`threads: 4`) | 348 ms | 89 ms | 3.9x |

macOS and Windows, every scenario, and which calls release the GVL (what
Puma users ask about) are in [docs/benchmarks.md](docs/benchmarks.md).

- **Precompiled** for Linux (glibc and musl), macOS and Windows, Ruby 3.1 to 4.0. No toolchain, no runtime dependencies.
- **Fast**: entries inflate and deflate in Rust with the GVL released, the central directory is parsed once, unchanged entries are copied byte for byte on commit, and a commit that only adds entries appends them in place.
- **Reads everything**: Stored, Deflate, Deflate64, bzip2, zstd, LZMA, XZ, PPMd and the PKZIP 1.x methods; AES and ZipCrypto. Writes Deflate, Stored, bzip2, zstd, XZ, PPMd, AES and ZipCrypto.
- **Safe by default**: no entry inflates past its declared size, extraction skips names that resolve outside the destination and never writes through a link already on disk, symlinks are opt-in, and limits on entry count, entry size, total size and compression ratio can be set up front. [SECURITY.md](SECURITY.md) has the details.
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

Precompiled gems ship for Linux, macOS and Windows; see
[Platforms](#platforms) for the details.

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

# A pipe or an upload read in one pass, an entry's worth of memory at a
# time, rather than taken in whole to reach the central directory:
Ziperu::InputStream.open(s3_object.body, streaming: true) do |zis|
  while (entry = zis.get_next_entry)
    zis.each_line { |line| ... }
  end
end
```

Read an archive in place on a server, without downloading it: only the
central directory and the entries read are fetched, with HTTP Range
requests (S3, GCS, a CDN; or a block that returns byte ranges):

```ruby
io = Ziperu::RemoteIO.new(url)   # "https://example.com/dataset.zip"
Ziperu::File.open_buffer(io, write: false) do |zf|
  zf.extract("docs/guide.txt", "guide.txt")   # a few requests, not 5 GB
end
```

Leave out an entry whose data could not be had, and go on with the rest
(a download that failed half-way through a streamed zip, say):

```ruby
body = Ziperu::OutputStream.body do |zos|
  files.each do |name, url|
    zos.put_next_entry(name)
    begin
      fetch(url) { |chunk| zos << chunk }
    rescue Net::HTTPError
      zos.rollback_entry   # before its first byte on a stream; any time on a file
    end
  end
end
[200, { "content-type" => "application/zip" }, body]
```

Seek about in a Stored entry, for readers that want random access (a PDF
stored in an archive):

```ruby
Ziperu::File.open("scans.zip") do |zf|
  zf.get_input_stream("scan.pdf") { |io| io.seek(-1024, IO::SEEK_END); io.read(1024) }
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

Or for one archive only, leaving the globals alone; every `Ziperu.*`
setting is a keyword of the same name on `File`, `InputStream` and
`OutputStream`:

```ruby
Ziperu::File.open(upload, max_entries: 1_000, max_total_size: 1 << 30) { |zip| ... }
Ziperu::OutputStream.open("out.zip", write_extended_timestamps: true) { |zos| ... }
```

## Migrating from rubyzip

Change the Gemfile line and keep `require "zip"`: the `Zip` constant and
its classes (`Zip::File`, `Zip::Entry`, `Zip::Error`, ...) point at the
`Ziperu` ones. Class names read `Ziperu::...` in `inspect` output and
exception messages, which only matters to code comparing against the
string `"Zip::Entry"`.

Gems that depend on rubyzip (roo, caxlsx, rubyXL and the like) still
pull it in, but under Bundler ziperu's `zip.rb` comes first on the load
path, so `require "zip"` loads ziperu and those gems run on it; rubyzip
stays installed and unused. Checked with Bundler 2.3, 2.5 and 4.0, in
either Gemfile order.

Without Bundler, RubyGems loads whichever gem asks for `zip` first. To
have ziperu answer for rubyzip there too, require this before anything
else loads it (the top of a script, or `config/boot.rb`):

```ruby
require "ziperu/replace_rubyzip"   # every require "zip" / "zip/..." loads ziperu
```

It raises if rubyzip is already loaded, rather than mix the two. Short of
that, use `require "ziperu"` and `Ziperu::` for your own code and leave
`Zip::` to rubyzip.

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
String buffer and while deflating to a file, so other Ruby threads keep running.

## Platforms

- **Ruby 3.3 to 4.0** are supported and tested on Linux, macOS and Windows.
  3.1 and 3.2 still get binaries, best effort.
- **Precompiled** for x86_64 and aarch64 Linux (glibc and musl; musl needs
  `libgcc`), Intel and Apple Silicon macOS, and x64 and arm64 Windows.
  Elsewhere the source gem builds with Rust 1.88+.
- **CRuby only**: on JRuby or TruffleRuby, use rubyzip.

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
