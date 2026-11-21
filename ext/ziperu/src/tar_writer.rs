//! `Ziperu::Native::TarWriter`: writes a tar archive front to back, to a
//! file or to any Ruby IO with `write` (a pipe, a socket, a response
//! body), plain or compressed with gzip, zstd, xz or bzip2.
//!
//! What is written is POSIX.1-2001 (pax) as GNU tar, bsdtar and Python
//! write it: a ustar header for every entry, and before it an extended
//! header only when something does not fit the ustar fields: a name or
//! link target over 100 bytes or not ASCII, a size of 8 GiB or more, a
//! time before 1970, an id over 2097151, an owner name over 32 bytes or
//! not ASCII. An archive of ordinary names is plain ustar, which every
//! reader takes.
//!
//! An entry's size goes in its header, ahead of its data, so it is fixed
//! when the entry starts: `write` refuses more than was declared, and the
//! next entry (or `close`) refuses to follow one that got less. Ruby
//! decides what each entry says; this side lays out the bytes.
//!
//! gzip and zstd streams are written with nothing of this machine in
//! them (no time, name or system in the gzip header), and a zstd frame
//! with its checksum, as the `zstd` command writes it: tar has no check
//! of its own on an entry's data.

use std::cell::{Cell, RefCell, RefMut};
use std::fs;
use std::io::{self, BufWriter, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use magnus::{
    gc::Marker, prelude::*, typed_data::DataTypeFunctions, value::Opaque, Error, RArray, RString,
    Ruby, TypedData, Value,
};

use crate::errors::{busy_error, io_error, ERROR};
use crate::gvl::maybe_without_gvl;
use crate::source::ruby_io_error;

const BLOCK: usize = 512;
const CHUNK: usize = 64 * 1024;
/// The name an extended header goes by, as Python writes it.
const PAX_NAME: &[u8] = b"././@PaxHeader";

/// Writes to a Ruby IO. Once detached it swallows everything: an encoder
/// dropped unfinished writes its last bytes from the GC's free, where no
/// Ruby object may be touched. A write that fails detaches it too, so
/// that an IO which raised is not handed the rest on the way out.
struct RubyWrite {
    io: Opaque<Value>,
    attached: Arc<AtomicBool>,
}

impl Write for RubyWrite {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() || !self.attached.load(Ordering::Acquire) {
            return Ok(buf.len());
        }
        let ruby = Ruby::get().map_err(|e| io::Error::other(e.to_string()))?;
        let io = ruby.get_inner(self.io);
        let chunk = ruby.str_from_slice(buf);
        if let Err(e) = io.funcall::<_, _, Value>("write", (chunk,)) {
            self.attached.store(false, Ordering::Release);
            return Err(ruby_io_error(e));
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

type Out = Box<dyn Write + Send>;

/// The tar stream on its way out, through a codec or not.
enum Encoder {
    Plain(Out),
    Gzip(flate2::write::GzEncoder<Out>),
    Zstd(zstd::stream::write::Encoder<'static, Out>),
    Xz(Box<lzma_rust2::XzWriter<Out>>),
    Bzip2(bzip2::write::BzEncoder<Out>),
}

impl Encoder {
    /// `level` is the codec's own scale, checked by Ruby; `None` is its
    /// usual default.
    fn new(out: Out, compression: &str, level: Option<u32>) -> io::Result<Self> {
        Ok(match compression {
            "none" => Encoder::Plain(out),
            // No name and no time in the header, and no operating system
            // (255 is "unknown"), so the same input gives the same bytes
            // on every machine.
            "gzip" => Encoder::Gzip(
                flate2::GzBuilder::new()
                    .operating_system(255)
                    .write(out, flate2::Compression::new(level.unwrap_or(6))),
            ),
            "zstd" => {
                let mut encoder =
                    zstd::stream::write::Encoder::new(out, level.map_or(3, |l| l as i32))?;
                encoder.include_checksum(true)?;
                Encoder::Zstd(encoder)
            }
            "xz" => {
                let options = lzma_rust2::XzOptions::with_preset(level.unwrap_or(6));
                Encoder::Xz(Box::new(
                    lzma_rust2::XzWriter::new(out, options).map_err(io::Error::other)?,
                ))
            }
            "bzip2" => Encoder::Bzip2(bzip2::write::BzEncoder::new(
                out,
                bzip2::Compression::new(level.unwrap_or(6)),
            )),
            other => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown compression {other:?}"),
                ))
            }
        })
    }

    /// Ends the compressed stream and flushes what is under it.
    fn finish(self) -> io::Result<()> {
        let mut out = match self {
            Encoder::Plain(out) => out,
            Encoder::Gzip(e) => e.finish()?,
            Encoder::Zstd(e) => e.finish()?,
            Encoder::Xz(e) => e.finish().map_err(io::Error::other)?,
            Encoder::Bzip2(e) => e.finish()?,
        };
        out.flush()
    }
}

impl Write for Encoder {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Encoder::Plain(w) => w.write(buf),
            Encoder::Gzip(w) => w.write(buf),
            Encoder::Zstd(w) => w.write(buf),
            Encoder::Xz(w) => w.write(buf),
            Encoder::Bzip2(w) => w.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Encoder::Plain(w) => w.flush(),
            Encoder::Gzip(w) => w.flush(),
            Encoder::Zstd(w) => w.flush(),
            Encoder::Xz(w) => w.flush(),
            Encoder::Bzip2(w) => w.flush(),
        }
    }
}

/// What one entry's header says.
struct Fields {
    name: Vec<u8>,
    link: Vec<u8>,
    flag: u8,
    size: u64,
    mode: u32,
    mtime: i64,
    uid: u64,
    gid: u64,
    uname: Vec<u8>,
    gname: Vec<u8>,
}

/// Writes `value` into a numeric field as zero-padded octal and a NUL.
/// False, with the field left at zero, when it does not fit.
fn octal(field: &mut [u8], value: u64) -> bool {
    let digits = field.len() - 1;
    let fits = digits >= 22 || value < 1u64 << (3 * digits);
    let text = format!("{:0digits$o}", if fits { value } else { 0 });
    field[..digits].copy_from_slice(text.as_bytes());
    field[digits] = 0;
    fits
}

/// Writes `value` into a text field; false when it has to go in an
/// extended header instead (too long, or not ASCII, which ustar does not
/// promise to carry). What fits of it is written either way.
fn text(field: &mut [u8], value: &[u8], directory: bool) -> bool {
    let fits = value.len() <= field.len() && value.is_ascii();
    let mut kept = &value[..value.len().min(field.len())];
    // A cut name must not end in a slash, which marks a directory to a
    // reader that has no use for the extended header.
    while !fits && !directory && kept.ends_with(b"/") {
        kept = &kept[..kept.len() - 1];
    }
    field[..kept.len()].copy_from_slice(kept);
    fits
}

/// The checksum of a header block: the sum of its bytes, the checksum
/// field itself counted as spaces.
fn seal(block: &mut [u8; BLOCK]) {
    block[148..156].fill(b' ');
    let sum: u32 = block.iter().map(|&b| u32::from(b)).sum();
    block[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
}

/// One record of an extended header: "LENGTH KEY=VALUE\n", the length
/// counting itself.
fn pax_record(key: &str, value: &[u8]) -> Vec<u8> {
    let body = key.len() + value.len() + 3;
    let mut total = body;
    loop {
        let next = body + total.to_string().len();
        if next == total {
            break;
        }
        total = next;
    }
    let mut record = format!("{total} {key}=").into_bytes();
    record.extend_from_slice(value);
    record.push(b'\n');
    record
}

/// The header block for `fields`, and the records for what did not fit it.
fn ustar(fields: &Fields) -> ([u8; BLOCK], Vec<u8>) {
    let mut block = [0u8; BLOCK];
    let mut pax = Vec::new();
    let directory = fields.flag == b'5';
    if !text(&mut block[0..100], &fields.name, directory) {
        pax.extend(pax_record("path", &fields.name));
    }
    octal(&mut block[100..108], u64::from(fields.mode & 0o7777));
    if !octal(&mut block[108..116], fields.uid) {
        pax.extend(pax_record("uid", fields.uid.to_string().as_bytes()));
    }
    if !octal(&mut block[116..124], fields.gid) {
        pax.extend(pax_record("gid", fields.gid.to_string().as_bytes()));
    }
    if !octal(&mut block[124..136], fields.size) {
        pax.extend(pax_record("size", fields.size.to_string().as_bytes()));
    }
    let mtime = u64::try_from(fields.mtime).ok();
    if !mtime.is_some_and(|t| octal(&mut block[136..148], t)) {
        octal(&mut block[136..148], 0);
        pax.extend(pax_record("mtime", fields.mtime.to_string().as_bytes()));
    }
    block[156] = fields.flag;
    if !text(&mut block[157..257], &fields.link, true) {
        pax.extend(pax_record("linkpath", &fields.link));
    }
    block[257..263].copy_from_slice(b"ustar\0");
    block[263..265].copy_from_slice(b"00");
    if !text(&mut block[265..297], &fields.uname, true) {
        pax.extend(pax_record("uname", &fields.uname));
    }
    if !text(&mut block[297..329], &fields.gname, true) {
        pax.extend(pax_record("gname", &fields.gname));
    }
    octal(&mut block[329..337], 0);
    octal(&mut block[337..345], 0);
    seal(&mut block);
    (block, pax)
}

/// Everything that goes ahead of an entry's data: an extended header and
/// its records when there are any, then the entry's own header.
fn headers(fields: &Fields) -> Vec<u8> {
    let (block, pax) = ustar(fields);
    let mut out = Vec::with_capacity(BLOCK);
    if !pax.is_empty() {
        let (extended, _) = ustar(&Fields {
            name: PAX_NAME.to_vec(),
            link: Vec::new(),
            flag: b'x',
            size: pax.len() as u64,
            mode: 0o644,
            mtime: fields.mtime.max(0),
            uid: 0,
            gid: 0,
            uname: Vec::new(),
            gname: Vec::new(),
        });
        out.extend_from_slice(&extended);
        out.extend_from_slice(&pax);
        out.resize(out.len() + padding_after(pax.len() as u64) as usize, 0);
    }
    out.extend_from_slice(&block);
    out
}

/// The zero bytes that bring `size` bytes of data up to a whole block.
fn padding_after(size: u64) -> u64 {
    (BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64
}

/// Why writing stopped.
#[derive(Debug)]
enum Fail {
    Io(io::Error),
    /// A file to add could not be opened. Nothing was written for it, so
    /// the archive can go on.
    Open(io::Error),
    /// The caller broke the format's terms; the archive cannot go on.
    Usage(String),
}

impl From<io::Error> for Fail {
    fn from(e: io::Error) -> Self {
        Fail::Io(e)
    }
}

struct State {
    out: Encoder,
    /// Data the current entry is still owed, and the padding after it.
    remaining: u64,
    padding: u64,
    /// The current entry's name, for messages.
    name: String,
}

impl State {
    fn pad(&mut self) -> io::Result<()> {
        let zeros = [0u8; BLOCK];
        self.out.write_all(&zeros[..self.padding as usize])?;
        self.padding = 0;
        Ok(())
    }

    /// The entry before must have had all its data.
    fn settled(&self) -> Result<(), Fail> {
        if self.remaining > 0 {
            return Err(Fail::Usage(format!(
                "entry '{}' is {} bytes short of the size its header gives",
                self.name, self.remaining
            )));
        }
        Ok(())
    }

    fn entry(&mut self, fields: &Fields) -> Result<(), Fail> {
        self.settled()?;
        self.out.write_all(&headers(fields))?;
        self.name = String::from_utf8_lossy(&fields.name).into_owned();
        self.remaining = fields.size;
        self.padding = padding_after(fields.size);
        if self.remaining == 0 {
            self.pad()?;
        }
        Ok(())
    }

    fn write(&mut self, data: &[u8]) -> Result<(), Fail> {
        if data.len() as u64 > self.remaining {
            return Err(Fail::Usage(format!(
                "entry '{}' was given {} bytes more than the size its header gives",
                self.name,
                data.len() as u64 - self.remaining
            )));
        }
        for piece in data.chunks(CHUNK) {
            crate::gvl::check()?;
            self.out.write_all(piece)?;
        }
        self.remaining -= data.len() as u64;
        if self.remaining == 0 {
            self.pad()?;
        }
        Ok(())
    }

    /// An entry for `fields` holding the file at `path`, which is opened
    /// before anything is written. A file that has shrunk since its size
    /// was taken is made up with zeros, as `tar` does, so the archive
    /// stays whole; returns the bytes it gave.
    fn add_file(&mut self, fields: &Fields, path: &str) -> Result<u64, Fail> {
        self.settled()?;
        let mut file = fs::File::open(path).map_err(Fail::Open)?;
        self.entry(fields)?;
        let mut buf = vec![0u8; CHUNK];
        let mut given = 0u64;
        while self.remaining > 0 {
            crate::gvl::check()?;
            let want = self.remaining.min(CHUNK as u64) as usize;
            let n = file.read(&mut buf[..want])?;
            if n == 0 {
                buf.fill(0);
                while self.remaining > 0 {
                    let step = self.remaining.min(CHUNK as u64) as usize;
                    self.out.write_all(&buf[..step])?;
                    self.remaining -= step as u64;
                }
                break;
            }
            self.out.write_all(&buf[..n])?;
            self.remaining -= n as u64;
            given += n as u64;
        }
        self.pad()?;
        Ok(given)
    }

    /// The end marker, and the end of the compressed stream.
    fn finish(mut self) -> Result<(), Fail> {
        self.settled()?;
        self.out.write_all(&[0u8; 2 * BLOCK])?;
        self.out.finish()?;
        Ok(())
    }
}

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::TarWriter", free_immediately, mark)]
pub struct TarWriter {
    inner: RefCell<Option<State>>,
    /// The Ruby IO written to, if that is what the output is.
    io: Option<Opaque<Value>>,
    attached: Arc<AtomicBool>,
    /// A write failed part-way: what reached the output is not known, so
    /// nothing more is written to it.
    failed: Cell<bool>,
}

impl DataTypeFunctions for TarWriter {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
    }
}

impl Drop for TarWriter {
    fn drop(&mut self) {
        // Before the encoder is dropped: see `RubyWrite`.
        self.attached.store(false, Ordering::Release);
    }
}

impl TarWriter {
    /// `compression` is "none", "gzip", "zstd", "xz" or "bzip2"; `level`
    /// the codec's own, nil for its default.
    pub fn open_path(
        ruby: &Ruby,
        path: String,
        compression: String,
        level: Option<u32>,
    ) -> Result<Self, Error> {
        // A new file and nothing else: the caller picks a name for the
        // archive in the making, and what may stand there already (a
        // link, left by someone who guessed it) is not written through.
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| io_error(ruby, e))?;
        Self::start(ruby, Box::new(file), None, &compression, level)
    }

    /// Any Ruby object with `write`; it is written forward only, and
    /// neither flushed nor closed.
    pub fn open_io(
        ruby: &Ruby,
        io: Value,
        compression: String,
        level: Option<u32>,
    ) -> Result<Self, Error> {
        let opaque = Opaque::from(io);
        let attached = Arc::new(AtomicBool::new(true));
        let out = RubyWrite {
            io: opaque,
            attached: Arc::clone(&attached),
        };
        let mut writer = Self::start(ruby, Box::new(out), Some(opaque), &compression, level)?;
        writer.attached = attached;
        Ok(writer)
    }

    fn start(
        ruby: &Ruby,
        out: Out,
        io: Option<Opaque<Value>>,
        compression: &str,
        level: Option<u32>,
    ) -> Result<Self, Error> {
        let out: Out = Box::new(BufWriter::with_capacity(CHUNK, out));
        let out = Encoder::new(out, compression, level).map_err(|e| {
            if e.kind() == io::ErrorKind::InvalidInput {
                Error::new(ruby.exception_arg_error(), e.to_string())
            } else {
                io_error(ruby, e)
            }
        })?;
        Ok(Self {
            inner: RefCell::new(Some(State {
                out,
                remaining: 0,
                padding: 0,
                name: String::new(),
            })),
            io,
            attached: Arc::new(AtomicBool::new(true)),
            failed: Cell::new(false),
        })
    }

    fn state(&self, ruby: &Ruby) -> Result<RefMut<'_, State>, Error> {
        if self.failed.get() {
            return Err(Error::new(
                ruby.exception_io_error(),
                "the tar writer failed earlier and cannot go on",
            ));
        }
        let guard = self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar writer"))?;
        RefMut::filter_map(guard, Option::as_mut)
            .map_err(|_| Error::new(ruby.exception_io_error(), "closed stream"))
    }

    fn raise(&self, ruby: &Ruby, fail: Fail) -> Error {
        match fail {
            Fail::Open(e) => io_error(ruby, e),
            Fail::Usage(why) => {
                self.failed.set(true);
                Error::new(ruby.get_inner(&ERROR), why)
            }
            Fail::Io(e) => {
                self.failed.set(true);
                io_error(ruby, e)
            }
        }
    }

    /// Runs `work` on the state, with the GVL released unless the output
    /// is a Ruby IO. A failure is final.
    fn run<T>(
        &self,
        ruby: &Ruby,
        work: impl FnOnce(&mut State) -> Result<T, Fail>,
    ) -> Result<T, Error> {
        let mut state = self.state(ruby)?;
        let outcome = maybe_without_gvl(self.io.is_some(), || work(&mut state));
        drop(state);
        outcome.map_err(|fail| self.raise(ruby, fail))
    }

    /// Starts an entry: `[name, link, flag, size, mode, mtime, uid, gid,
    /// uname, gname]`, the names as bytes, `flag` the type's character
    /// code, `mtime` in whole seconds.
    pub fn entry(ruby: &Ruby, rb_self: &Self, spec: RArray) -> Result<(), Error> {
        let fields = Self::fields(spec)?;
        rb_self.run(ruby, |state| state.entry(&fields))
    }

    fn fields(spec: RArray) -> Result<Fields, Error> {
        let bytes = |i: isize| -> Result<Vec<u8>, Error> {
            let s: RString = spec.entry(i)?;
            // SAFETY: the bytes are copied before any Ruby call can move
            // or change the string.
            Ok(unsafe { s.as_slice() }.to_vec())
        };
        Ok(Fields {
            name: bytes(0)?,
            link: bytes(1)?,
            flag: spec.entry(2)?,
            size: spec.entry(3)?,
            mode: spec.entry(4)?,
            mtime: spec.entry(5)?,
            uid: spec.entry(6)?,
            gid: spec.entry(7)?,
            uname: bytes(8)?,
            gname: bytes(9)?,
        })
    }

    /// Data for the current entry.
    pub fn write(ruby: &Ruby, rb_self: &Self, data: RString) -> Result<usize, Error> {
        // SAFETY: copied before the GVL is released or Ruby is called.
        let data = unsafe { data.as_slice() }.to_vec();
        rb_self.run(ruby, |state| state.write(&data))?;
        Ok(data.len())
    }

    /// An entry (`spec` as for `entry`) with the file at `path` for its
    /// data. Returns how many bytes the file gave (see `State::add_file`).
    /// A file that cannot be opened raises with nothing written.
    pub fn add_file(ruby: &Ruby, rb_self: &Self, spec: RArray, path: String) -> Result<u64, Error> {
        let fields = Self::fields(spec)?;
        rb_self.run(ruby, |state| state.add_file(&fields, &path))
    }

    /// Ends the archive. Nothing can be written afterwards.
    pub fn close(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.state(ruby)?;
        let state = rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar writer"))?
            .take();
        let Some(state) = state else {
            return Ok(());
        };
        let outcome = maybe_without_gvl(rb_self.io.is_some(), || state.finish());
        outcome.map_err(|fail| rb_self.raise(ruby, fail))
    }

    /// Lets go of the output without ending the archive: what follows a
    /// failure, when what was written is to be thrown away.
    pub fn abandon(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.attached.store(false, Ordering::Release);
        rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "tar writer"))?
            .take();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(name: &[u8], flag: u8, size: u64) -> Fields {
        Fields {
            name: name.to_vec(),
            link: Vec::new(),
            flag,
            size,
            mode: 0o644,
            mtime: 1_700_000_000,
            uid: 0,
            gid: 0,
            uname: Vec::new(),
            gname: Vec::new(),
        }
    }

    #[test]
    fn writes_numbers_that_fit_and_says_when_they_do_not() {
        let mut field = [0xffu8; 8];
        assert!(octal(&mut field, 0o644));
        assert_eq!(&field, b"0000644\0");
        assert!(octal(&mut field, 0o7777777));
        assert!(!octal(&mut field, 0o10000000));
        assert_eq!(&field, b"0000000\0");
        let mut size = [0u8; 12];
        assert!(octal(&mut size, (8 << 30) - 1));
        assert_eq!(&size, b"77777777777\0");
        assert!(!octal(&mut size, 8 << 30));
    }

    #[test]
    fn a_record_counts_its_own_length() {
        assert_eq!(
            pax_record("path", b"a"),
            b"9 path=a
"
        );
        // Nine bytes and one digit would make ten, which takes two digits.
        assert_eq!(
            pax_record("path", b"ab"),
            b"11 path=ab
"
        );
        assert_eq!(
            pax_record("p", b"abcd"),
            b"9 p=abcd
"
        );
        for len in 0..1200 {
            let record = pax_record("path", &vec![b'x'; len]);
            let stated: usize =
                std::str::from_utf8(&record[..record.iter().position(|&b| b == b' ').unwrap()])
                    .unwrap()
                    .parse()
                    .unwrap();
            assert_eq!(stated, record.len(), "value of {len} bytes");
        }
    }

    #[test]
    fn an_ordinary_entry_is_one_ustar_block() {
        let out = headers(&fields(b"dir/file.txt", b'0', 5));
        assert_eq!(out.len(), BLOCK);
        assert_eq!(&out[..12], b"dir/file.txt");
        assert_eq!(&out[257..265], b"ustar\x0000");
        assert_eq!(&out[124..136], b"00000000005\0");
        let sum: u32 = out
            .iter()
            .enumerate()
            .map(|(i, &b)| {
                if (148..156).contains(&i) {
                    32
                } else {
                    u32::from(b)
                }
            })
            .sum();
        assert_eq!(&out[148..156], format!("{sum:06o}\0 ").as_bytes());
    }

    #[test]
    fn what_does_not_fit_goes_in_an_extended_header() {
        let long = vec![b'n'; 150];
        let out = headers(&fields(&long, b'0', 0));
        assert_eq!(out.len(), 3 * BLOCK);
        assert_eq!(out[156], b'x');
        assert!(out[BLOCK..].starts_with(b"160 path=nnn"));
        assert_eq!(out[2 * BLOCK + 156], b'0');

        let mut f = fields("h\u{e9}llo".as_bytes(), b'0', 8 << 30);
        f.mtime = -5;
        f.uid = 3_000_000_000;
        let out = headers(&f);
        let records = String::from_utf8_lossy(&out[BLOCK..2 * BLOCK]).into_owned();
        for wanted in [
            "path=h\u{e9}llo\n",
            "uid=3000000000\n",
            "size=8589934592\n",
            "mtime=-5\n",
        ] {
            assert!(records.contains(wanted), "{wanted} in {records}");
        }
    }

    #[test]
    fn a_cut_name_does_not_end_in_a_slash() {
        let mut name = vec![b'd'; 99];
        name.extend(b"/file.txt");
        let out = headers(&fields(&name, b'0', 0));
        let block = &out[2 * BLOCK..];
        assert_eq!(&block[..99], &name[..99]);
        assert_eq!(block[99], 0);
    }
}
