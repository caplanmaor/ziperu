# Benchmarks

ziperu 0.2.3 against rubyzip 3.7.0, both loaded in one process, on
GitHub's hosted runners with Ruby 3.4.12: [bench/bench.rb](../bench/bench.rb)
through [the Bench workflow](../.github/workflows/bench.yml), run
[43150830286](https://github.com/caplanmaor/ziperu/actions/runs/43150830286)
on 2026-11-11. Each scenario runs five times per library, alternating,
and the median is shown. Shared CI machines are noisy: read a 1.2x as
"about the same" and anything over 2x as real.

To reproduce: `rake bench` locally (`RUNS=`, `QUICK=1`), or label a pull
request `bench` to run all three platforms.

## ubuntu-latest (4 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.3 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 184 ms | 75 ms | 2.5x |
| read 1000 x 8 KB deflated entries | 110 ms | 18 ms | 6.1x |
| InputStream over 1000 entries | 70 ms | 18 ms | 3.9x |
| inflate one 64 MB entry | 112 ms | 38 ms | 3.0x |
| extract_all 1000 entries | 234 ms | 94 ms | 2.5x |
| write 1000 x 8 KB entries (OutputStream) | 99 ms | 47 ms | 2.1x |
| deflate one 64 MB entry (OutputStream) | 323 ms | 101 ms | 3.2x |
| open_buffer(String) and read 1000 entries | 70 ms | 14 ms | 5.0x |
| Zip::File add 100 files and commit | 14 ms | 8 ms | 1.6x |
| list names and times of 10000 entries | 196 ms | 126 ms | 1.6x |
| InputStream over 10000 entries, names only | 204 ms | 57 ms | 3.6x |
| Zip::File get_output_stream 1000 entries and commit | 310 ms | 84 ms | 3.7x |
| append one entry to a 10000-entry archive | 1.16 s | 148 ms | 7.8x |
| extract_all 1000 entries (ziperu: threads: 4) | 238 ms | 76 ms | 3.1x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 348 ms | 89 ms | 3.9x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [x86_64-linux]

## macos-latest (5 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.3 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 104 ms | 46 ms | 2.2x |
| read 1000 x 8 KB deflated entries | 66 ms | 12 ms | 5.4x |
| InputStream over 1000 entries | 46 ms | 12 ms | 3.8x |
| inflate one 64 MB entry | 72 ms | 20 ms | 3.6x |
| extract_all 1000 entries | 222 ms | 153 ms | 1.5x |
| write 1000 x 8 KB entries (OutputStream) | 60 ms | 33 ms | 1.8x |
| deflate one 64 MB entry (OutputStream) | 184 ms | 40 ms | 4.6x |
| open_buffer(String) and read 1000 entries | 42 ms | 10 ms | 4.3x |
| Zip::File add 100 files and commit | 9 ms | 6 ms | 1.4x |
| list names and times of 10000 entries | 103 ms | 73 ms | 1.4x |
| InputStream over 10000 entries, names only | 122 ms | 41 ms | 3.0x |
| Zip::File get_output_stream 1000 entries and commit | 384 ms | 55 ms | 7.0x |
| append one entry to a 10000-entry archive | 673 ms | 71 ms | 9.4x |
| extract_all 1000 entries (ziperu: threads: 4) | 222 ms | 118 ms | 1.9x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 178 ms | 50 ms | 3.6x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [arm64-darwin23]

## windows-latest (4 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.3 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 371 ms | 75 ms | 4.9x |
| read 1000 x 8 KB deflated entries | 265 ms | 22 ms | 11.8x |
| InputStream over 1000 entries | 154 ms | 24 ms | 6.3x |
| inflate one 64 MB entry | 132 ms | 22 ms | 6.0x |
| extract_all 1000 entries | 985 ms | 380 ms | 2.6x |
| write 1000 x 8 KB entries (OutputStream) | 122 ms | 46 ms | 2.6x |
| deflate one 64 MB entry (OutputStream) | 360 ms | 77 ms | 4.7x |
| open_buffer(String) and read 1000 entries | 130 ms | 20 ms | 6.4x |
| Zip::File add 100 files and commit | 39 ms | 27 ms | 1.4x |
| list names and times of 10000 entries | 380 ms | 135 ms | 2.8x |
| InputStream over 10000 entries, names only | 423 ms | 63 ms | 6.7x |
| Zip::File get_output_stream 1000 entries and commit | 935 ms | 97 ms | 9.6x |
| append one entry to a 10000-entry archive | 2.59 s | 154 ms | 16.8x |
| extract_all 1000 entries (ziperu: threads: 4) | 975 ms | 459 ms | 2.1x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 684 ms | 266 ms | 2.6x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [x64-mingw-ucrt]

## Reading the numbers

- **Decompressing and compressing** are where the Rust core pays off:
  reading many small deflated entries is 5x to 12x faster, and a large
  entry inflates 3x to 6x faster, straight into the String returned.
- **Writing through `Zip::File`** is where 0.2.3 gained most:
  `get_output_stream` keeps entries in memory rather than a tempfile
  each (4x to 10x), and appending to a large archive touches only what
  it adds (8x to 17x).
- **Listing** a large central directory is 2x to 5x faster. It is bounded
  by building one Ruby `Entry` per record, which both libraries do; use
  `Ziperu::File.foreach` to avoid holding them all. Walking an
  `InputStream` for names alone reads no entry data (3x to 7x).
- **`extract_all`** is bounded by creating files, which is slow on macOS
  and slower on Windows. `threads: 4` helps on Linux (94 ms to 76 ms) and
  macOS, and does not on Windows (380 ms to 459 ms), where more threads
  only contend for the file system. Measure before turning it on there.
- **Adding files from disk with `threads: 4`** is 2.6x to 3.9x faster than
  rubyzip, because each file is compressed on its own thread.
- **`Zip::File` add and commit** for a hundred small files is about the
  same: the time goes to the files, not the zip format.

## Which calls release the GVL

While the native core inflates, deflates or does file I/O it releases
the GVL, so other Ruby threads (other Puma requests, say) keep running,
as long as it never has to call back into Ruby for bytes. That depends
on where the archive is:

| The archive is | Reading (`read`, `get_input_stream`, `extract`, `extract_all`, `verify`, opening and listing) | Writing (`OutputStream`, `commit`) |
|---|---|---|
| A path: a String or Pathname, or a `File` or `Tempfile` given to `Ziperu::File.open` (which reopens it by path) | Released | Released |
| A String or `StringIO` (`open_buffer`) | Released (the bytes are taken once) | Held while writing to the `StringIO`; released with `memory: true`, which copies out once at `close` |
| A pipe or socket (`InputStream`, `write_buffer`, `OutputStream.body`) | Released (the stream is read into memory first, since a zip's directory is at its end) | Held: every chunk is handed to the Ruby IO as it is made |
| Any other seekable Ruby IO, including a `File` given to `InputStream.open` or `open_buffer` | Held: every read goes through its `read` and `seek` | Held |

"Held" means the work is done with the GVL, as rubyzip always does it;
it is still the faster path, but no other Ruby thread runs meanwhile.
Encrypted entries follow the same rule. Appending (`Ziperu::File` adding
to an archive on disk) writes to the path and releases it.
