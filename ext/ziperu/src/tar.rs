//! `Ziperu::Native::TarReader`: reads a tar archive in one pass, header
//! by header, from a file or any Ruby IO with `read` (a pipe, a socket).
//!
//! The archive may be plain or compressed with gzip, zstd, xz or bzip2;
//! which is told from its first bytes, never from a name. The codecs are
//! the ones the zip crate already links.
//!
//! The headers are parsed here rather than by a crate, so that what is
//! taken for an entry, and what is refused, is decided in one place:
//!
//! - v7, ustar (with its name prefix) and GNU headers; GNU long names and
//!   long link names (`L`, `K`); PAX extended headers (`x`), of which
//!   `path`, `linkpath`, `size`, `mtime`, `uid`, `gid`, `uname` and `gname`
//!   are applied. PAX global headers (`g`) are read and ignored.
//! - Only a regular file has data. The size field of a link, a directory
//!   or a device is ignored, as GNU tar, libarchive and Python do.
//! - Sparse files and multi-volume archives are refused, not guessed at.
//! - An extended header or long name over `META_MAX` is refused: it would
//!   be held in memory whole.
//! - The archive ends at the first all-zero block, or at the end of the
//!   input on a block boundary. Input that ends anywhere else is a
//!   truncated archive. An archive with no entries is two zero blocks,
//!   as `tar` writes one; a single zero block is not an archive.
//! - A compressed archive is then read to the end of its stream, which
//!   is where gzip, xz and bzip2 keep the checksum of what they hold:
//!   tar has none for an entry's data, so that is the only check on it.
//!   Zeros after a gzip or bzip2 stream are padding, as `gzip` has it;
//!   anything else there is refused.
//!
//! `extract_begin`, `extract_entry` and `extract_finish` put entries on
//! disk through `placer.rs`, under the rules a zip's entries go by. Ruby
//! drives them one entry at a time, since it is Ruby that knows what is
//! excluded, renamed or a link.
//!
//! Two limits are enforced here because a single call can run long
//! (skipping a large entry): the ratio of tar bytes out to compressed
//! bytes in, and the number of bytes read from the input.

use std::cell::{Cell, RefCell, RefMut};
use std::fs;
use std::io::{self, BufRead, BufReader, Cursor, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use magnus::{
    gc::Marker, prelude::*, typed_data::DataTypeFunctions, value::Opaque, Error, IntoValue, RArray,
    RHash, RString, Ruby, Symbol, TypedData, Value,
};

use crate::errors::{busy_error, io_error, IntoRuby, ERROR, LIMIT_ERROR};
use crate::extract::{raise as extract_raise, system_time};
use crate::gvl::{maybe_without_gvl, Cancellable};
use crate::placer::{Failure, Notice, OnExists, Placer, Spec};
use crate::source::RubyError;
use crate::stream::RubyRead;

const BLOCK: usize = 512;
const CHUNK: usize = 64 * 1024;
/// The most a long name or an extended header may hold.
const META_MAX: u64 = 1 << 20;
/// The ratio limit is not applied to the first bytes out: a small archive
/// is mostly zero padding, and compresses a hundredfold honestly.
const RATIO_FLOOR: u64 = 1 << 20;
/// What an xz block's decoder may allocate, in KiB. `xz -9` needs 65 MiB;
/// a header can ask for 4 GiB.
const XZ_MEM_LIMIT_KB: u32 = 256 * 1024;
/// How much `read` takes on at a time: its buffer grows as the data
/// arrives, never to the size a header merely claims.
const READ_STEP: usize = 1 << 20;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Compression {
    None,
    Gzip,
    Zstd,
    Xz,
    Bzip2,
}

impl Compression {
    /// What the first bytes of the input say it is. A tar header starts
    /// with a file name, so each magic has to be one no name begins with:
    /// for bzip2 that takes the block magic after "BZh" and the level.
    fn detect(magic: &[u8]) -> Self {
        const BZ_BLOCK: &[u8] = &[0x31, 0x41, 0x59, 0x26, 0x53, 0x59];
        const BZ_END: &[u8] = &[0x17, 0x72, 0x45, 0x38, 0x50, 0x90];
        if magic.starts_with(&[0x1f, 0x8b]) {
            Compression::Gzip
        } else if magic.starts_with(&[0x28, 0xb5, 0x2f, 0xfd]) {
            Compression::Zstd
        } else if magic.starts_with(&[0xfd, b'7', b'z', b'X', b'Z', 0]) {
            Compression::Xz
        } else if magic.len() >= 10
            && magic.starts_with(b"BZh")
            && (b'1'..=b'9').contains(&magic[3])
            && (&magic[4..10] == BZ_BLOCK || &magic[4..10] == BZ_END)
        {
            Compression::Bzip2
        } else {
            Compression::None
        }
    }

    fn name(self) -> &'static str {
        match self {
            Compression::None => "none",
            Compression::Gzip => "gzip",
            Compression::Zstd => "zstd",
            Compression::Xz => "xz",
            Compression::Bzip2 => "bzip2",
        }
    }
}

/// Counts what is read from the input itself, before any decoding.
struct Counted<R> {
    inner: R,
    count: Arc<AtomicU64>,
}

impl<R: Read> Read for Counted<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.count.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}

/// Compressed streams end to end, read as one, as the command-line tools
/// have it; zero bytes after the last are padding (a tape's, a block
/// device's) and anything else there is an error of the decoder's.
struct Members<R, D> {
    current: Option<D>,
    start: fn(R) -> D,
    stop: fn(D) -> R,
}

impl<R: BufRead, D: Read> Members<R, D> {
    fn new(input: R, start: fn(R) -> D, stop: fn(D) -> R) -> Self {
        Self {
            current: Some(start(input)),
            start,
            stop,
        }
    }
}

impl<R: BufRead, D: Read> Read for Members<R, D> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            let Some(decoder) = self.current.as_mut() else {
                return Ok(0);
            };
            let n = decoder.read(buf)?;
            if n > 0 || buf.is_empty() {
                return Ok(n);
            }
            // This member is over: what comes after it?
            let Some(decoder) = self.current.take() else {
                return Ok(0);
            };
            let mut input = (self.stop)(decoder);
            loop {
                let chunk = input.fill_buf()?;
                if chunk.is_empty() {
                    return Ok(0);
                }
                let (len, zeros) = (chunk.len(), chunk.iter().take_while(|&&b| b == 0).count());
                input.consume(zeros);
                if zeros < len {
                    break;
                }
            }
            self.current = Some((self.start)(input));
        }
    }
}

/// The tar stream: `raw` with its compression, if any, taken off.
fn open_input(
    raw: impl Read + Send + 'static,
    count: Arc<AtomicU64>,
) -> io::Result<(Compression, Box<dyn Read + Send>)> {
    let mut raw = BufReader::with_capacity(
        CHUNK,
        Counted {
            inner: Cancellable(raw),
            count,
        },
    );
    let mut magic = [0u8; 10];
    let mut have = 0;
    while have < magic.len() {
        let n = raw.read(&mut magic[have..])?;
        if n == 0 {
            break;
        }
        have += n;
    }
    let compression = Compression::detect(&magic[..have]);
    let head = Cursor::new(magic[..have].to_vec()).chain(raw);
    let input: Box<dyn Read + Send> = match compression {
        Compression::None => Box::new(head),
        // Several members or frames end to end are one stream, as the
        // command-line tools have it.
        Compression::Gzip => Box::new(Members::new(
            head,
            flate2::bufread::GzDecoder::new,
            flate2::bufread::GzDecoder::into_inner,
        )),
        Compression::Zstd => Box::new(zstd::stream::read::Decoder::new(head)?),
        Compression::Xz => Box::new(lzma_rust2::XzReader::new_mem_limit(
            head,
            true,
            XZ_MEM_LIMIT_KB,
        )),
        Compression::Bzip2 => Box::new(Members::new(
            head,
            bzip2::bufread::BzDecoder::new,
            bzip2::bufread::BzDecoder::into_inner,
        )),
    };
    Ok((compression, input))
}

/// Why reading stopped.
#[derive(Debug)]
enum Fail {
    Io(io::Error),
    /// The bytes are not a tar archive, or not a whole one.
    Invalid(String),
    /// A tar archive, of a kind not read here.
    Unsupported(String),
    /// More came out, for what went in, than the limit allows.
    Ratio(f64, f64),
    /// More was read from the input than the limit allows.
    Input(u64, u64),
}

impl From<io::Error> for Fail {
    fn from(e: io::Error) -> Self {
        Fail::Io(e)
    }
}

/// What an entry is, from its type flag.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    File,
    Directory,
    Symlink,
    Hardlink,
    CharacterDevice,
    BlockDevice,
    Fifo,
    /// A type flag not known here; it has data, as a file does.
    Other,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::File => "file",
            Kind::Directory => "directory",
            Kind::Symlink => "symlink",
            Kind::Hardlink => "hardlink",
            Kind::CharacterDevice => "character_device",
            Kind::BlockDevice => "block_device",
            Kind::Fifo => "fifo",
            Kind::Other => "other",
        }
    }

    fn has_data(self) -> bool {
        matches!(self, Kind::File | Kind::Other)
    }
}

/// One entry, with long names and extended headers applied.
#[derive(Debug)]
struct Meta {
    name: Vec<u8>,
    link: Vec<u8>,
    kind: Kind,
    /// The bytes of data that follow; zero for what has none.
    size: u64,
    mtime_sec: i64,
    mtime_nsec: u32,
    mode: u32,
    uid: i64,
    gid: i64,
    uname: Vec<u8>,
    gname: Vec<u8>,
}

/// A header block's fields, as they stand in it.
struct Raw {
    meta: Meta,
    /// The type flag itself.
    flag: u8,
    /// The size field, whatever the type.
    size: u64,
}

/// A numeric field: octal digits, ended by a NUL or spaces; or, with the
/// first byte 0x80 or 0xff, a big-endian binary number (GNU's way of
/// holding what octal cannot, negative for 0xff).
fn number(field: &[u8]) -> Option<i64> {
    let first = *field.first()?;
    if first == 0x80 || first == 0xff {
        let mut n: i128 = 0;
        for &b in &field[1..] {
            n = (n << 8) | i128::from(b);
        }
        if first == 0xff {
            n -= 1i128 << (8 * (field.len() - 1));
        }
        return i64::try_from(n).ok();
    }
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    let digits = field[..end].trim_ascii();
    let mut n: u64 = 0;
    for &b in digits {
        if !(b'0'..=b'7').contains(&b) {
            return None;
        }
        n = n.checked_mul(8)?.checked_add(u64::from(b - b'0'))?;
    }
    i64::try_from(n).ok()
}

/// A text field: up to its first NUL.
fn text(field: &[u8]) -> &[u8] {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    &field[..end]
}

/// Whether the block's checksum field holds the sum of its bytes, taken
/// with that field as spaces. Old writers summed the bytes as signed.
fn checksum_ok(block: &[u8; BLOCK]) -> bool {
    let Some(stored) = number(&block[148..156]) else {
        return false;
    };
    let (mut unsigned, mut signed) = (0i64, 0i64);
    for (i, &b) in block.iter().enumerate() {
        let b = if (148..156).contains(&i) { b' ' } else { b };
        unsigned += i64::from(b);
        signed += i64::from(b as i8);
    }
    stored == unsigned || stored == signed
}

fn parse_header(block: &[u8; BLOCK]) -> Result<Raw, &'static str> {
    if !checksum_ok(block) {
        return Err("a header's checksum does not match");
    }
    let posix = &block[257..263] == b"ustar\0";
    let mut name = text(&block[0..100]).to_vec();
    let flag = block[156];
    if posix {
        let prefix = text(&block[345..500]);
        if !prefix.is_empty() {
            let mut joined = prefix.to_vec();
            joined.push(b'/');
            joined.extend_from_slice(&name);
            name = joined;
        }
    }
    let size = number(&block[124..136])
        .and_then(|n| u64::try_from(n).ok())
        .ok_or("a header's size is not a number")?;
    let mode = number(&block[100..108])
        .and_then(|n| u32::try_from(n & 0o7777).ok())
        .ok_or("a header's mode is not a number")?;
    let uid = number(&block[108..116]).ok_or("a header's uid is not a number")?;
    let gid = number(&block[116..124]).ok_or("a header's gid is not a number")?;
    let mtime = number(&block[136..148]).ok_or("a header's time is not a number")?;
    let kind = match flag {
        0 | b'0' | b'7' => Kind::File,
        b'1' => Kind::Hardlink,
        b'2' => Kind::Symlink,
        b'3' => Kind::CharacterDevice,
        b'4' => Kind::BlockDevice,
        b'5' => Kind::Directory,
        b'6' => Kind::Fifo,
        _ => Kind::Other,
    };
    Ok(Raw {
        meta: Meta {
            name,
            link: text(&block[157..257]).to_vec(),
            kind,
            size: if kind.has_data() { size } else { 0 },
            mtime_sec: mtime,
            mtime_nsec: 0,
            mode,
            uid,
            gid,
            uname: text(&block[265..297]).to_vec(),
            gname: text(&block[297..329]).to_vec(),
        },
        flag,
        size,
    })
}

/// A key and its value.
type PaxRecord<'a> = (&'a [u8], &'a [u8]);

/// The records of a PAX extended header: `<length> <key>=<value>\n`, the
/// length in decimal and counting the whole record.
fn parse_pax(data: &[u8]) -> Result<Vec<PaxRecord<'_>>, &'static str> {
    const BAD: &str = "an extended header is malformed";
    let mut rest = data;
    let mut records = Vec::new();
    // Some writers pad the last record's block with NULs.
    while !rest.is_empty() && rest[0] != 0 {
        let space = rest.iter().take(20).position(|&b| b == b' ').ok_or(BAD)?;
        let length: usize = std::str::from_utf8(&rest[..space])
            .ok()
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse().ok())
            .ok_or(BAD)?;
        if length < space + 3 || length > rest.len() || rest[length - 1] != b'\n' {
            return Err(BAD);
        }
        let record = &rest[space + 1..length - 1];
        let equals = record.iter().position(|&b| b == b'=').ok_or(BAD)?;
        records.push((&record[..equals], &record[equals + 1..]));
        rest = &rest[length..];
    }
    Ok(records)
}

fn pax_number(value: &[u8]) -> Option<i64> {
    std::str::from_utf8(value).ok()?.parse().ok()
}

/// A PAX time: seconds, with an optional decimal fraction. Returns whole
/// seconds and the nanoseconds past them.
fn pax_time(value: &[u8]) -> Option<(i64, u32)> {
    let s = std::str::from_utf8(value).ok()?;
    let (whole, fraction) = s.split_once('.').unwrap_or((s, ""));
    let sec: i64 = whole.parse().ok()?;
    if !fraction.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut nsec = 0u32;
    for i in 0..9 {
        let digit = fraction.as_bytes().get(i).map_or(0, |b| b - b'0');
        nsec = nsec * 10 + u32::from(digit);
    }
    if whole.starts_with('-') && nsec > 0 {
        // -1.25 is three quarters of a second past -2.
        Some((sec.checked_sub(1)?, 1_000_000_000 - nsec))
    } else {
        Some((sec, nsec))
    }
}

/// Applies an extended header's records to the entry that follows it.
fn apply_pax(meta: &mut Meta, data: &[u8]) -> Result<(), Fail> {
    let invalid = |what: &str| Fail::Invalid(format!("an extended header's {what} is not valid"));
    for (key, value) in parse_pax(data).map_err(|e| Fail::Invalid(e.to_string()))? {
        match key {
            // A header's own name fields end at a NUL, so only here can a
            // name hold one; no file system takes it.
            b"path" | b"linkpath" if value.contains(&0) => return Err(invalid("name")),
            b"path" => meta.name = value.to_vec(),
            b"linkpath" => meta.link = value.to_vec(),
            b"uname" => meta.uname = value.to_vec(),
            b"gname" => meta.gname = value.to_vec(),
            b"size" => {
                let size = pax_number(value)
                    .and_then(|n| u64::try_from(n).ok())
                    .ok_or_else(|| invalid("size"))?;
                if meta.kind.has_data() {
                    meta.size = size;
                }
            }
            b"uid" => meta.uid = pax_number(value).ok_or_else(|| invalid("uid"))?,
            b"gid" => meta.gid = pax_number(value).ok_or_else(|| invalid("gid"))?,
            b"mtime" => {
                (meta.mtime_sec, meta.mtime_nsec) =
                    pax_time(value).ok_or_else(|| invalid("mtime"))?;
            }
            _ if key.starts_with(b"GNU.sparse.") => {
                return Err(Fail::Unsupported(
                    "sparse files in a tar archive are not supported".to_string(),
                ));
            }
            _ => {}
        }
    }
    Ok(())
}

struct State {
    input: Box<dyn Read + Send>,
    compression: Compression,
    /// Bytes read from the input, before decoding.
    raw_in: Arc<AtomicU64>,
    /// Bytes of the tar stream taken so far.
    out: u64,
    /// Data left in the current entry, and the padding after it.
    remaining: u64,
    padding: u64,
    done: bool,
    max_ratio: Option<f64>,
    max_input: Option<u64>,
}

impl State {
    /// One read of the tar stream, counted and checked against the limits.
    fn take(&mut self, buf: &mut [u8]) -> Result<usize, Fail> {
        let n = self.input.read(buf)?;
        self.out += n as u64;
        let read = self.raw_in.load(Ordering::Relaxed);
        if let Some(limit) = self.max_input {
            if read > limit {
                return Err(Fail::Input(read, limit));
            }
        }
        if let Some(limit) = self.max_ratio {
            if self.compression != Compression::None && self.out > RATIO_FLOOR {
                let ratio = self.out as f64 / read.max(1) as f64;
                if ratio > limit {
                    return Err(Fail::Ratio(ratio, limit));
                }
            }
        }
        Ok(n)
    }

    /// Fills `buf`; how much of it was filled before the input ended.
    fn take_all(&mut self, buf: &mut [u8]) -> Result<usize, Fail> {
        let mut have = 0;
        while have < buf.len() {
            let n = self.take(&mut buf[have..])?;
            if n == 0 {
                break;
            }
            have += n;
        }
        Ok(have)
    }

    fn truncated() -> Fail {
        Fail::Invalid("the archive is cut short".to_string())
    }

    fn take_exact(&mut self, buf: &mut [u8]) -> Result<(), Fail> {
        if self.take_all(buf)? < buf.len() {
            return Err(Self::truncated());
        }
        Ok(())
    }

    fn skip(&mut self, mut count: u64) -> Result<(), Fail> {
        let mut scratch = vec![0u8; (count.min(CHUNK as u64)) as usize];
        while count > 0 {
            let step = count.min(scratch.len() as u64) as usize;
            self.take_exact(&mut scratch[..step])?;
            count -= step as u64;
        }
        Ok(())
    }

    /// Reads a compressed stream to its end, so that the codec checks
    /// what it has decoded. What follows the end of the archive is not
    /// looked at, only passed over, under the same limits as the rest.
    fn drain(&mut self) -> Result<(), Fail> {
        if self.compression == Compression::None {
            return Ok(());
        }
        let mut scratch = vec![0u8; CHUNK];
        while self.take(&mut scratch)? > 0 {}
        Ok(())
    }

    /// The data of a long name or an extended header, and past its padding.
    fn metadata(&mut self, size: u64) -> Result<Vec<u8>, Fail> {
        if size > META_MAX {
            return Err(Fail::Invalid(format!(
                "a long name or extended header of {size} bytes is over the {META_MAX} allowed"
            )));
        }
        let mut data = vec![0u8; size as usize];
        self.take_exact(&mut data)?;
        self.skip(padding_after(size))?;
        Ok(data)
    }

    /// Skips what is left of the current entry and reads up to the next
    /// one; `None` at the end of the archive.
    fn next(&mut self) -> Result<Option<Meta>, Fail> {
        if self.done {
            return Ok(None);
        }
        let rest = self.remaining + self.padding;
        (self.remaining, self.padding) = (0, 0);
        self.skip(rest)?;

        let mut long_name: Option<Vec<u8>> = None;
        let mut long_link: Option<Vec<u8>> = None;
        let mut extended: Option<Vec<u8>> = None;
        loop {
            let offset = self.out;
            let mut block = [0u8; BLOCK];
            let have = self.take_all(&mut block)?;
            let pending = long_name.is_some() || long_link.is_some() || extended.is_some();
            if have == 0 && offset > 0 && !pending {
                // No end marker: the input ends where an entry could start.
                self.done = true;
                return Ok(None);
            }
            if have < BLOCK {
                return Err(if offset == 0 {
                    Fail::Invalid("not a tar archive".to_string())
                } else {
                    Self::truncated()
                });
            }
            if block.iter().all(|&b| b == 0) {
                if offset == 0 {
                    // An archive of nothing is its end marker alone: two
                    // zero blocks. Fewer, or zeros that give way to
                    // something else, are not an archive.
                    let mut second = [1u8; BLOCK];
                    let have = self.take_all(&mut second)?;
                    if have < BLOCK || second.iter().any(|&b| b != 0) {
                        return Err(Fail::Invalid("not a tar archive".to_string()));
                    }
                }
                if pending {
                    return Err(Self::truncated());
                }
                self.done = true;
                self.drain()?;
                return Ok(None);
            }
            let Raw {
                mut meta,
                flag,
                size,
            } = parse_header(&block).map_err(|why| {
                Fail::Invalid(if offset == 0 {
                    "not a tar archive".to_string()
                } else {
                    format!("{why} (at offset {offset})")
                })
            })?;
            match flag {
                b'L' => {
                    long_name = Some(text(&self.metadata(size)?).to_vec());
                    continue;
                }
                b'K' => {
                    long_link = Some(text(&self.metadata(size)?).to_vec());
                    continue;
                }
                // 'X' is how Solaris marks the same thing.
                b'x' | b'X' => {
                    extended = Some(self.metadata(size)?);
                    continue;
                }
                // Global settings, a comment: read past.
                b'g' => {
                    self.metadata(size)?;
                    continue;
                }
                // A volume label has no data and names no file.
                b'V' => continue,
                b'S' => {
                    return Err(Fail::Unsupported(
                        "sparse files in a tar archive are not supported".to_string(),
                    ))
                }
                b'M' => {
                    return Err(Fail::Unsupported(
                        "multi-volume tar archives are not supported".to_string(),
                    ))
                }
                _ => {}
            }
            if let Some(name) = long_name.take() {
                meta.name = name;
            }
            if let Some(link) = long_link.take() {
                meta.link = link;
            }
            if let Some(data) = extended.take() {
                apply_pax(&mut meta, &data)?;
            }
            // An old-style directory: no type for it, a name that ends in
            // a slash. The whole name, that is: of a long one the header
            // holds the first hundred bytes, which can end in a slash
            // when the name does not.
            if matches!(flag, 0 | b'0') && meta.name.ends_with(b"/") {
                meta.kind = Kind::Directory;
                meta.size = 0;
            }
            self.remaining = meta.size;
            self.padding = padding_after(meta.size);
            return Ok(Some(meta));
        }
    }

    /// Fills `buf` with the current entry's data; the caller asks for no
    /// more than is left of it.
    fn read_data(&mut self, buf: &mut [u8]) -> Result<(), Fail> {
        debug_assert!(buf.len() as u64 <= self.remaining);
        self.take_exact(buf)?;
        self.remaining -= buf.len() as u64;
        Ok(())
    }
}

/// The zero bytes that bring `size` bytes of data up to a whole block.
fn padding_after(size: u64) -> u64 {
    (BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64
}

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::TarReader", free_immediately, mark)]
pub struct TarReader {
    inner: RefCell<Option<State>>,
    /// The Ruby IO read from, if that is what the input is.
    io: Option<Opaque<Value>>,
    compression: Compression,
    raw_in: Arc<AtomicU64>,
    /// A read failed part-way: where the stream stands is not known, so
    /// nothing more is read from it.
    failed: Cell<bool>,
    /// Where entries are put, once `extract_begin` has said.
    placer: RefCell<Option<Placer>>,
}

impl DataTypeFunctions for TarReader {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
    }
}

impl TarReader {
    /// `max_ratio` and `max_input` are the limits described at the top of
    /// this file, nil for none.
    pub fn open_path(
        ruby: &Ruby,
        path: String,
        max_ratio: Option<f64>,
        max_input: Option<u64>,
    ) -> Result<Self, Error> {
        let file = fs::File::open(&path).rb(ruby)?;
        Self::start(ruby, file, None, max_ratio, max_input)
    }

    /// Any Ruby object with `read(n)`; it is read forward only.
    pub fn open_io(
        ruby: &Ruby,
        io: Value,
        max_ratio: Option<f64>,
        max_input: Option<u64>,
    ) -> Result<Self, Error> {
        let opaque = Opaque::from(io);
        Self::start(
            ruby,
            RubyRead::new(opaque),
            Some(opaque),
            max_ratio,
            max_input,
        )
    }

    fn start(
        ruby: &Ruby,
        raw: impl Read + Send + 'static,
        io: Option<Opaque<Value>>,
        max_ratio: Option<f64>,
        max_input: Option<u64>,
    ) -> Result<Self, Error> {
        let raw_in = Arc::new(AtomicU64::new(0));
        let (compression, input) = open_input(raw, Arc::clone(&raw_in))
            .map_err(|e| raise(ruby, Compression::None, Fail::Io(e)))?;
        Ok(Self {
            inner: RefCell::new(Some(State {
                input,
                compression,
                raw_in: Arc::clone(&raw_in),
                out: 0,
                remaining: 0,
                padding: 0,
                done: false,
                max_ratio,
                max_input,
            })),
            io,
            compression,
            raw_in,
            failed: Cell::new(false),
            placer: RefCell::new(None),
        })
    }

    fn state(&self, ruby: &Ruby) -> Result<RefMut<'_, State>, Error> {
        if self.failed.get() {
            return Err(Error::new(
                ruby.exception_io_error(),
                "the tar reader failed earlier and cannot go on",
            ));
        }
        let guard = self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar reader"))?;
        RefMut::filter_map(guard, Option::as_mut)
            .map_err(|_| Error::new(ruby.exception_io_error(), "closed stream"))
    }

    /// Runs `work` on the state, with the GVL released unless the input is
    /// a Ruby IO. A failure is final.
    fn run<T>(
        &self,
        ruby: &Ruby,
        work: impl FnOnce(&mut State) -> Result<T, Fail>,
    ) -> Result<T, Error> {
        let mut state = self.state(ruby)?;
        let outcome = maybe_without_gvl(self.io.is_some(), || work(&mut state));
        drop(state);
        outcome.map_err(|fail| {
            self.failed.set(true);
            raise(ruby, self.compression, fail)
        })
    }

    /// Skips what is left of the current entry and reads the next header:
    /// a Hash of its fields, or nil at the end of the archive.
    pub fn next_entry(ruby: &Ruby, rb_self: &Self) -> Result<Option<RHash>, Error> {
        let Some(meta) = rb_self.run(ruby, State::next)? else {
            return Ok(None);
        };
        let h = ruby.hash_new();
        let text = |bytes: &[u8]| ruby.str_from_slice(bytes);
        h.aset(ruby.to_symbol("name"), text(&meta.name))?;
        h.aset(ruby.to_symbol("linkname"), text(&meta.link))?;
        h.aset(ruby.to_symbol("type"), ruby.to_symbol(meta.kind.name()))?;
        h.aset(ruby.to_symbol("size"), meta.size)?;
        h.aset(ruby.to_symbol("mtime_sec"), meta.mtime_sec)?;
        h.aset(ruby.to_symbol("mtime_nsec"), meta.mtime_nsec)?;
        h.aset(ruby.to_symbol("mode"), meta.mode)?;
        h.aset(ruby.to_symbol("uid"), meta.uid)?;
        h.aset(ruby.to_symbol("gid"), meta.gid)?;
        h.aset(ruby.to_symbol("uname"), text(&meta.uname))?;
        h.aset(ruby.to_symbol("gname"), text(&meta.gname))?;
        Ok(Some(h))
    }

    /// Up to `want` bytes of the current entry's data, or nil at its end.
    pub fn read(ruby: &Ruby, rb_self: &Self, want: usize) -> Result<Option<RString>, Error> {
        let left = rb_self.state(ruby)?.remaining;
        if left == 0 {
            return Ok(None);
        }
        let want = (want as u64).min(left) as usize;
        // What is left is what a header says, which may be far more than
        // the archive holds: the buffer is for what has really arrived.
        let mut buf = Vec::new();
        rb_self.run(ruby, |state| {
            while buf.len() < want {
                let have = buf.len();
                buf.resize(have + (want - have).min(READ_STEP), 0);
                state.read_data(&mut buf[have..])?;
            }
            Ok(())
        })?;
        Ok(Some(ruby.str_from_slice(&buf)))
    }

    /// `:none`, `:gzip`, `:zstd`, `:xz` or `:bzip2`.
    pub fn compression(ruby: &Ruby, rb_self: &Self) -> Symbol {
        ruby.to_symbol(rb_self.compression.name())
    }

    /// Bytes read from the input so far (compressed, if it is).
    pub fn bytes_in(&self) -> u64 {
        self.raw_in.load(Ordering::Relaxed)
    }

    /// Says where `extract_entry` puts entries: under `dest`, an absolute
    /// path. `on_exists` is 0 raise, 1 overwrite, 2 skip.
    pub fn extract_begin(
        ruby: &Ruby,
        rb_self: &Self,
        dest: String,
        on_exists: u8,
    ) -> Result<(), Error> {
        let on_exists = match on_exists {
            0 => OnExists::Raise,
            1 => OnExists::Overwrite,
            2 => OnExists::Skip,
            other => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("on_exists code {other} is not 0, 1 or 2"),
                ))
            }
        };
        *rb_self
            .placer
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar reader"))? = Some(Placer::new(&dest, on_exists));
        Ok(())
    }

    /// Puts the current entry at `name` under the destination: a
    /// directory, or a file holding what is left of the entry's data.
    /// `spec` is `[name, mtime_sec, mtime_nsec, mode, directory, replace]`,
    /// the time and mode nil to leave them alone; with `replace` a file
    /// already there is overwritten whatever the policy (the caller knows
    /// it for one this run wrote).
    ///
    /// Returns the bytes written for a file, nil for a directory or an
    /// entry left out under the policy, and `[kind, path]` for one left
    /// out with a warning due (`:unsafe`, or `:link` with the link).
    pub fn extract_entry(ruby: &Ruby, rb_self: &Self, spec: RArray) -> Result<Value, Error> {
        let name: String = spec.entry(0)?;
        let mtime = match spec.entry::<Option<i64>>(1)? {
            Some(sec) => system_time(sec, spec.entry(2)?),
            None => None,
        };
        let replace: bool = spec.entry(5)?;
        let spec = Spec {
            index: 0,
            name,
            mtime,
            mode: spec.entry(3)?,
            directory: spec.entry(4)?,
        };

        let mut state = rb_self.state(ruby)?;
        let mut placer = rb_self.placer(ruby)?;
        let policy = placer.on_exists();
        if replace {
            placer.set_on_exists(OnExists::Overwrite);
            placer.set_own(true);
        }
        // What went wrong reading the archive, as opposed to writing the
        // file: `place` only knows the second kind.
        let mut read_fail: Option<Fail> = None;
        let outcome = maybe_without_gvl(rb_self.io.is_some(), || {
            let state = &mut *state;
            let read_fail = &mut read_fail;
            placer.place(&spec, |file| {
                let mut buf = vec![0u8; CHUNK];
                let mut written = 0u64;
                while state.remaining > 0 {
                    crate::gvl::check()?;
                    let step = state.remaining.min(CHUNK as u64) as usize;
                    if let Err(fail) = state.read_data(&mut buf[..step]) {
                        *read_fail = Some(fail);
                        return Err(Failure::Io(io::Error::other("reading the archive failed")));
                    }
                    file.write_all(&buf[..step])?;
                    written += step as u64;
                }
                Ok(written)
            })
        });
        placer.set_on_exists(policy);
        placer.set_own(false);
        let notice = placer.take_notices().pop();
        drop(placer);
        drop(state);

        if let Some(fail) = read_fail {
            rb_self.failed.set(true);
            return Err(raise(ruby, rb_self.compression, fail));
        }
        let written =
            outcome.map_err(|failure| extract_raise(ruby, ruby.qnil().as_value(), failure))?;
        Ok(match notice {
            Some((_, Notice::Unsafe(path))) => {
                (ruby.to_symbol("unsafe"), path).into_value_with(ruby)
            }
            Some((_, Notice::Link(path))) => (ruby.to_symbol("link"), path).into_value_with(ruby),
            Some((_, Notice::Oversize)) | None => written.into_value_with(ruby),
        })
    }

    /// Gives the directories made their times and modes, now that nothing
    /// more goes into them.
    pub fn extract_finish(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut placer = rb_self.placer(ruby)?;
        let outcome = maybe_without_gvl(false, || placer.stamp_directories());
        drop(placer);
        outcome.map_err(|(_, failure)| extract_raise(ruby, ruby.qnil().as_value(), failure))
    }

    fn placer(&self, ruby: &Ruby) -> Result<RefMut<'_, Placer>, Error> {
        let guard = self
            .placer
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar reader"))?;
        RefMut::filter_map(guard, Option::as_mut).map_err(|_| {
            Error::new(
                ruby.exception_io_error(),
                "extract_begin has not been called",
            )
        })
    }

    pub fn close(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar reader"))?
            .take();
        Ok(())
    }
}

fn raise(ruby: &Ruby, compression: Compression, fail: Fail) -> Error {
    let invalid = |why: String| {
        Error::new(
            ruby.get_inner(&ERROR),
            format!("invalid tar archive: {why}"),
        )
    };
    match fail {
        Fail::Invalid(why) => invalid(why),
        Fail::Unsupported(why) => Error::new(ruby.get_inner(&ERROR), why),
        Fail::Ratio(ratio, allowed) => {
            let ratio = (ratio * 10.0).round() / 10.0;
            limit_error(ruby, ("a compression ratio", ratio, allowed))
        }
        Fail::Input(read, allowed) => limit_error(ruby, ("an archive size", read, allowed)),
        Fail::Io(e) => {
            let ours = crate::gvl::is_cancelled(&e)
                || e.get_ref().is_some_and(|inner| inner.is::<RubyError>());
            if ours {
                return io_error(ruby, e);
            }
            use io::ErrorKind::*;
            match e.kind() {
                UnexpectedEof => invalid("the archive is cut short".to_string()),
                // How the decoders report data they cannot make sense of.
                InvalidData | InvalidInput | Other | OutOfMemory
                    if compression != Compression::None =>
                {
                    invalid(format!("the {} data is corrupt ({e})", compression.name()))
                }
                _ => io_error(ruby, e),
            }
        }
    }
}

/// `Ziperu::LimitError.new(what, actual, limit)`.
fn limit_error<A: magnus::ArgList>(ruby: &Ruby, args: A) -> Error {
    match ruby.get_inner(&LIMIT_ERROR).new_instance(args) {
        Ok(exception) => Error::from(exception),
        Err(e) => e,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_rng::{Rng, CASES};

    fn octal(field: &mut [u8], value: u64) {
        let digits = format!("{:0width$o}", value, width = field.len() - 1);
        field[..digits.len()].copy_from_slice(digits.as_bytes());
        field[digits.len()] = 0;
    }

    /// A ustar header block for `name`, with a good checksum.
    fn header(name: &[u8], flag: u8, size: u64) -> [u8; BLOCK] {
        let mut b = [0u8; BLOCK];
        b[..name.len()].copy_from_slice(name);
        octal(&mut b[100..108], 0o644);
        octal(&mut b[108..116], 1000);
        octal(&mut b[116..124], 1000);
        octal(&mut b[124..136], size);
        octal(&mut b[136..148], 1_700_000_000);
        b[156] = flag;
        b[257..263].copy_from_slice(b"ustar\0");
        b[263..265].copy_from_slice(b"00");
        seal(&mut b);
        b
    }

    fn seal(b: &mut [u8; BLOCK]) {
        b[148..156].copy_from_slice(b"        ");
        let sum: u64 = b.iter().map(|&x| u64::from(x)).sum();
        let digits = format!("{sum:06o}\0 ");
        b[148..156].copy_from_slice(digits.as_bytes());
    }

    fn padded(data: &[u8]) -> Vec<u8> {
        let mut out = data.to_vec();
        out.resize(data.len() + padding_after(data.len() as u64) as usize, 0);
        out
    }

    fn reader(bytes: Vec<u8>) -> State {
        let raw_in = Arc::new(AtomicU64::new(0));
        let (compression, input) = open_input(Cursor::new(bytes), Arc::clone(&raw_in)).unwrap();
        State {
            input,
            compression,
            raw_in,
            out: 0,
            remaining: 0,
            padding: 0,
            done: false,
            max_ratio: None,
            max_input: None,
        }
    }

    fn names(bytes: Vec<u8>) -> Result<Vec<String>, Fail> {
        let mut state = reader(bytes);
        let mut names = Vec::new();
        while let Some(meta) = state.next()? {
            names.push(String::from_utf8_lossy(&meta.name).into_owned());
        }
        Ok(names)
    }

    #[test]
    fn reads_numbers() {
        assert_eq!(number(b"0000644\0"), Some(0o644));
        assert_eq!(number(b"   644 \0"), Some(0o644));
        assert_eq!(number(b"\0\0\0\0\0\0\0\0"), Some(0));
        assert_eq!(number(b"        "), Some(0));
        assert_eq!(number(b"0000648\0"), None);
        assert_eq!(
            number(&[0x80, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0]),
            Some(1 << 32)
        );
        assert_eq!(number(&[0xff; 12]), Some(-1));
        assert_eq!(
            number(&[0x80, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            None
        );
        assert_eq!(number(&[0x81, 0, 0, 0, 0, 0, 0, 0]), None);
    }

    #[test]
    fn reads_pax_records() {
        let records = parse_pax(b"12 path=a/b\n18 mtime=1.500000\n").unwrap();
        assert_eq!(
            records,
            vec![(&b"path"[..], &b"a/b"[..]), (b"mtime", b"1.500000")]
        );
        assert!(parse_pax(b"99 path=a\n").is_err());
        assert!(parse_pax(b"9 path=a/b\n").is_err());
        assert!(parse_pax(b"x path=a\n").is_err());
        assert!(parse_pax(b"7 path\n").is_err());
        assert_eq!(parse_pax(b"").unwrap(), vec![]);
    }

    #[test]
    fn reads_pax_times() {
        assert_eq!(pax_time(b"1700000000"), Some((1_700_000_000, 0)));
        assert_eq!(pax_time(b"1.5"), Some((1, 500_000_000)));
        assert_eq!(pax_time(b"1.123456789123"), Some((1, 123_456_789)));
        assert_eq!(pax_time(b"-1.25"), Some((-2, 750_000_000)));
        assert_eq!(pax_time(b"-0.5"), Some((-1, 500_000_000)));
        assert_eq!(pax_time(b"1.x"), None);
        assert_eq!(pax_time(b""), None);
    }

    #[test]
    fn tells_compression_from_the_first_bytes() {
        assert_eq!(Compression::detect(&[0x1f, 0x8b, 8, 0]), Compression::Gzip);
        assert_eq!(
            Compression::detect(&[0x28, 0xb5, 0x2f, 0xfd, 0]),
            Compression::Zstd
        );
        assert_eq!(Compression::detect(b"\xfd7zXZ\0\0"), Compression::Xz);
        assert_eq!(Compression::detect(b"BZh91AY&SY"), Compression::Bzip2);
        // A file named like the start of a bzip2 stream is a file name.
        assert_eq!(Compression::detect(b"BZh9.txt\0\0"), Compression::None);
        assert_eq!(Compression::detect(b"hello.txt\0"), Compression::None);
        assert_eq!(Compression::detect(b""), Compression::None);
    }

    #[test]
    fn walks_entries_and_skips_unread_data() {
        let mut tar = Vec::new();
        tar.extend(header(b"a.txt", b'0', 5));
        tar.extend(padded(b"hello"));
        tar.extend(header(b"dir/", b'5', 0));
        tar.extend(header(b"dir/b.txt", b'0', 600));
        tar.extend(padded(&[7u8; 600]));
        tar.extend([0u8; 2 * BLOCK]);
        assert_eq!(names(tar.clone()).unwrap(), ["a.txt", "dir/", "dir/b.txt"]);

        let mut state = reader(tar);
        let first = state.next().unwrap().unwrap();
        assert_eq!((first.kind, first.size, first.mode), (Kind::File, 5, 0o644));
        let mut data = [0u8; 5];
        state.read_data(&mut data).unwrap();
        assert_eq!(&data, b"hello");
        assert_eq!(state.next().unwrap().unwrap().kind, Kind::Directory);
        assert_eq!(state.next().unwrap().unwrap().size, 600);
        assert!(state.next().unwrap().is_none());
        assert!(state.next().unwrap().is_none());
    }

    #[test]
    fn applies_long_names_and_extended_headers() {
        let long = vec![b'n'; 300];
        let mut tar = Vec::new();
        let mut name = long.clone();
        name.push(0);
        tar.extend(header(b"././@LongLink", b'L', name.len() as u64));
        tar.extend(padded(&name));
        tar.extend(header(b"short", b'0', 0));
        let pax = b"21 path=from/pax.txt\n10 size=3\n30 mtime=1700000001.250000000\n";
        tar.extend(header(b"PaxHeader", b'x', pax.len() as u64));
        tar.extend(padded(pax));
        tar.extend(header(b"ignored", b'0', 0));
        tar.extend(padded(b"abc"));
        tar.extend([0u8; 2 * BLOCK]);

        let mut state = reader(tar);
        assert_eq!(state.next().unwrap().unwrap().name, long);
        let second = state.next().unwrap().unwrap();
        assert_eq!(second.name, b"from/pax.txt");
        assert_eq!(second.size, 3);
        assert_eq!(
            (second.mtime_sec, second.mtime_nsec),
            (1_700_000_001, 250_000_000)
        );
        assert!(state.next().unwrap().is_none());
    }

    #[test]
    fn a_long_name_cut_at_a_slash_is_still_a_file() {
        // 99 bytes and a slash fill the header's name field exactly.
        let mut full = vec![b'd'; 99];
        full.extend(b"/file.txt");
        let mut name = full.clone();
        name.push(0);
        let mut tar = Vec::new();
        tar.extend(header(b"././@LongLink", b'L', name.len() as u64));
        tar.extend(padded(&name));
        tar.extend(header(&full[..100], b'0', 600));
        tar.extend(padded(&[7u8; 600]));
        tar.extend(header(b"old/", b'0', 0));
        tar.extend(header(b"after", b'0', 0));
        tar.extend([0u8; 2 * BLOCK]);

        let mut state = reader(tar);
        let first = state.next().unwrap().unwrap();
        assert_eq!(
            (first.name, first.kind, first.size),
            (full, Kind::File, 600)
        );
        assert_eq!(state.next().unwrap().unwrap().kind, Kind::Directory);
        assert_eq!(state.next().unwrap().unwrap().name, b"after");
        assert!(state.next().unwrap().is_none());
    }

    #[test]
    fn a_link_or_directory_has_no_data_whatever_its_size_says() {
        let mut tar = Vec::new();
        tar.extend(header(b"link", b'2', 4096));
        tar.extend(header(b"dir/", b'5', 4096));
        tar.extend(header(b"after", b'0', 0));
        tar.extend([0u8; 2 * BLOCK]);
        assert_eq!(names(tar).unwrap(), ["link", "dir/", "after"]);
    }

    #[test]
    fn joins_the_ustar_prefix() {
        let mut block = header(b"file.txt", b'0', 0);
        block[345..351].copy_from_slice(b"a/deep");
        seal(&mut block);
        let mut tar = block.to_vec();
        tar.extend([0u8; 2 * BLOCK]);
        assert_eq!(names(tar).unwrap(), ["a/deep/file.txt"]);
    }

    #[test]
    fn refuses_what_is_not_a_whole_archive() {
        let invalid = |bytes: Vec<u8>| match names(bytes) {
            Err(Fail::Invalid(why)) => why,
            other => panic!("expected Invalid, got {other:?}"),
        };
        assert_eq!(invalid(Vec::new()), "not a tar archive");
        assert_eq!(invalid(b"hello".to_vec()), "not a tar archive");
        assert_eq!(invalid(vec![0u8; BLOCK]), "not a tar archive");
        let mut zeros_then = vec![0u8; BLOCK];
        zeros_then.extend([b'x'; BLOCK]);
        assert_eq!(invalid(zeros_then), "not a tar archive");
        // Its end marker alone: an archive of nothing.
        assert!(names(vec![0u8; 2 * BLOCK]).unwrap().is_empty());
        assert!(names(vec![0u8; 20 * BLOCK]).unwrap().is_empty());
        assert_eq!(invalid(vec![b'x'; BLOCK]), "not a tar archive");

        let mut cut = header(b"a.txt", b'0', 1000).to_vec();
        cut.extend([1u8; 600]);
        assert_eq!(invalid(cut), "the archive is cut short");

        let mut bad = header(b"a.txt", b'0', 0).to_vec();
        let mut second = header(b"b.txt", b'0', 0);
        second[0] = b'c';
        bad.extend(second);
        assert!(invalid(bad).starts_with("a header's checksum does not match"));

        let mut huge = header(b"x", b'x', META_MAX + 1).to_vec();
        huge.extend([0u8; BLOCK]);
        assert!(invalid(huge).contains("over the"));

        // An end of input on a block boundary, with no end marker, is an end.
        assert_eq!(
            names(header(b"a.txt", b'0', 0).to_vec()).unwrap(),
            ["a.txt"]
        );
    }

    #[test]
    fn zeros_after_a_compressed_stream_are_padding() {
        let mut tar = header(b"a.txt", b'0', 5).to_vec();
        tar.extend(padded(b"hello"));
        tar.extend([0u8; 2 * BLOCK]);
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        io::Write::write_all(&mut gz, &tar).unwrap();
        let gz = gz.finish().unwrap();
        let mut bz = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::default());
        io::Write::write_all(&mut bz, &tar).unwrap();
        let bz = bz.finish().unwrap();

        for packed in [gz, bz] {
            let mut zeros = packed.clone();
            zeros.extend([0u8; 3000]);
            assert_eq!(names(zeros).unwrap(), ["a.txt"]);

            // A second stream after the padding is more of the same.
            let mut twice = packed.clone();
            twice.extend([0u8; 100]);
            twice.extend(&packed);
            assert_eq!(names(twice).unwrap(), ["a.txt"]);

            let mut junk = packed.clone();
            junk.extend([0u8; 100]);
            junk.extend(b"not a stream");
            assert!(matches!(names(junk), Err(Fail::Io(_))));

            // A checksum that does not hold is still found.
            let mut bad = packed.clone();
            let at = bad.len() - 6;
            bad[at] ^= 0xff;
            assert!(matches!(names(bad), Err(Fail::Io(_))));
        }
    }

    #[test]
    fn a_name_with_a_nul_is_refused() {
        for pax in [&b"16 path=a\0b.txt\n"[..], b"16 linkpath=a\0b\n"] {
            let mut tar = header(b"PaxHeader", b'x', pax.len() as u64).to_vec();
            tar.extend(padded(pax));
            tar.extend(header(b"x", b'0', 0));
            tar.extend([0u8; 2 * BLOCK]);
            assert!(matches!(names(tar), Err(Fail::Invalid(_))));
        }
    }

    #[test]
    fn refuses_sparse_and_multi_volume() {
        for flag in *b"SM" {
            let mut tar = header(b"x", flag, 0).to_vec();
            tar.extend([0u8; 2 * BLOCK]);
            assert!(matches!(names(tar), Err(Fail::Unsupported(_))));
        }
        let pax = b"22 GNU.sparse.major=1\n";
        let mut tar = header(b"PaxHeader", b'x', pax.len() as u64).to_vec();
        tar.extend(padded(pax));
        tar.extend(header(b"x", b'0', 0));
        assert!(matches!(names(tar), Err(Fail::Unsupported(_))));
    }

    #[test]
    fn stops_at_the_ratio_and_input_limits() {
        let mut tar = header(b"zeros", b'0', 8 << 20).to_vec();
        tar.extend(vec![0u8; 8 << 20]);
        tar.extend([0u8; 2 * BLOCK]);
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        io::Write::write_all(&mut gz, &tar).unwrap();
        let gz = gz.finish().unwrap();

        let mut state = reader(gz.clone());
        assert_eq!(state.compression, Compression::Gzip);
        state.max_ratio = Some(100.0);
        state.next().unwrap();
        assert!(matches!(state.next(), Err(Fail::Ratio(ratio, _)) if ratio > 100.0));

        let mut state = reader(gz);
        state.max_input = Some(1024);
        assert!(matches!(state.next(), Err(Fail::Input(_, 1024))));
    }

    #[test]
    fn property_any_bytes_are_survived() {
        let mut rng = Rng::new(21);
        for _ in 0..CASES {
            // Random bytes, and a real archive with bytes of it changed.
            let bytes = if rng.below(2) == 0 {
                rng.bytes(3 * BLOCK)
            } else {
                let pax = b"12 path=a/b\n";
                let mut tar = header(b"PaxHeader", b'x', pax.len() as u64).to_vec();
                tar.extend(padded(pax));
                tar.extend(header(b"a.txt", b'0', 700));
                tar.extend(padded(&[1u8; 700]));
                tar.extend([0u8; 2 * BLOCK]);
                for _ in 0..rng.below(4) {
                    let at = rng.below(tar.len());
                    tar[at] = rng.next() as u8;
                }
                tar.truncate(rng.below(tar.len() + 1));
                tar
            };
            let mut state = reader(bytes);
            while let Ok(Some(meta)) = state.next() {
                let mut data = vec![0u8; meta.size.min(4096) as usize];
                if state.read_data(&mut data).is_err() {
                    break;
                }
            }
        }
    }

    #[test]
    fn property_any_header_fields_are_survived() {
        let mut rng = Rng::new(22);
        for _ in 0..CASES {
            let mut block = [0u8; BLOCK];
            for b in block.iter_mut() {
                *b = rng.next() as u8;
            }
            seal(&mut block);
            let _ = parse_header(&block);
            let _ = parse_pax(&rng.bytes(64));
            let _ = pax_time(&rng.bytes(24));
        }
    }
}
