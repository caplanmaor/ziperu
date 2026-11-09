# Changelog

## 0.1.0

First release.

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
