# Migrating from rubyzip

The library lives in the `Ziperu` namespace. `require "zip"` loads it and
sets `Zip = Ziperu`, so existing code keeps working with a one-line change
to the Gemfile (`gem "ziperu"` in place of `gem "rubyzip"`).

If rubyzip has to stay installed during the migration (another gem depends
on it, say), the two cannot share the `Zip` name: `require "zip"` raises a
`LoadError` naming the file that already defined `Zip`. Use `require "ziperu"`
and `Ziperu::` for the code you have switched, and leave `Zip::` to rubyzip
until it goes. Exception classes follow the namespace, so rescue
`Ziperu::Error` (or `Zip::Error`, which is the same class once aliased).

## Deliberate differences from rubyzip

- `Ziperu::InputStream` locates entries through the central directory instead
  of walking local headers, so archives written in streaming mode (general
  purpose bit 3, e.g. by macOS Archive Utility) read normally instead of
  raising `Ziperu::StreamingError`.
- Every read path stops at the entry's declared size, so a header that lies
  can't inflate into a zip bomb; a `Ziperu::EntrySizeError` is raised instead.
  (rubyzip only checks this in `extract`, not in `InputStream`.)
  `Ziperu.validate_entry_sizes = false` restores rubyzip's behaviour of
  extracting the full data with a warning.
- ZipCrypto ("traditional") encryption is written by ziperu itself (the
  crate keeps that broken cipher read-only), with the header layout
  rubyzip produces (general purpose bits 0 and 3 set, the check byte from
  the DOS time) plus the data descriptor bit 3 announces, which rubyzip
  omits and Info-ZIP's `unzip` insists on. Only Stored and Deflate entries
  can be encrypted this way, and a committed `Ziperu::File` never
  encrypts; existing ZipCrypto entries are copied byte for byte. Their
  headers are patched once the data is written, so `write_buffer` to an IO
  that cannot seek builds such an archive in memory first, and
  `copy_raw_entry` of a ZipCrypto entry into one raises `ArgumentError`.
  `AESEncrypter` is the better choice wherever the consumer can open AES.
- Zip64 is on by default, as in rubyzip 3: an entry whose size is not
  known when it is written (a `put_next_entry` without a size) or is
  4 GiB or more gets a zip64 extra field, version 4.5, and 64-bit sizes
  in its data descriptor; `Ziperu.write_zip64_support = false` or
  `suppress_extra_fields: :zip64` turns that off (`suppress_extra_fields:
  true` drops every extra field), and an entry that then grows past
  4 GiB raises `Ziperu::Error`. The central directory's own zip64 records
  are written whenever the archive needs them (over 4 GiB, or 65,535
  entries), whatever the setting; everything reads either way.
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
  `Ziperu::EntryExistsError`; rubyzip writes both and the last one wins.
  Writing data to a directory entry raises `Ziperu::Error`; rubyzip
  stores it.
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
- Several records with the same name in one archive (Python's `zipfile`
  writes such archives, with a warning): `Ziperu::File` lists every record
  and each reads its own data, where rubyzip keeps only the last. A lookup
  by name (`find_entry`, `read`, `extract_all`) finds the last, as in
  rubyzip, and so does a commit, which writes one record per name; a
  shadowed record given a new name before the commit is written afresh.
  `Ziperu::InputStream` yields every record, as rubyzip's does.
- `Ziperu::InputStream` over something that is not a zip archive at all
  returns `nil` from the first `get_next_entry`, as rubyzip does. One over
  an archive whose central directory is cut off or damaged raises
  `Ziperu::Error`, where rubyzip walks the local headers and yields what
  it can; `Ziperu::File.open` raises in both.
- `Zip::VERSION` is ziperu's own version, not rubyzip's. Code that gates on
  it (`Gem::Version.new(Zip::VERSION) >= "3"`) takes its rubyzip 2.x path,
  so ziperu accepts the 2.x call forms alongside the 3.x keywords:
  `Zip::File.open(path, Zip::File::CREATE)` and `Zip::File.new(path,
  create, buffer, options)`, `Zip::File.add_buffer { |zf| }`,
  `get_output_stream(name, permissions, comment, ...)`, `Zip::Entry.new(zip,
  name, comment, extra, ...)`, `Zip::InputStream.open(io, offset,
  decrypter)`, `Zip::OutputStream.new(io, stream, encrypter)` and
  `write_buffer(io, encrypter)`, `Zip::GPFBit3Error`, and the rubyzip 1.x
  error names (`Zip::ZipError`, `Zip::ZipEntryExistsError`, ...). New code
  should use the keywords and check `Ziperu::RUBYZIP_COMPAT_VERSION`.
- An open `Ziperu::File` holds its file open until `close`. On Windows a
  commit by *another* `Ziperu::File` on the same path therefore moves the
  old archive aside before putting the new one in place, and removes it
  once nothing holds it; the first instance keeps reading the old bytes,
  as it would on Unix. rubyzip closes the file between operations.
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

## Beyond rubyzip

Everything here is additive: code that does not use it behaves as above.

- **Non-destructive open.** `Ziperu::File.open(path, write: false)` is
  read-only: any change raises, and `close` never touches the file, where
  rubyzip's `open` rewrites the archive on close (and has lost content
  that way). `write: "other.zip"` writes the changes to a new archive and
  leaves the one opened as it was.
- **A password on the archive.** `Ziperu::File.open(path, password: "...")`
  (or `decrypter:`) makes `read`, `get_input_stream`, `extract`,
  `extract_all` and `verify` decrypt every entry, AES and ZipCrypto alike;
  `InputStream.open` takes `password:` too. rubyzip decrypts only through
  `InputStream`, given a decrypter object.
- **`add` from an IO.** `zf.add("name", io)` takes any object with `read`
  (a File, StringIO, Tempfile or pipe) and streams it when the archive is
  written; the entry reads and extracts from it before then.
- **Errors at the call site.** `Entry#name=` and `#comment=` validate
  (leading `/`, more than 65,535 bytes) when called, and
  `File.open_buffer` refuses a pipe or socket with an `ArgumentError`,
  where rubyzip blocks or writes a corrupt header.
- **Archive limits.** `Ziperu.max_entries`, `Ziperu.max_total_size`
  (declared uncompressed bytes) and `Ziperu.max_compression_ratio` (the
  highest ratio any entry declares; a zip bomb runs to a million or
  more, a file of zeros to about a thousand) make `Ziperu::File.open` and
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
  the archive in memory. `write_buffer` takes an IO that cannot seek (a
  pipe, a socket, a Rack response body, an S3 multipart upload): each
  entry goes out as it is written, with its sizes in a data descriptor
  after the data, which every zip reader since PKZIP 2.0 understands;
  rubyzip needs a seekable IO there.
- **Appending in place.** When a `Ziperu::File` commit only adds entries,
  they are appended after the ones already there (plus a new central
  directory) rather than the archive being rewritten through a temporary
  file, as rubyzip does for every commit. A failure in the middle puts
  the archive back as it was; `Ziperu.append_in_place = false` keeps
  rubyzip's rewrite. `Ziperu::OutputStream.open(path, append: true)`
  appends directly.
- **Walking a huge archive.** `Ziperu::File.foreach(path) { |entry| ... }`
  yields the entries one at a time without listing them all first, in
  constant memory, each readable while the block runs; without a block it
  is an Enumerator (`foreach(path).find { ... }` stops at the first
  match). rubyzip's `foreach` opens the whole archive.
- **A streaming HTTP response body.** `Ziperu::OutputStream.body { |zos| ... }`
  is an Enumerator of the archive's bytes in chunks, produced as they are
  consumed: hand it to Rack (or anything with `each`) as the body and the
  download starts with the first entry, with no temp file and no
  `Content-Length`. In Rails, `write_buffer(response.stream)` inside
  `ActionController::Live` does the same.
