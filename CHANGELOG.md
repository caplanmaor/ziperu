# Changelog

## Unreleased

- Per-archive settings: every `Ziperu.*` setting (the limits,
  `validate_entry_sizes`, `sort_entries`, `case_insensitive_match`,
  `write_zip64_support`, `write_extended_timestamps`, `unicode_names`,
  `source_date_epoch`, `append_in_place`, `on_exists_proc` and the rest)
  is also a keyword of the same name on `Ziperu::File.new` / `open` /
  `open_buffer` / `foreach`, `Ziperu::InputStream` and
  `Ziperu::OutputStream`. One given that way holds for that archive
  alone, so two archives in one process can differ; the others keep
  following the globals. `Ziperu::File#settings` shows what an archive
  consults.
- Docs: one convention for the API's edges. Internals are `# :nodoc:`
  (the eight `@api private` tags became that) and may change in any
  release; what ziperu adds to rubyzip's API carries the line `Not in
  rubyzip.` in its comment, so `grep -rn "Not in rubyzip" lib` lists
  the additions.
- A stated Ruby policy (README): 3.3 to 4.0 supported and tested on
  every platform, 3.1 and 3.2 best effort, ruby-head watched by a
  nightly, non-blocking CI job. CI now runs the suite on 4.0 too.
- Every Ruby example in the README runs as a test.
- The release workflow can push to rubygems.org itself through trusted
  publishing (OIDC, no API key), native gems before the source gem; it
  is off until the repository variable `RUBYGEMS_TRUSTED_PUBLISHING` is
  set (see docs/development.md).
- Releases build a committed snapshot of platforms and Rubies
  (`.github/release-matrix.json`) rather than upstream's list on the day
  of the tag, so a patch release cannot silently gain or lose one; a
  weekly check says when the snapshot has fallen behind.
- Internal: an entry's data source (none, an archive record, a path, an
  IO) is one `Entry::Source` object instead of four instance variables;
  no change in behaviour.

## 0.2.0 (2026-11-09)

- XZ and PPMd on write (`Entry::XZ`, `Entry::PPMD`), alongside bzip2 and
  zstd; 7-Zip reads all four. `add_recursive(dir, symlinks: :store)`
  adds symlinks as link entries (`zip -y`) instead of skipping them.
- `Ziperu.max_entry_size`, alongside the other limits; a SECURITY.md
  stating what is guarded against and what is not; and tests for the
  hostile shapes the zip crate's 9.1.x hardening is for (a Unicode Path
  field renaming an entry out of the destination, a name that differs
  between the headers, a file through a symlink, duplicate names, a
  declared size smaller than the data).
- Zip64 per entry: `put_next_entry(name, zip64: true | false)`,
  `get_output_stream(name, zip64: ...)` and `Entry.new(..., zip64: ...)`
  decide for one entry, where before only the global
  `Ziperu.write_zip64_support` and `suppress_extra_fields: :zip64` did;
  `Ziperu.write_zip64_support = :always` writes every file entry
  zip64-ready, for testing readers.
- Reproducible archives: with `SOURCE_DATE_EPOCH` in the environment (or
  `Ziperu.source_date_epoch` set), every new entry's timestamp is that
  instant in UTC (a source file's own mtime wins when earlier) and the
  "made by" system is Unix on every platform, so the same input gives
  the same bytes on every run and machine. `add_recursive` already walks
  directories in sorted order.
- Names in other encodings. `Ziperu.unicode_names = true` now really
  sets the language encoding flag on every entry (the native writer had
  no way to, so the setting was lost; a non-ASCII UTF-8 name is flagged
  regardless). Info-ZIP's Unicode Path extra field, which Info-ZIP on
  Windows writes beside a code-page name, is honoured on read.
  `Ziperu::File.open(path, metadata_encoding: "Shift_JIS")` (also on
  `open_buffer`, `foreach` and `InputStream.open`) transcodes names and
  comments stored in another encoding to UTF-8. Comments come back as
  the stored bytes (the native core used to decode them as CP437).
  `Ziperu.write_extended_timestamps = true` gives every new entry
  Info-ZIP's extended timestamp (UTC, to the second), as Info-ZIP and
  7-Zip write it; off by default, since an extra field changes the bytes
  (an EPUB's first entry must have none). An entry rewritten from an
  archive keeps exactly the fields it had.
- Streamed downloads: `Ziperu::OutputStream.estimated_size { |e| ... }`
  works out, to the byte, how large a streamed archive of stored (or
  deflated-with-known-size) entries will be, for a `Content-Length`;
  `OutputStream#bytes_written` reports progress on a stream;
  `require "ziperu/rails_streaming"` gives controllers `zip_stream(name,
  size:) { |zos| ... }` (headers plus an Enumerator body, no
  `ActionController::Live`) and Rack apps `Ziperu::RailsStreaming.headers`.
- `extract_all` takes the policies `unzip` has: `on_exists: :raise |
  :overwrite | :skip` (also on `extract`), `exclude: ["*.log", /re/]`,
  `junk_paths: true`, and `sanitize: :windows` for names Windows refuses.
  `Ziperu.on_exists_proc = true` now also takes the native fast path.
- Parallel compression and extraction. `OutputStream#add_files(files,
  threads: n)` compresses files from disk on `n` threads (the crate's
  rayon-backed append; entries come out in the order given);
  `Ziperu::File.open(path, threads: n)` and `File.add_recursive(zip, dir,
  threads: n)` do the same for a commit's additions from disk.
  `extract_all(dir, threads: n)` inflates and writes the files on `n`
  threads, each reading the archive through its own handle. Both default
  to one thread, as before.
- `Ziperu::File.open(path, write: false)` opens an archive read-only:
  any change raises and `close` never writes, where rubyzip rewrites the
  archive on close. `write: "other.zip"` writes the changes to a new
  archive and leaves the one opened as it was.
- `OutputStream.write_buffer(io)` and `Ziperu::File#write_buffer(io)`
  stream to an IO that cannot seek (a pipe, a socket, a response body, an
  upload): each entry goes out as it is written, with its sizes in a data
  descriptor after the data, and nothing is held back to the end. rubyzip
  needs a seekable IO there. The entries still learn their offsets, sizes
  and CRCs. ZipCrypto entries have their headers patched at the end, so an
  archive holding them is built in memory first, and copying one raw into
  a stream raises `ArgumentError`.
- `Ziperu::OutputStream.body { |zos| ... }` returns the archive as an
  Enumerator of chunks, produced on demand: a Rack response body for a
  streamed download, with no temp file.
- Large archives: `Ziperu::File.foreach(path) { |entry| ... }` walks the
  entries one at a time, in constant memory, with each entry readable as
  it goes by (and is an Enumerator without a block, so `first`, `find`
  and `lazy` work); `Ziperu::File.open` on an archive of 200,000 entries
  takes half the time and under half the memory it did (the listing is
  handed over one entry at a time, extra fields and timestamps are parsed
  on first use, entries without a comment share one empty String); an
  `InputStream` walk fetches entries in batches and is about a third
  faster. An entry's invalid DOS timestamp is parsed when its `time` is
  first asked for, unless `Ziperu.warn_invalid_date` is set, in which
  case the warning still comes when the archive is opened.
- Adding entries to an archive on disk appends them in place: a commit
  whose only changes are additions (`add`, `get_output_stream` on a new
  name, `mkdir`) writes the new entries after the existing ones and a new
  central directory, instead of rewriting the whole archive through a
  temporary file, so adding one file to a large archive costs that file.
  A failure in the middle puts the archive back as it was.
  `Ziperu.append_in_place = false` restores the rewrite;
  `OutputStream.open(path, append: true)` appends directly.
- `Ziperu.max_compression_ratio`: an archive declaring an entry with a
  higher uncompressed-to-compressed ratio raises `Ziperu::LimitError` on
  open, like the other limits; the zip bomb check that `max_total_size`
  alone does not give.
- The rest of rubyzip 2.x's call forms, for libraries that take their
  2.x path because `Zip::VERSION` is ziperu's: `Zip::File.new(path,
  create, buffer, options)` and `Zip::File.open(path, create, options)`,
  `Zip::File.add_buffer`, positional `get_output_stream(name,
  permissions, ...)` and `Zip::Entry.new(zip, name, comment, ...)`,
  `Zip::InputStream.new(io, offset, decrypter)`, `Zip::OutputStream.new(io,
  stream, encrypter)`, `OutputStream.open(path, encrypter)` and
  `write_buffer(io, encrypter)`, and the rubyzip 1.x error names
  (`Zip::ZipError` and friends) that 3.0 removed.
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
