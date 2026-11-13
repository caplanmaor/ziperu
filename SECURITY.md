# Security

## Reporting

Report a vulnerability through GitHub's private vulnerability reporting
on this repository ("Report a vulnerability" under the Security tab), not
in a public issue. You will hear back within a week. Fixes go out as a
patch release of the latest minor version with a note in CHANGELOG.md.

## What ziperu guards against

Archives are untrusted input. ziperu treats them that way by default,
where rubyzip leaves most of it to the caller:

- **Path traversal.** `extract` and `extract_all` resolve every name
  against the destination and skip, with a warning, any that would land
  outside it (`..`, absolute paths, drive letters, UNC shares). The check
  is done on the name a reader would use, so a Unicode Path extra field
  that renames an entry cannot be used to escape either. The native
  extractor applies the same check on every thread.
- **Links on disk.** Below the destination, extraction does not write
  through a link that is already there (a symlink, or a junction on
  Windows): an entry with one on the way, or at its own path, is skipped
  with a warning, whatever `on_exists:` says. The destination itself may
  be a link.
- **Symlink entries.** Extraction never creates a link unless asked to
  (`symlinks: :create`), and then only when its target resolves inside
  the destination and has no `..` after a name (which a link could
  redirect); links are created after everything else.
- **Remote archives.** `RemoteIO` fetches http and https URLs only,
  sends its `headers:` only to the origin of the URL it was given (not
  to another host a redirect leads to, unless `forward_headers: true`),
  and refuses a redirect from https to http. A server that ignores Range
  cannot make it hold more than `max_full_download:` bytes (64 MB), a
  ranged answer must be for the range asked, and a file that changes
  between requests (by ETag or Last-Modified) raises.
- **Failed writes.** A file replaced during extraction, an archive
  rewritten on commit, and a `write: path` target are all written
  beside their path and renamed into place once complete, so a failure
  leaves what was there.
- **Lying headers.** No entry inflates past its declared size
  (`Ziperu::EntrySizeError`); a CRC mismatch raises; the sizes and CRC
  come from the central directory, never from a local header or data
  descriptor alone, and the central directory's name is the one every
  check and lookup uses.
- **Zip bombs and resource limits.** `Ziperu.max_entries`,
  `Ziperu.max_total_size`, `Ziperu.max_entry_size` and
  `Ziperu.max_compression_ratio` make `File.open` and `InputStream.open`
  raise `Ziperu::LimitError` before any entry is read. They are off by
  default; set them in an application that accepts uploads.
- **Duplicate names.** Several records under one name are all listed and
  readable, but a lookup by name finds the one a reader would, and only
  that one is written back. Writing two entries with the same name to one
  stream raises.
- **Windows names.** `extract_all(dir, sanitize: :windows)` rewrites names
  Windows refuses, so an archive cannot make extraction fail halfway on a
  reserved device name.
- **Memory safety.** The core is Rust (the `zip` crate, 9.x) with the
  unsafe blocks confined to the Ruby boundary and documented; the suite
  runs under GC stress, valgrind (ruby_memcheck) and a resident-size
  growth check in CI, and the parsers are fuzzed differentially against
  Python's zipfile and rubyzip.

## What it does not

- **A destination someone else can write to while you extract**, except
  in one case. On Linux 5.6 and later, the native `extract_all` opens the
  directory of every file it writes with `openat2(RESOLVE_BENEATH |
  RESOLVE_NO_SYMLINKS)`, so the kernel refuses a link swapped in at any
  point. It creates, replaces and stamps files through that handle, and
  stamps directories through one too. Even there, a directory it creates
  can still land through a swapped link, as an empty directory. Everywhere
  else the link check is made just before each path is used, so a local
  user who swaps a directory for a link in between can still redirect a
  write. That covers Windows, macOS, older kernels, sandboxes that refuse
  the call, and the Ruby per-entry path (encrypted entries, symlinks, an
  `extract_all` block). Extract into a directory only you can write to
  (a fresh `Dir.mktmpdir`, say) and move the result.
- **ZipCrypto** is written and read because tools still expect it, but it
  is a broken cipher: a few bytes of known plaintext recover the keys.
  Use `AESEncrypter` for anything that matters.
- **Decompression time.** The limits bound the output; a hostile archive
  can still take the CPU time its declared sizes allow. Bound the
  declared total and run extraction in a worker with a timeout.
- **Archives you write** carry whatever names and contents you give
  them; `Entry#name=` only refuses a leading `/` and an overlong name.
