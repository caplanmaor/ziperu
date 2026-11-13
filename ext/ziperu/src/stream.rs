//! `Ziperu::Native::StreamReader`: reads an archive from a pipe or socket
//! in one pass, local header by local header, never holding more than an
//! entry's worth of it.
//!
//! The central directory is at the end, out of reach until everything
//! before it has gone by, so this is what can be known from the local
//! headers alone (no comments, no external attributes). Most streamed
//! archives put an entry's sizes in a data descriptor after its data
//! (general-purpose bit 3), which the zip crate's own stream reader does
//! not take; here a Deflated entry is inflated until the deflate stream
//! ends, and its descriptor read after it. An entry whose sizes are in its
//! local header is read for any method the crate knows, through the crate,
//! with its compressed bytes in memory. A Stored or other entry with its
//! sizes only after the data cannot be delimited in one pass: that raises
//! `Ziperu::Native::UnsupportedError`.

use std::cell::{RefCell, RefMut};
use std::io::{self, BufRead, BufReader, Cursor, Read};

use flate2::{Decompress, FlushDecompress, Status};
use magnus::{
    gc::Marker, prelude::*, typed_data::DataTypeFunctions, value::Opaque, Error, RHash, RString,
    Ruby, TypedData, Value,
};
use zip::read::{read_zipfile_from_stream_with_options, ZipReadOptions};

use crate::errors::{busy_error, read_error, size_limit_error, ERROR};
use crate::rb::{bytes_of, copy_chunk};
use crate::source::ruby_io_error;
use crate::zipcrypto::{DATA_DESCRIPTOR_FLAG, ENCRYPTED_FLAG};

const LOCAL_SIGNATURE: u32 = 0x0403_4b50;
const CENTRAL_SIGNATURE: u32 = 0x0201_4b50;
const END_SIGNATURE: u32 = 0x0605_4b50;
const ZIP64_END_SIGNATURE: u32 = 0x0606_4b50;
const DESCRIPTOR_SIGNATURE: u32 = 0x0807_4b50;
/// A split archive's first segment starts with this; one written in a
/// single piece sometimes does too, and it is skipped.
const SPANNING_SIGNATURE: u32 = 0x3030_4b50;
const ZIP64_EXTRA_ID: u16 = 0x0001;
const STORED: u16 = 0;
const DEFLATED: u16 = 8;
const CHUNK: usize = 64 * 1024;
/// Entries read through the crate have their compressed bytes in memory;
/// never reserve more than this on the strength of a header field.
const CAPACITY_HINT_MAX: u64 = 1 << 20;

/// A Ruby IO read through `read(n)`, forward only.
struct RubyRead {
    io: Opaque<Value>,
}

impl Read for RubyRead {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let ruby = Ruby::get().map_err(|e| io::Error::other(e.to_string()))?;
        let io = ruby.get_inner(self.io);
        let chunk: Option<RString> = io.funcall("read", (buf.len(),)).map_err(ruby_io_error)?;
        Ok(copy_chunk(chunk, buf))
    }
}

/// How the current entry's data is being read.
enum Body {
    /// Its sizes are known: the bytes as they come (Stored), or inflated.
    Stored {
        remaining: u64,
    },
    Inflate(Box<Decompress>),
    /// Decoded through the crate from its compressed bytes in memory.
    Buffered(Cursor<Vec<u8>>),
}

struct Current {
    body: Body,
    /// The CRC and sizes from the local header, or from the descriptor
    /// once read; `None` until known.
    crc: Option<u32>,
    size: Option<u64>,
    /// Bit 3: a data descriptor follows the data.
    descriptor: bool,
    zip64: bool,
    hasher: crc32fast::Hasher,
    produced: u64,
    /// The data has been read to its end and checked.
    finished: bool,
}

struct State {
    input: BufReader<RubyRead>,
    current: Option<Current>,
    /// The central directory (or the end of the input) was reached.
    done: bool,
    /// Bytes taken from the input so far, which is where the next local
    /// header starts.
    offset: u64,
    password: Option<Vec<u8>>,
    enforce_size: bool,
}

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::StreamReader", free_immediately, mark)]
pub struct StreamReader {
    inner: RefCell<Option<State>>,
    io: Opaque<Value>,
}

impl DataTypeFunctions for StreamReader {
    fn mark(&self, marker: &Marker) {
        marker.mark(self.io);
    }
}

impl StreamReader {
    pub fn new(io: Value, password: Option<RString>, enforce_size: bool) -> Result<Self, Error> {
        let opaque = Opaque::from(io);
        Ok(Self {
            inner: RefCell::new(Some(State {
                input: BufReader::with_capacity(CHUNK, RubyRead { io: opaque }),
                current: None,
                done: false,
                offset: 0,
                password: password.map(bytes_of),
                enforce_size,
            })),
            io: opaque,
        })
    }

    fn state(&self, ruby: &Ruby) -> Result<RefMut<'_, State>, Error> {
        let guard = self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "stream reader"))?;
        RefMut::filter_map(guard, Option::as_mut)
            .map_err(|_| Error::new(ruby.exception_io_error(), "closed stream"))
    }

    pub fn close(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "stream reader"))?
            .take();
        Ok(())
    }

    /// Skips what is left of the current entry and reads the next local
    /// header: a Hash shaped as `Archive#entries` gives (sizes nil where
    /// the header defers them to a descriptor), or nil at the central
    /// directory.
    pub fn next_entry(ruby: &Ruby, rb_self: &Self) -> Result<Option<RHash>, Error> {
        let mut state = rb_self.state(ruby)?;
        if state.current.is_some() {
            // The rest of the entry, read and checked: nothing is skipped
            // unseen, so a corrupt entry fails here as it would when read.
            let mut sink = Vec::new();
            loop {
                sink.clear();
                if !state.fill(ruby, &mut sink, CHUNK)? {
                    break;
                }
            }
            state.current = None;
        }
        if state.done {
            return Ok(None);
        }
        state.read_header(ruby)
    }

    /// Up to `maxlen` bytes of the current entry (CHUNK when nil), or nil
    /// at its end.
    pub fn read(
        ruby: &Ruby,
        rb_self: &Self,
        maxlen: Option<usize>,
    ) -> Result<Option<RString>, Error> {
        let mut state = rb_self.state(ruby)?;
        let want = maxlen.unwrap_or(CHUNK);
        if want == 0 {
            return Ok(Some(ruby.str_new("")));
        }
        let mut out = Vec::with_capacity(want.min(CHUNK));
        while out.len() < want {
            let left = want - out.len();
            if !state.fill(ruby, &mut out, left)? {
                break;
            }
        }
        if out.is_empty() {
            return Ok(None);
        }
        Ok(Some(ruby.str_from_slice(&out)))
    }

    pub fn is_eof(ruby: &Ruby, rb_self: &Self) -> Result<bool, Error> {
        let state = rb_self.state(ruby)?;
        Ok(state.current.as_ref().is_none_or(|c| c.finished))
    }

    /// The current entry's `[crc, size]` as read, once its data has been
    /// read to the end, or nil before: for an entry whose header deferred
    /// them to a descriptor, what it came to.
    pub fn trailer(ruby: &Ruby, rb_self: &Self) -> Result<Option<(u32, u64)>, Error> {
        let state = rb_self.state(ruby)?;
        Ok(state
            .current
            .as_ref()
            .filter(|c| c.finished)
            .map(|c| (c.hasher.clone().finalize(), c.produced)))
    }
}

impl State {
    fn read_u32(&mut self) -> io::Result<u32> {
        let mut b = [0u8; 4];
        self.input.read_exact(&mut b)?;
        self.offset += 4;
        Ok(u32::from_le_bytes(b))
    }

    fn read_vec(&mut self, len: usize) -> io::Result<Vec<u8>> {
        let mut v = vec![0u8; len];
        self.input.read_exact(&mut v)?;
        self.offset += len as u64;
        Ok(v)
    }

    fn read_header(&mut self, ruby: &Ruby) -> Result<Option<RHash>, Error> {
        let header_offset = self.offset;
        let signature = match self.read_u32() {
            Ok(s) => s,
            // An input that ends where an entry could start has no more.
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof && self.offset == 0 => {
                self.done = true;
                return Ok(None);
            }
            Err(e) => return Err(stream_error(ruby, e)),
        };
        let signature = if signature == SPANNING_SIGNATURE && header_offset == 0 {
            self.read_u32().map_err(|e| stream_error(ruby, e))?
        } else {
            signature
        };
        match signature {
            LOCAL_SIGNATURE => {}
            CENTRAL_SIGNATURE | END_SIGNATURE | ZIP64_END_SIGNATURE => {
                self.done = true;
                return Ok(None);
            }
            _ => {
                return Err(Error::new(
                    ruby.get_inner(&ERROR),
                    format!("invalid Zip archive: no local header at offset {header_offset}"),
                ))
            }
        }
        let fixed = self.read_vec(26).map_err(|e| stream_error(ruby, e))?;
        let u16_at = |i: usize| u16::from_le_bytes([fixed[i], fixed[i + 1]]);
        let u32_at =
            |i: usize| u32::from_le_bytes([fixed[i], fixed[i + 1], fixed[i + 2], fixed[i + 3]]);
        let flags = u16_at(2);
        let method = u16_at(4);
        let dos_time = u16_at(6);
        let dos_date = u16_at(8);
        let crc = u32_at(10);
        let mut csize = u64::from(u32_at(14));
        let mut size = u64::from(u32_at(18));
        let name = self
            .read_vec(u16_at(22) as usize)
            .map_err(|e| stream_error(ruby, e))?;
        let extra = self
            .read_vec(u16_at(24) as usize)
            .map_err(|e| stream_error(ruby, e))?;
        let zip64 = apply_zip64(&extra, &mut size, &mut csize);
        let descriptor = flags & DATA_DESCRIPTOR_FLAG != 0;
        let encrypted = flags & ENCRYPTED_FLAG != 0;

        let unsupported = |what: &str| {
            Error::new(
                ruby.get_inner(&crate::errors::NATIVE_UNSUPPORTED_ERROR),
                format!(
                    "entry '{}': {what} cannot be read from a stream in one pass; \
                     read the archive from a file or a seekable IO",
                    String::from_utf8_lossy(&name)
                ),
            )
        };
        let body = if descriptor {
            if method != DEFLATED || encrypted {
                return Err(unsupported(
                    "an entry whose sizes follow its data, unless Deflated and unencrypted,",
                ));
            }
            Body::Inflate(Box::new(Decompress::new(false)))
        } else if method == STORED && !encrypted {
            Body::Stored { remaining: csize }
        } else if method == DEFLATED && !encrypted {
            Body::Inflate(Box::new(Decompress::new(false)))
        } else {
            // Any other method, or encryption: the crate decodes it from
            // the compressed bytes, given a local header to start from.
            let mut raw = Vec::with_capacity(30 + name.len() + extra.len());
            raw.extend_from_slice(&LOCAL_SIGNATURE.to_le_bytes());
            raw.extend_from_slice(&fixed);
            raw.extend_from_slice(&name);
            raw.extend_from_slice(&extra);
            raw.reserve(csize.min(CAPACITY_HINT_MAX) as usize);
            let copied = io::copy(&mut (&mut self.input).take(csize), &mut raw)
                .map_err(|e| stream_error(ruby, e))?;
            self.offset += copied;
            if copied != csize {
                return Err(stream_error(ruby, io::ErrorKind::UnexpectedEof.into()));
            }
            let mut cursor = Cursor::new(raw);
            let options = ZipReadOptions::new().password(self.password.as_deref());
            let mut file = read_zipfile_from_stream_with_options(&mut cursor, options)
                .map_err(|e| crate::errors::zip_read_error(ruby, e))?
                .ok_or_else(|| Error::new(ruby.get_inner(&ERROR), "invalid Zip archive"))?;
            let mut decoded = Vec::with_capacity(size.min(CAPACITY_HINT_MAX) as usize);
            file.read_to_end(&mut decoded)
                .map_err(|e| read_error(ruby, e))?;
            drop(file);
            Body::Buffered(Cursor::new(decoded))
        };

        let h = ruby.hash_new();
        h.aset(ruby.to_symbol("index"), ())?;
        h.aset(ruby.to_symbol("name"), ruby.str_from_slice(&name))?;
        let (known_size, known_csize, known_crc) = if descriptor {
            (None, None, None)
        } else {
            (Some(size), Some(csize), Some(crc))
        };
        h.aset(ruby.to_symbol("size"), known_size)?;
        h.aset(ruby.to_symbol("compressed_size"), known_csize)?;
        h.aset(ruby.to_symbol("crc"), known_crc)?;
        h.aset(ruby.to_symbol("compression_method"), method)?;
        h.aset(ruby.to_symbol("flags"), flags)?;
        h.aset(ruby.to_symbol("external_attributes"), 0)?;
        h.aset(ruby.to_symbol("fstype"), 0)?;
        h.aset(ruby.to_symbol("version_made_by"), u16_at(0) & 0xFF)?;
        h.aset(ruby.to_symbol("dos_date"), dos_date)?;
        h.aset(ruby.to_symbol("dos_time"), dos_time)?;
        h.aset(ruby.to_symbol("comment"), ruby.str_new(""))?;
        h.aset(ruby.to_symbol("extra"), ruby.str_from_slice(&extra))?;
        h.aset(ruby.to_symbol("header_offset"), header_offset)?;

        let buffered = matches!(body, Body::Buffered(_));
        self.current = Some(Current {
            body,
            crc: (!descriptor).then_some(crc),
            size: (!descriptor).then_some(size),
            descriptor,
            zip64,
            hasher: crc32fast::Hasher::new(),
            produced: 0,
            finished: false,
        });
        if buffered {
            // The crate has checked the CRC already; nothing to compare.
            if let Some(c) = &mut self.current {
                c.crc = None;
            }
        }
        Ok(Some(h))
    }

    /// Appends up to `want` bytes of the current entry to `out`; false
    /// once its data has ended (and been checked).
    fn fill(&mut self, ruby: &Ruby, out: &mut Vec<u8>, want: usize) -> Result<bool, Error> {
        let Some(current) = self.current.as_mut() else {
            return Ok(false);
        };
        if current.finished {
            return Ok(false);
        }
        // A step at a time, whatever the caller asked for: the buffer is
        // grown (and zeroed) by `want` before each read, and the caller
        // comes back for the rest.
        let want = want.min(CHUNK);
        let start = out.len();
        let ended = match &mut current.body {
            Body::Stored { remaining } => {
                let step = (*remaining).min(want as u64) as usize;
                if step == 0 {
                    true
                } else {
                    out.resize(start + step, 0);
                    let n = self
                        .input
                        .read(&mut out[start..])
                        .map_err(|e| stream_error(ruby, e))?;
                    out.truncate(start + n);
                    if n == 0 {
                        return Err(stream_error(ruby, io::ErrorKind::UnexpectedEof.into()));
                    }
                    *remaining -= n as u64;
                    self.offset += n as u64;
                    *remaining == 0
                }
            }
            Body::Inflate(d) => {
                let input = self.input.fill_buf().map_err(|e| stream_error(ruby, e))?;
                if input.is_empty() {
                    return Err(stream_error(ruby, io::ErrorKind::UnexpectedEof.into()));
                }
                out.resize(start + want, 0);
                let (before_in, before_out) = (d.total_in(), d.total_out());
                let status = d
                    .decompress(input, &mut out[start..], FlushDecompress::None)
                    .map_err(|e| read_error(ruby, io::Error::new(io::ErrorKind::InvalidData, e)))?;
                let consumed = (d.total_in() - before_in) as usize;
                let produced = d.total_out() - before_out;
                out.truncate(start + produced as usize);
                self.input.consume(consumed);
                self.offset += consumed as u64;
                if produced == 0 && consumed == 0 && status != Status::StreamEnd {
                    return Err(read_error(
                        ruby,
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            "deflate stream makes no progress",
                        ),
                    ));
                }
                status == Status::StreamEnd
            }
            Body::Buffered(c) => {
                out.resize(start + want, 0);
                let n = c.read(&mut out[start..]).map_err(|e| read_error(ruby, e))?;
                out.truncate(start + n);
                n == 0
            }
        };
        let current = self.current.as_mut().expect("checked above");
        let fresh = &out[start..];
        current.hasher.update(fresh);
        current.produced += fresh.len() as u64;
        if let Some(size) = current.size {
            if self.enforce_size && current.produced > size {
                return Err(size_limit_error(ruby));
            }
        }
        if ended {
            self.finish_entry(ruby)?;
        }
        Ok(!fresh.is_empty() || !ended)
    }

    /// The entry's data has ended: read its descriptor, if it has one, and
    /// check the CRC and size.
    fn finish_entry(&mut self, ruby: &Ruby) -> Result<(), Error> {
        let (descriptor, zip64) = {
            let c = self.current.as_ref().expect("an entry in progress");
            (c.descriptor, c.zip64)
        };
        if descriptor {
            let first = self.read_u32().map_err(|e| stream_error(ruby, e))?;
            let crc = if first == DESCRIPTOR_SIGNATURE {
                self.read_u32().map_err(|e| stream_error(ruby, e))?
            } else {
                first
            };
            let sizes = self
                .read_vec(if zip64 { 16 } else { 8 })
                .map_err(|e| stream_error(ruby, e))?;
            let size = if zip64 {
                u64::from_le_bytes(sizes[8..16].try_into().expect("8 bytes"))
            } else {
                u64::from(u32::from_le_bytes(sizes[4..8].try_into().expect("4 bytes")))
            };
            let c = self.current.as_mut().expect("an entry in progress");
            c.crc = Some(crc);
            c.size = Some(size);
        }
        let c = self.current.as_mut().expect("an entry in progress");
        c.finished = true;
        if let Some(expected) = c.crc {
            if c.hasher.clone().finalize() != expected {
                return Err(read_error(
                    ruby,
                    io::Error::new(io::ErrorKind::InvalidData, "invalid checksum"),
                ));
            }
        }
        if let Some(size) = c.size {
            if c.produced < size {
                return Err(read_error(
                    ruby,
                    io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "entry is shorter than its declared size",
                    ),
                ));
            }
        }
        Ok(())
    }
}

/// The 64-bit sizes of a zip64 extra field, where the header saturated
/// them; whether there was one (which makes the descriptor's sizes 64-bit).
fn apply_zip64(extra: &[u8], size: &mut u64, csize: &mut u64) -> bool {
    let mut rest = extra;
    while rest.len() >= 4 {
        let id = u16::from_le_bytes([rest[0], rest[1]]);
        let len = u16::from_le_bytes([rest[2], rest[3]]) as usize;
        rest = &rest[4..];
        if rest.len() < len {
            return false;
        }
        let (mut data, tail) = rest.split_at(len);
        rest = tail;
        if id != ZIP64_EXTRA_ID {
            continue;
        }
        for field in [size, csize] {
            if *field != u64::from(u32::MAX) {
                continue;
            }
            let Some((value, more)) = data.split_first_chunk::<8>() else {
                return true;
            };
            *field = u64::from_le_bytes(*value);
            data = more;
        }
        return true;
    }
    false
}

/// An error reading the input: an archive cut short is a broken archive.
fn stream_error(ruby: &Ruby, err: io::Error) -> Error {
    crate::errors::header_error(ruby, err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_rng::{Rng, CASES};

    const SATURATED: u64 = u32::MAX as u64;

    fn field(id: u16, data: &[u8]) -> Vec<u8> {
        let mut out = id.to_le_bytes().to_vec();
        out.extend_from_slice(&(data.len() as u16).to_le_bytes());
        out.extend_from_slice(data);
        out
    }

    #[test]
    fn property_any_extra_bytes_are_survived() {
        let mut rng = Rng::new(4);
        for _ in 0..CASES {
            let mut extra = rng.bytes(64);
            if rng.below(2) == 0 && extra.len() >= 2 {
                extra[..2].copy_from_slice(&ZIP64_EXTRA_ID.to_le_bytes());
            }
            let (mut size, mut csize) = (SATURATED, SATURATED);
            apply_zip64(&extra, &mut size, &mut csize);
        }
    }

    #[test]
    fn property_the_zip64_field_fills_only_saturated_sizes() {
        let mut rng = Rng::new(5);
        for case in 0..CASES {
            let (true_size, true_csize) = (rng.next(), rng.next());
            let size_saturated = rng.below(2) == 0;
            let csize_saturated = rng.below(2) == 0;
            let mut data = Vec::new();
            if size_saturated {
                data.extend_from_slice(&true_size.to_le_bytes());
            }
            if csize_saturated {
                data.extend_from_slice(&true_csize.to_le_bytes());
            }
            // Other fields before it, as writers put them.
            let mut extra = Vec::new();
            for _ in 0..rng.below(3) {
                let other = rng.bytes(12);
                extra.extend(field(0x5455 + rng.below(4) as u16, &other));
            }
            extra.extend(field(ZIP64_EXTRA_ID, &data));
            let mut size = if size_saturated { SATURATED } else { 10 };
            let mut csize = if csize_saturated { SATURATED } else { 20 };
            assert!(apply_zip64(&extra, &mut size, &mut csize), "case {case}");
            assert_eq!(
                size,
                if size_saturated { true_size } else { 10 },
                "case {case}"
            );
            assert_eq!(
                csize,
                if csize_saturated { true_csize } else { 20 },
                "case {case}"
            );
        }
    }

    #[test]
    fn property_without_a_zip64_field_nothing_changes() {
        let mut rng = Rng::new(6);
        for case in 0..CASES {
            let mut extra = Vec::new();
            for _ in 0..rng.below(4) {
                let other = rng.bytes(20);
                extra.extend(field(0x000A + rng.below(0x100) as u16, &other));
            }
            let (mut size, mut csize) = (SATURATED, 7);
            assert!(!apply_zip64(&extra, &mut size, &mut csize), "case {case}");
            assert_eq!((size, csize), (SATURATED, 7), "case {case}");
        }
    }
}
