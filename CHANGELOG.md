# Changelog

## 0.2.0 (unreleased)

- `Ziperu::File.open(path, password: "...")` (or `decrypter:`) decrypts
  every entry for `read`, `get_input_stream`, `extract`, `extract_all` and
  `verify`, AES and ZipCrypto alike; `InputStream.open` takes `password:`
  too. rubyzip only decrypts through `InputStream` with a decrypter object.
- `Ziperu::File#add(name, io)` takes any object with `read` (a File,
  StringIO, Tempfile or pipe) as the source; it is streamed when the
  archive is written, and the entry reads and extracts from it before then.
- `InputStream` gains `getc`, `getbyte`, `readchar`, `readbyte`,
  `ungetbyte`, `each_byte`, `each_char`, `readpartial`, `read_nonblock`,
  `binmode` and the other IO bits; `ungetc` takes a String or a byte.
- `Entry#name=` and `#comment=` validate at the call site (a leading `/`,
  more than 65,535 bytes) instead of failing when the archive is written.
- `Ziperu::File.open_buffer` refuses a pipe or socket with an
  `ArgumentError` instead of blocking forever; `InputStream` reads those.
- Errors from the native `extract_all` name the path, as `Errno::*`.
- Walking a large archive with `InputStream` is about 2.5x faster (each
  entry read an 8 KiB buffer instead of 64 KiB; large reads bypass it).
- The committed COMPAT.md is now the baseline CI holds rubyzip's test
  suite to, and the test suites of roo, caxlsx, rubyXL, docx, write_xlsx,
  sablon and gepub run weekly with ziperu standing in for rubyzip. Running
  them turned up three gaps, now closed: the rubyzip 2.x call forms
  `Zip::File.open(path, Zip::File::CREATE)` and `Zip::File.new(path, true)`
  (libraries that branch on `Zip::VERSION >= 3` take their 2.x path with
  ziperu), `Zip::CentralDirectory.new.read_from_stream(io)` (roo), and
  `Entry#calculate_local_header_size` / `#local_entry_offset` (roo again).

## 0.1.2

Fixes from a review-and-testing round against rubyzip 3.7, Info-ZIP, 7-Zip
and Python's `zipfile`, on Linux (glibc and musl), macOS and Windows.

- ZipCrypto entries were undecryptable after any `Ziperu::File` commit
  that copied them (the copy dropped general purpose bit 3, which the
  check byte depends on); they are now copied byte for byte under their
  own headers, and a rename or chmod is carried along.
- ZipCrypto entries now end with the data descriptor their bit 3
  announces, so Info-ZIP's `unzip` no longer rejects such archives as
  "overlapped components" (Python, 7-Zip and ziperu read both forms).
  The archive's compressed sizes are also right in the local header.
- The glibc Linux gems are published as `x86_64-linux-gnu` and
  `aarch64-linux-gnu`, so RubyGems no longer installs them on Alpine
  (musl) where they could not load. The musl gems need Alpine's `libgcc`
  package (in the `ruby:3.2-alpine` and later images); a mismatched binary
  or that missing library now raises a `LoadError` that says what to
  install.
- `Pathname` arguments to `Ziperu::File.open`, `InputStream.open`,
  `count_entries` and `rename` work (they were read in text mode, which
  broke on Windows).
- A commit that fails (a source file gone, an encrypted entry edited)
  leaves the pending changes in place, so it can be retried; before, the
  entries forgot their edits and pointed into the discarded temp file.
- `get_output_stream` on an existing name keeps the entry's position in
  the archive, as rubyzip does (EPUB's `mimetype` must come first).
- `extract`, `extract_all` and `verify` of an entry replaced or added
  from disk and not yet committed use the new data.
- Edits made directly to an entry's `extra` fields are committed.
- Rewriting an archive into the `File` it is read from
  (`open_buffer(File.open(path, "r+b"))`) no longer corrupts it, and a
  rewrite that shrinks the archive truncates the IO.
- `Ziperu::InputStream` over a truncated or damaged archive raises
  instead of yielding no entries; something that is not an archive at all
  still yields none. An `offset:` that is not an entry's raises.
- A second entry under one name in an `OutputStream` raises
  `EntryExistsError` (was `Ziperu::Error`); writing data to a directory
  entry raises with the entry's name.
- `Entry#get_raw_input_stream` is back.
- An entry declared empty whose data is not is reported as
  `EntrySizeError` on every read path, not only `File#read`.
- An mtime the OS cannot represent (an NTFS extra field far in the
  future) is skipped on extraction instead of aborting the interpreter.

## 0.1.1

First release, as far as rubygems.org is concerned: 0.1.0 was tagged but
its precompiled gems were built for Ruby 3.3 and later only, so it was
never published. The native gems now cover every Ruby the gemspec
promises (3.1 through 4.0).

## 0.1.0

Not published.

- rubyzip 3.x API (`Ziperu::File`, `Entry`, `InputStream`, `OutputStream`,
  `FileSystem`) on a Rust core; `require "zip"` aliases `Zip = Ziperu`.
- Reads Stored, Deflate, Deflate64, bzip2, zstd, LZMA, XZ, PPMd and the
  PKZIP 1.x methods; writes Stored, Deflate, bzip2 and zstd; AES and
  ZipCrypto encryption both ways.
- Precompiled gems for Linux, macOS and Windows; no toolchain needed.
- Beyond rubyzip: archive limits (`Ziperu.max_entries`,
  `Ziperu.max_total_size`), `File#verify`, symlink entries with opt-in
  extraction, progress callbacks, native `extract_all`, streaming reads
  and writes through any IO, UTF-8 names when the archive flags them.
- See the README for the deliberate differences from rubyzip.
