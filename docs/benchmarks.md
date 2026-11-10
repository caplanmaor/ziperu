# Benchmarks

ziperu 0.2.0 against rubyzip 3.7.0, both loaded in one process, on
GitHub's hosted runners with Ruby 3.4.12: [bench/bench.rb](../bench/bench.rb)
through [the Bench workflow](../.github/workflows/bench.yml), run
[42841892936](https://github.com/caplanmaor/ziperu/actions/runs/42841892936)
on 2026-11-10. Each scenario runs five times per library, alternating,
and the median is shown. Shared CI machines are noisy: read a 1.2x as
"about the same" and anything over 2x as real.

To reproduce: `rake bench` locally (`RUNS=`, `QUICK=1`), or label a pull
request `bench` to run all three platforms.

## ubuntu-latest (4 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.0 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 135 ms | 58 ms | 2.3x |
| read 1000 x 8 KB deflated entries | 80 ms | 14 ms | 5.8x |
| InputStream over 1000 entries | 52 ms | 17 ms | 3.0x |
| inflate one 64 MB entry | 88 ms | 66 ms | 1.3x |
| extract_all 1000 entries | 169 ms | 80 ms | 2.1x |
| write 1000 x 8 KB entries (OutputStream) | 62 ms | 37 ms | 1.7x |
| deflate one 64 MB entry (OutputStream) | 188 ms | 77 ms | 2.4x |
| open_buffer(String) and read 1000 entries | 43 ms | 11 ms | 3.9x |
| Zip::File add 100 files and commit | 10 ms | 7 ms | 1.4x |
| extract_all 1000 entries (ziperu: threads: 4) | 167 ms | 67 ms | 2.5x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 214 ms | 60 ms | 3.6x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [x86_64-linux]

## macos-latest (3 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.0 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 106 ms | 54 ms | 2.0x |
| read 1000 x 8 KB deflated entries | 85 ms | 14 ms | 5.9x |
| InputStream over 1000 entries | 48 ms | 15 ms | 3.2x |
| inflate one 64 MB entry | 78 ms | 43 ms | 1.8x |
| extract_all 1000 entries | 290 ms | 213 ms | 1.4x |
| write 1000 x 8 KB entries (OutputStream) | 59 ms | 42 ms | 1.4x |
| deflate one 64 MB entry (OutputStream) | 200 ms | 43 ms | 4.7x |
| open_buffer(String) and read 1000 entries | 45 ms | 10 ms | 4.7x |
| Zip::File add 100 files and commit | 11 ms | 11 ms | 1.1x |
| extract_all 1000 entries (ziperu: threads: 4) | 317 ms | 186 ms | 1.7x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 200 ms | 65 ms | 3.1x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [arm64-darwin23]

## windows-latest (4 cores)

| scenario | rubyzip 3.7.0 | ziperu 0.2.0 | speedup |
|---|---:|---:|---:|
| open and list 10000 entries | 387 ms | 79 ms | 4.9x |
| read 1000 x 8 KB deflated entries | 266 ms | 24 ms | 11.2x |
| InputStream over 1000 entries | 152 ms | 43 ms | 3.6x |
| inflate one 64 MB entry | 122 ms | 65 ms | 1.9x |
| extract_all 1000 entries | 984 ms | 396 ms | 2.5x |
| write 1000 x 8 KB entries (OutputStream) | 122 ms | 61 ms | 2.0x |
| deflate one 64 MB entry (OutputStream) | 364 ms | 77 ms | 4.7x |
| open_buffer(String) and read 1000 entries | 121 ms | 18 ms | 6.6x |
| Zip::File add 100 files and commit | 42 ms | 34 ms | 1.2x |
| extract_all 1000 entries (ziperu: threads: 4) | 969 ms | 469 ms | 2.1x |
| add 1000 files from disk and commit (ziperu: threads: 4) | 693 ms | 246 ms | 2.8x |

median of 5 runs; ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [x64-mingw-ucrt]

## Reading the numbers

- **Decompressing and compressing** are where the Rust core pays off:
  reading many small deflated entries is 6x to 11x faster, deflating a
  large entry 2.4x to 4.7x.
- **Listing** a large central directory is 2x to 5x faster. It is bounded
  by building one Ruby `Entry` per record, which both libraries do; use
  `Ziperu::File.foreach` to avoid holding them all.
- **`extract_all`** is bounded by creating files, which is slow on macOS
  and slower on Windows. `threads: 4` helps on Linux (80 ms to 67 ms)
  and does not on Windows (396 ms to 469 ms), where more threads only
  contend for the file system. Measure before turning it on there.
- **Adding files from disk with `threads: 4`** is 2.8x to 3.6x faster than
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
