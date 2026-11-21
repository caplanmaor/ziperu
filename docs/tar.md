# Tar archives

ziperu reads, extracts and writes tar archives: plain `.tar`, and tar
compressed with gzip, zstd, xz or bzip2. Nothing here is in rubyzip; the
code lives under `Ziperu::Tar`.

```ruby
Ziperu.extract(upload, "out", **Ziperu::Limits::UPLOAD)   # a zip or a tar

Ziperu::Tar.extract_all("release.tar.gz", "src", strip_components: 1)

Ziperu::Tar.foreach("logs.tar.zst") do |entry|
  process(entry.name, entry.read) if entry.file?
end

Ziperu::Tar.create("backup.tar.zst") { |tar| tar.add_recursive("data") }
```

## What is read

- **Formats:** v7, ustar, GNU and PAX, including GNU long names and PAX
  extended headers (`path`, `linkpath`, `size`, `mtime`, `uid`, `gid`,
  `uname`, `gname`). PAX global headers are read past.
- **Compression:** none, gzip (several members end to end count as one
  stream), zstd, xz and bzip2. Which one is told from the first bytes of
  the archive, never from its name: a `.tar` that is really zstd reads,
  and so does an upload with no name at all.
- **Sources:** a path (a String or a Pathname), or any object with
  `read(length)`: a File, a StringIO, a socket, a pipe, an HTTP response
  body. A tar archive has no index, so it is read front to back and
  nothing needs to seek.
- **Not read:** sparse files (GNU `S` entries and the PAX `GNU.sparse`
  forms) and multi-volume archives raise `Ziperu::Error`. Extended
  attributes and ACLs in PAX headers are ignored.

Tools checked in CI: GNU tar, bsdtar (libarchive), Python's `tarfile`
and 7-Zip, in each format they write.

## Reading entries

`Ziperu::Tar.foreach(path_or_io, **limits)` yields one entry at a time in
constant memory. Without a block it returns an Enumerator.

```ruby
Ziperu::Tar.foreach(io) do |entry|
  entry.name          # as the archive has it: may be absolute or hold ".."
  entry.type          # :file, :directory, :symlink, :hardlink,
                      # :character_device, :block_device, :fifo or :other
  entry.size          # bytes of data; 0 for anything but a file
  entry.mode          # permission bits
  entry.mtime         # a Time, to the nanosecond where the archive has it
  entry.link_target   # for a symlink or hard link
  entry.uid; entry.gid; entry.uname; entry.gname

  entry.read          # all of the data
  entry.read(4096)    # or a piece at a time; nil at the end
  entry.each_chunk { |chunk| ... }
end
```

An entry's data can be read only inside the block, before the next entry
is reached; what is left unread is skipped. A name is a UTF-8 String when
its bytes are valid UTF-8 and a binary String otherwise.

`Ziperu::Tar::Reader` is the same thing without the block: `open`,
`next_entry`, `each`, `compression` (`:none`, `:gzip`, `:zstd`, `:xz` or
`:bzip2`) and `close`. The IO it was given is left open.

Decoding from a path runs with the GVL released, so other threads keep
going while a large entry is read or skipped.

## Extracting

`Ziperu::Tar.extract_all(path_or_io, destination = ".", **options)`
extracts every entry. `Ziperu.extract` does the same after looking at the
first bytes to tell a tar archive from a zip, and takes the options of
whichever it finds.

| option | |
|---|---|
| `symlinks:` | `:skip` (default, with a warning per link) or `:create` |
| `on_exists:` | `:raise` (default), `:overwrite` or `:skip`, for a path taken before the extraction began |
| `exclude:` | globs or Regexps of entry names to leave out; `"*.log"` matches at any depth |
| `strip_components:` | drop this many leading directories from every name |
| `sanitize:` | `:windows` rewrites names Windows refuses |
| `progress:` | called with `(entry, done, nil)` after each entry |
| the limits | `max_entries`, `max_entry_size`, `max_total_size`, `max_compression_ratio`, `max_archive_size` |

The rules are the ones a zip is extracted by (see
[SECURITY.md](../SECURITY.md)):

- A name that resolves outside the destination is skipped with a
  warning. A leading `/` is dropped, as `tar` does, so `/etc/passwd`
  lands at `destination/etc/passwd`.
- Nothing is written through a link that is already on disk below the
  destination.
- Times and permission bits are restored. Setuid and setgid bits and
  owners never are.
- A file being replaced is written beside its path and renamed into
  place, so a failure leaves what was there.

What is particular to tar:

- **Symlinks** are created only with `symlinks: :create`, and only when
  the target resolves inside the destination and has no `..` after a
  name.
- **Hard links** are created only to a file the same extraction wrote.
  A link to anything else (a file that was already there, a path outside
  the destination, a name the archive does not hold) is skipped with a
  warning.
- **Links are created last**, after every file, hard links before
  symlinks. So an archive cannot place a link and then write through it:
  an entry `d/x` listed after a symlink `d` makes a real directory `d`,
  and the link then finds its place taken (`DestinationExistsError`).
- **Devices and fifos** are skipped with a warning.
- **A name given twice:** the last entry wins, as with `tar`. This does
  not excuse a file that was there before: that one still follows
  `on_exists:`.
- **Names that are not valid UTF-8** are skipped with a warning.
- **An entry of a type not known here** is extracted as a regular file,
  as GNU tar and Python do.

There is no `threads:` (the archive is one stream), no `junk_paths:` and
no `extraction_plan` for tar.

## Limits

The limit settings work as keywords or as the `Ziperu.*` globals, and
`Ziperu::Limits::UPLOAD` and `STRICT` apply as they do to a zip. A tar
archive has no table of contents to check up front, so the limits are
enforced as it is read, and what came before the entry that broke one
has already been extracted:

- `max_entries`, `max_entry_size` and `max_total_size` are checked
  against each header as it is reached.
- `max_compression_ratio` is the ratio of bytes decoded to bytes read
  from the input, measured over the whole stream once a megabyte has
  come out. A gzip bomb is stopped a few megabytes in, whether its
  entries are read, skipped or extracted.
- `max_archive_size` bounds what is read from an IO.
- A long name or extended header over 1 MiB is refused, and an xz stream
  that needs more than 256 MiB to decode.
- Memory follows what has been read, never the size a header claims:
  `entry.read(entry.size)` on an entry that says it holds a terabyte
  fails when the archive runs out.

## Integrity

Tar has a checksum on each header and none on the data. For a compressed
archive the codec's own checksum is the only one there is, and gzip, xz
and bzip2 keep it at the end of the stream (zstd too, when the frame was
written with one, as the `zstd` command and ziperu do). So after the
last entry ziperu reads the compressed stream to its end, and corrupt
data raises `Ziperu::Error` even when every entry appeared to read. A
plain `.tar` has no such check.

Zero bytes after a gzip or bzip2 stream are taken for padding, as `gzip`
takes them; anything else after the end of a compressed stream raises.

A truncated archive raises. An archive that ends on a block boundary
without the two zero blocks that mark the end is accepted, as `tar`
accepts it with a warning. An archive of nothing but zero blocks is an
empty archive.

## Writing

`Ziperu::Tar.create(path_or_io, compression: nil, level: nil)` yields a
`Ziperu::Tar::Writer` and ends the archive when the block returns.

```ruby
Ziperu::Tar.create("backup.tar.zst", level: 10) do |tar|
  tar.add("report.pdf", "tmp/report.pdf")       # a file from disk
  tar.add("upload.bin", io)                     # any IO with read
  tar.add_data("notes.txt", "some text\n")      # a String
  tar.mkdir("empty")
  tar.symlink("latest", "report.pdf")
  tar.link("copy.pdf", "report.pdf")            # a hard link to an entry above
  tar.add_recursive("public", prefix: "site/")
end

Ziperu::Tar.add_recursive("site.tar.gz", "public")   # one directory, one call
```

- **Compression** is `:none`, `:gzip`, `:zstd`, `:xz` or `:bzip2`. For a
  path it defaults to what the name ends in (`.tar.gz`, `.tgz`,
  `.tar.zst`, `.tzst`, `.tar.xz`, `.txz`, `.tar.bz2`, `.tbz2`), and for an
  IO to none. `level:` is the codec's own scale: gzip and xz 0 to 9, zstd
  1 to 22, bzip2 1 to 9.
- **Where it goes:** a path, or any object with `write`, which may be a
  pipe or a socket: nothing is sought. A path is written beside itself
  and renamed into place when the archive is whole, so a block that
  raises leaves what was there. An IO is left open, and has by then been
  given whatever was written before the failure.
- **`add(name, source, mode: nil, mtime: nil)`** takes a path or an IO.
  A file's mode and time are its own unless given; an IO gets 0644 and
  now. A directory is added alone, without what is in it. An entry's
  size has to be written ahead of its data, so an IO is asked how much
  it has left (`size - pos`); one that cannot say (a pipe, a response
  body) is copied to a temporary file first. A file that cannot be
  opened raises before anything is written for it, so the error can be
  rescued and the archive go on.
- **`add_recursive(dir, prefix: "", symlinks: :skip, exclude: nil,
  progress: nil)`** adds a tree in name order. No link is followed:
  `symlinks: :skip` leaves them out with a warning and `:store` records
  them as links. `exclude:` takes globs or Regexps of archive names, and
  an excluded directory takes what is under it along. The archive being
  written is left out if it is inside the tree.
- **`Ziperu::Tar.body(**options) { |tar| ... }`** is the same as a Rack
  body: an Enumerator that yields the archive's bytes as they are made.

What is written:

- **Format:** a ustar header for each entry, and before it a PAX
  extended header only when something does not fit: a name or link
  target over 100 bytes or not ASCII, a size of 8 GiB or more, a time
  before 1970. An archive of ordinary names is plain ustar. GNU tar,
  bsdtar, Python and 7-Zip read the result in CI.
- **Owners are not recorded:** uid and gid are 0 and the names are
  empty, so an archive says nothing about the machine that made it.
- **Times are whole seconds.** With `Ziperu.source_date_epoch` (or the
  `SOURCE_DATE_EPOCH` variable, or the keyword on `create`) no entry is
  later than it, and the same input then gives the same bytes on any
  machine: the gzip header carries no time, name or operating system.
- **A zstd archive carries a checksum** of what it holds, as the `zstd`
  command writes one.
- **Names go in as given.** A trailing slash is dropped from a file's
  name; nothing else is cleaned, so `..` and a leading `/` are yours to
  avoid. An empty name or one with a NUL is an ArgumentError.

A file that shrinks while it is being read is made up with zeros, with
a warning, as `tar` does: its size is already in the archive. An IO
that gives less than it said raises `Ziperu::Error`, and the archive is
not finished.

Not written: sparse files, devices and fifos, extended attributes, and
sub-second times. There is no appending to an existing archive.

## Errors

- `Ziperu::Error`: not a tar archive, a damaged or truncated one, corrupt
  compressed data, or a kind that is not read (sparse, multi-volume).
- `Ziperu::LimitError`: a limit was passed.
- `Ziperu::DestinationExistsError`: a path is taken and `on_exists:` is
  `:raise`.
- `Errno::*` and `IOError`: from the file system or the IO, as usual.

After an error a reader reads nothing more.
