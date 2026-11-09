# Changelog

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
  (musl) where they could not load; the musl gems link the GCC unwinder
  statically and load on Alpine images without `libgcc`. A mismatched
  binary now raises a `LoadError` that says what to install.
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
