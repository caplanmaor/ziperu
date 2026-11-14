//! `Ziperu::Native::EntryReader`: a chunked, decompressing reader over one entry.
//!
//! Returns raw bytes; everything IO-shaped (`gets`, `lineno`, encodings) is
//! layered on top in `lib/ziperu/input_stream.rb`. With `enforce_size` (the
//! default) it never inflates more than the declared size, so a lying header
//! cannot become a zip bomb, and reports a header that lies the other way as
//! `Ziperu::Native::SizeLimitError`. Without it, it reads to the true end of
//! the data, which is what rubyzip does when `Ziperu.validate_entry_sizes` is
//! off.

use std::cell::{Cell, RefCell, RefMut};
use std::io::{self, Read, Seek, SeekFrom};

use magnus::{
    gc::Marker, typed_data::DataTypeFunctions, value::Opaque, Error, RString, Ruby, TypedData,
    Value,
};
use zip::read::{read_zipfile_from_stream_with_options, ZipFile, ZipFileEntry, ZipReadOptions};
use zip::result::{ZipError, ZipResult};
use zip::ZipArchive;

use crate::errors::{busy_error, read_error, size_limit_error, zip_error, IntoRuby};
use crate::gvl::maybe_without_gvl;
use crate::source::Source;

const CHUNK: usize = 64 * 1024;
/// Reads shorter than this run under the GVL; see `read`.
const INLINE_READ: u64 = 16 * 1024;

/// What the entry was opened from. The crate's `by_index` readers always cap
/// output at the central directory's size; lifting that means reading the
/// local header ourselves through the stream API, which borrows the raw
/// `Source` instead of the `ZipArchive`.
enum Owner {
    Archive(*mut ZipArchive<Source>),
    Source(*mut Source),
}

/// A `ZipFile` together with what it borrows from.
///
/// `ZipFile<'a>` borrows its owner mutably; to hand one to Ruby we keep the
/// owner on the heap behind a raw pointer and give the borrow a `'static`
/// lifetime that `Drop` makes honest.
struct OwnedEntry {
    file: Option<ZipFile<'static, Source>>,
    owner: Owner,
    // The reader borrows the password for its own lifetime too; boxed so its
    // address is stable, declared after `file` so it is dropped after it.
    password: Option<Box<[u8]>>,
}

/// Central-directory facts needed to (re)open an entry.
pub(crate) struct EntryInfo {
    /// The crate's index, or `None` for a record it cannot address (one of
    /// several under the same name), which is read from its local header.
    pub(crate) index: Option<usize>,
    pub(crate) header_start: u64,
    pub(crate) size: u64,
    pub(crate) compressed_size: u64,
    pub(crate) crc32: u32,
    /// The central directory's compression method, when known. The local
    /// header must agree: reading through it must not decode the data
    /// differently from reading by index.
    pub(crate) method: Option<u16>,
}

impl EntryInfo {
    /// For the entry the crate has at `index`.
    pub(crate) fn from_entry(index: usize, entry: &ZipFileEntry<'_>) -> Self {
        Self {
            index: Some(index),
            header_start: entry.header_start(),
            size: entry.size(),
            compressed_size: entry.compressed_size(),
            crc32: entry.crc32(),
            method: Some(crate::archive::compression_code(entry.compression())),
        }
    }

    /// For a record the crate cannot address by index, as its central
    /// record describes it.
    pub(crate) fn at_offset(
        header_start: u64,
        size: u64,
        compressed_size: u64,
        crc32: u32,
    ) -> Self {
        Self {
            index: None,
            header_start,
            size,
            compressed_size,
            crc32,
            method: None,
        }
    }

    /// Declared to hold nothing: no data, and the CRC of no data. An entry
    /// declared empty but holding data, or with another CRC, is a lie the
    /// crate's checks should catch.
    fn is_empty(&self) -> bool {
        self.size == 0 && self.compressed_size == 0 && self.crc32 == 0
    }
}

/// The compression method in the local header at the source's position,
/// which is left where it was.
fn local_method(source: &mut Source, header_start: u64) -> ZipResult<u16> {
    let mut head = [0u8; 10];
    source.seek(SeekFrom::Start(header_start))?;
    source.read_exact(&mut head)?;
    source.seek(SeekFrom::Start(header_start))?;
    Ok(u16::from_le_bytes([head[8], head[9]]))
}

/// Opens the entry `info` describes by seeking to its local header, with
/// the central directory's compressed size and CRC (so an entry whose
/// local header defers to a data descriptor still reads) and `size_cap`
/// as the uncompressed size the crate enforces: the declared size, or
/// `u64::MAX` to read past it to the true end of the data.
pub(crate) fn open_local_entry<'a>(
    source: &'a mut Source,
    info: &EntryInfo,
    password: Option<&'a [u8]>,
    size_cap: u64,
) -> ZipResult<ZipFile<'a, Source>> {
    if let Some(method) = info.method {
        if local_method(source, info.header_start)? != method {
            return Err(ZipError::InvalidArchive(
                "local header compression method differs from the central directory".into(),
            ));
        }
    }
    source.seek(SeekFrom::Start(info.header_start))?;
    let options = ZipReadOptions::new()
        .password(password)
        .override_compressed_size(info.compressed_size)
        .override_uncompressed_size(size_cap)
        .override_crc(info.crc32);
    read_zipfile_from_stream_with_options(source, options)?.ok_or(ZipError::InvalidArchive(
        "expected a local file header".into(),
    ))
}

impl OwnedEntry {
    fn open(
        archive: ZipArchive<Source>,
        enforce_size: bool,
        password: Option<Vec<u8>>,
        info: &EntryInfo,
    ) -> ZipResult<Self> {
        let owner = if enforce_size && info.index.is_some() {
            Owner::Archive(Box::into_raw(Box::new(archive)))
        } else {
            Owner::Source(Box::into_raw(Box::new(archive.into_inner())))
        };
        let mut this = Self {
            file: None,
            owner,
            password: password.map(Vec::into_boxed_slice),
        };
        this.reopen(info)?;
        Ok(this)
    }

    fn reopen(&mut self, info: &EntryInfo) -> ZipResult<()> {
        self.file = None;
        // SAFETY: the password box and the owner allocation live as long as
        // `self` and are only freed by `Drop`, after `file` has been dropped,
        // so these `'static` borrows never outlive their referents. Nothing
        // else holds a reference to either allocation.
        let password: Option<&'static [u8]> = self
            .password
            .as_deref()
            .map(|p| unsafe { &*(p as *const [u8]) });
        let options = ZipReadOptions::new().password(password);
        let file = match self.owner {
            Owner::Archive(archive) => {
                // SAFETY: as above.
                let archive: &'static mut ZipArchive<Source> = unsafe { &mut *archive };
                let index = info.index.ok_or(ZipError::FileNotFound)?;
                archive.by_index_with_options(index, options)?
            }
            Owner::Source(source) => {
                // SAFETY: as above.
                let source: &'static mut Source = unsafe { &mut *source };
                open_local_entry(source, info, password, u64::MAX)?
            }
        };
        self.file = Some(file);
        Ok(())
    }
}

impl Drop for OwnedEntry {
    fn drop(&mut self) {
        self.file = None;
        // SAFETY: created by `Box::into_raw` in `open`; freed exactly once here.
        unsafe {
            match self.owner {
                Owner::Archive(p) => drop(Box::from_raw(p)),
                Owner::Source(p) => drop(Box::from_raw(p)),
            }
        }
    }
}

struct Inner {
    /// `None` once closed, which frees the entry and the owner it borrows
    /// from (the file handle or the Ruby IO root) right away.
    entry: Option<OwnedEntry>,
    info: EntryInfo,
    /// Declared size, or `None` when reading to the true end of the data.
    size: Option<u64>,
    /// Bytes delivered to Ruby so far.
    consumed: u64,
    finished: bool,
    /// Bytes already decompressed but not yet handed out: what a read
    /// had gathered when it was interrupted, served first by the next.
    pending: Vec<u8>,
    /// Set when a read failed part-way for any reason but an interrupt:
    /// the decoder's state is then unknown, so later reads raise rather
    /// than return data that may have a hole in it. `rewind` clears it.
    failed: Option<String>,
    /// Reads over a Ruby IO must keep the GVL; the rest release it.
    needs_gvl: bool,
    /// For a Stored entry that is not encrypted, which `seek` can move
    /// about in: a source of its own over the archive's bytes.
    raw_source: Option<Source>,
    /// Where the entry's data begins, once a seek has looked it up.
    data_start: Option<u64>,
    /// After a seek, reads come straight from `raw_source`: the absolute
    /// position of the next byte, and of the end of the data. A read
    /// this way checks no CRC (only reading from the start can).
    raw: Option<(u64, u64)>,
    /// Whether a read of the rest of the entry may go straight into a
    /// String of the declared size (`rb::size_believable`).
    direct: bool,
}

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::EntryReader", free_immediately, mark)]
pub struct EntryReader {
    // A read releases the GVL while borrowed, so a failed borrow means
    // another thread is reading through this same object right now.
    inner: RefCell<Inner>,
    /// The Ruby IO behind a `Source::Ruby`, kept alive by `mark`.
    io: Option<Opaque<Value>>,
    /// The String an interrupted `read_direct` was filling, kept alive by
    /// `mark`. Its bytes become `Inner::pending` only if another read
    /// comes (`settle`): copying them at the interrupt held up a
    /// `Timeout` by the time it takes to copy most of a large entry.
    /// Set and taken with the GVL held only.
    partial: Cell<Option<Opaque<RString>>>,
}

impl DataTypeFunctions for EntryReader {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
        if let Some(partial) = self.partial.get() {
            marker.mark(partial);
        }
    }
}

// SAFETY: the raw pointer in `OwnedEntry` is only dereferenced through the
// reader's `RefCell`, whose exclusive borrow is held by one thread for the
// whole of a call (with or without the GVL), so the reader is never used
// concurrently.
unsafe impl Send for EntryReader {}

impl EntryReader {
    pub(crate) fn open(
        ruby: &Ruby,
        archive: ZipArchive<Source>,
        index: usize,
        password: Option<Vec<u8>>,
        enforce_size: bool,
        needs_gvl: bool,
        io: Option<Opaque<Value>>,
    ) -> Result<Self, Error> {
        let seekable;
        let info = {
            // From the parsed central directory: no seek to the local
            // header, which the reader is about to do anyway.
            let meta = archive.metadata();
            let raw = meta.entry(index).rb(ruby)?;
            seekable = raw.compression() == zip::CompressionMethod::Stored && !raw.encrypted();
            EntryInfo::from_entry(index, &raw)
        };
        let raw_source =
            (seekable && enforce_size).then(|| archive.clone().into_inner().clone_small());
        let reader = Self::open_at(ruby, archive, info, password, enforce_size, needs_gvl, io)?;
        reader.inner.borrow_mut().raw_source = raw_source;
        Ok(reader)
    }

    /// Moves to byte `pos` of the entry's data (the end, if past it). Only
    /// a Stored entry that is not encrypted has its bytes where they can
    /// be reached directly; any other must be read from the start.
    pub fn seek(ruby: &Ruby, rb_self: &Self, pos: u64) -> Result<(), Error> {
        let mut inner = rb_self.inner(ruby)?;
        if inner.entry.is_none() {
            return Err(Error::new(ruby.exception_io_error(), "closed stream"));
        }
        let (Some(size), true) = (inner.size, inner.raw_source.is_some()) else {
            return Err(Error::new(
                ruby.get_inner(&crate::errors::ERROR),
                "only a Stored entry that is not encrypted can be seeked in; \
                 a compressed one must be read from the start (rewind)",
            ));
        };
        let data_start = match inner.data_start {
            Some(at) => at,
            None => {
                let header_start = inner.info.header_start;
                let source = inner.raw_source.as_mut().expect("checked above");
                let at = data_offset(source, header_start)
                    .map_err(|e| crate::errors::header_error(ruby, e))?;
                inner.data_start = Some(at);
                at
            }
        };
        let pos = pos.min(size);
        inner.raw = Some((data_start + pos, data_start + size));
        inner.consumed = pos;
        rb_self.partial.set(None);
        inner.pending.clear();
        inner.failed = None;
        inner.finished = pos >= size;
        Ok(())
    }

    /// `read` after a seek: straight from the archive's bytes.
    fn read_raw(
        ruby: &Ruby,
        inner: &mut Inner,
        maxlen: Option<usize>,
    ) -> Result<Option<RString>, Error> {
        let (at, end) = inner.raw.expect("called after a seek");
        let remaining = end - at;
        if remaining == 0 {
            inner.finished = true;
            return Ok(None);
        }
        let want = maxlen.map_or(remaining, |n| (n as u64).min(remaining));
        let keep_gvl = inner.needs_gvl || want < INLINE_READ;
        let source = inner.raw_source.as_mut().expect("seekable");
        let mut buf = Vec::new();
        maybe_without_gvl(keep_gvl, || -> io::Result<()> {
            source.seek_to(at)?;
            while (buf.len() as u64) < want {
                crate::gvl::check()?;
                let step = (want - buf.len() as u64).min(CHUNK as u64) as usize;
                let start = buf.len();
                buf.resize(start + step, 0);
                let n = source.read(&mut buf[start..])?;
                buf.truncate(start + n);
                if n == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "the entry's data ends before its declared size",
                    ));
                }
            }
            Ok(())
        })
        .map_err(|e| read_error(ruby, e))?;
        let n = buf.len() as u64;
        inner.raw = Some((at + n, end));
        inner.consumed += n;
        inner.finished = at + n >= end;
        Ok(Some(ruby.str_from_slice(&buf)))
    }

    /// A reader over the entry `info` describes, which need not be one the
    /// crate can address by index.
    pub(crate) fn open_at(
        ruby: &Ruby,
        archive: ZipArchive<Source>,
        info: EntryInfo,
        password: Option<Vec<u8>>,
        enforce_size: bool,
        needs_gvl: bool,
        io: Option<Opaque<Value>>,
    ) -> Result<Self, Error> {
        let direct = enforce_size
            && password.is_none()
            && info.method.is_some_and(|m| {
                crate::rb::size_believable(
                    m,
                    info.size,
                    info.compressed_size,
                    archive.central_directory_start(),
                )
            });
        let entry = OwnedEntry::open(archive, enforce_size, password, &info).rb(ruby)?;
        let size = enforce_size.then_some(info.size);
        let finished = size.is_some() && info.is_empty();
        Ok(Self {
            inner: RefCell::new(Inner {
                entry: Some(entry),
                info,
                size,
                consumed: 0,
                finished,
                pending: Vec::new(),
                failed: None,
                needs_gvl,
                raw_source: None,
                data_start: None,
                raw: None,
                direct,
            }),
            io,
            partial: Cell::new(None),
        })
    }

    /// Moves what an interrupted `read_direct` had read into `pending`,
    /// for the read now starting to serve first.
    fn settle(&self, ruby: &Ruby, inner: &mut Inner) {
        if let Some(partial) = self.partial.take() {
            let partial = ruby.get_inner(partial);
            // SAFETY: copied out at once, with the GVL held.
            inner.pending = unsafe { partial.as_slice() }.to_vec();
        }
    }

    fn inner(&self, ruby: &Ruby) -> Result<RefMut<'_, Inner>, Error> {
        self.inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "entry reader"))
    }

    /// The declared size, or nil when not enforcing it.
    pub fn size(ruby: &Ruby, rb_self: &Self) -> Result<Option<u64>, Error> {
        Ok(rb_self.inner(ruby)?.size)
    }

    pub fn pos(ruby: &Ruby, rb_self: &Self) -> Result<u64, Error> {
        Ok(rb_self.inner(ruby)?.consumed)
    }

    pub fn is_eof(ruby: &Ruby, rb_self: &Self) -> Result<bool, Error> {
        Ok(rb_self.inner(ruby)?.finished)
    }

    /// Releases the entry and what it holds open (the file handle, or the
    /// Ruby IO) now rather than at GC time; reads afterwards return nil.
    pub fn close(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut inner = rb_self.inner(ruby)?;
        inner.entry = None;
        inner.finished = true;
        rb_self.partial.set(None);
        Ok(())
    }

    /// Up to `maxlen` bytes (all remaining bytes when nil) as a binary
    /// String, or nil once the entry is exhausted. Short only at EOF.
    pub fn read(
        ruby: &Ruby,
        rb_self: &Self,
        maxlen: Option<usize>,
    ) -> Result<Option<RString>, Error> {
        let mut inner = rb_self.inner(ruby)?;
        if let Some(reason) = &inner.failed {
            return Err(failed_error(ruby, reason));
        }
        rb_self.settle(ruby, &mut inner);
        if inner.finished && inner.pending.is_empty() {
            return Ok(None);
        }
        if maxlen == Some(0) {
            // `read(0)` asks for nothing, which is not the end of the
            // entry: below, an empty fill means exactly that.
            return Ok(Some(ruby.str_new("")));
        }
        if inner.raw.is_some() {
            return Self::read_raw(ruby, &mut inner, maxlen);
        }
        let remaining = inner.size.map_or(u64::MAX, |s| s - inner.consumed);
        let want = match maxlen {
            Some(n) => (n as u64).min(remaining),
            None => remaining,
        };

        // This read reaches the declared size: one more byte would mean the
        // header lied, so probe for it.
        let probe = inner.size == Some(inner.consumed + want);
        // Releasing the GVL costs about as much as inflating a few KiB, so
        // tiny reads (`getc`, `each_byte`) keep it.
        let keep_gvl = inner.needs_gvl || want < INLINE_READ;
        let mut buf = std::mem::take(&mut inner.pending);
        if !buf.is_empty() && buf.len() as u64 >= want {
            // Served from what an interrupted read left behind. Should
            // this reach the declared size, the next read probes past it.
            inner.pending = buf.split_off(want as usize);
            inner.consumed += want;
            return Ok(Some(ruby.str_from_slice(&buf)));
        }
        if buf.is_empty() && probe && inner.direct && want >= crate::rb::DIRECT_READ_MIN {
            return Self::read_direct(ruby, rb_self, &mut inner, want as usize);
        }
        let Inner {
            entry, finished, ..
        } = &mut *inner;
        let file = match entry.as_mut().and_then(|e| e.file.as_mut()) {
            Some(file) if !*finished => file,
            // Closed, a rewind failed to reopen it, or the data has ended
            // and only pending bytes were left.
            _ => {
                if buf.is_empty() {
                    return Ok(None);
                }
                inner.consumed += buf.len() as u64;
                return Ok(Some(ruby.str_from_slice(&buf)));
            }
        };
        let outcome = maybe_without_gvl(keep_gvl, || fill(file, &mut buf, want, probe));
        let (eof, oversize) = match outcome {
            Ok(flags) => flags,
            Err(e) => {
                if crate::gvl::is_cancelled(&e) {
                    // Interrupted between chunks: the decoder is intact,
                    // and what it produced so far waits for the next read.
                    inner.pending = buf;
                } else {
                    inner.failed = Some(e.to_string());
                }
                return Err(read_error(ruby, e));
            }
        };

        let filled = buf.len() as u64;
        inner.consumed += filled;
        if eof {
            inner.finished = true;
        }
        if oversize {
            return Err(size_limit_error(ruby));
        }
        if filled == 0 {
            // Nothing left: the declared size was reached (and the probe
            // found no more), or the stream ended short of it, in which
            // case the crate's CRC check normally raises first. Either way
            // the entry is finished; a reader looping on `sysread` until
            // nil depends on `eof?` saying so.
            inner.finished = true;
            return Ok(None);
        }
        if probe && filled == want {
            inner.finished = true;
        }
        Ok(Some(ruby.str_from_slice(&buf)))
    }

    /// The rest of the entry, `want` bytes to its declared size, read
    /// straight into the String handed back (see `rb::fill_new_string`),
    /// with the same outcomes as the chunked way: an interrupt leaves what
    /// was read for the next read (`partial`), any other error poisons
    /// the reader, and data past the declared size is a size-limit error.
    fn read_direct(
        ruby: &Ruby,
        rb_self: &Self,
        inner: &mut Inner,
        want: usize,
    ) -> Result<Option<RString>, Error> {
        let needs_gvl = inner.needs_gvl;
        if inner.finished {
            return Ok(None);
        }
        let Some(file) = inner.entry.as_mut().and_then(|e| e.file.as_mut()) else {
            return Ok(None);
        };
        let (out, result) = crate::rb::fill_new_string(
            ruby,
            needs_gvl,
            want,
            &mut crate::gvl::Cancellable(file),
            |r| {
                let mut extra = [0u8; 1];
                r.read(&mut extra).map(|n| n != 0)
            },
        );
        match result {
            Ok((filled, oversize)) => {
                inner.consumed += filled as u64;
                if filled < want || oversize.is_some() {
                    inner.finished = true;
                }
                if oversize == Some(true) {
                    return Err(size_limit_error(ruby));
                }
                Ok((filled > 0).then_some(out))
            }
            Err(e) => {
                if crate::gvl::is_cancelled(&e) {
                    rb_self.partial.set(Some(out.into()));
                } else {
                    inner.failed = Some(e.to_string());
                }
                Err(read_error(ruby, e))
            }
        }
    }

    pub fn rewind(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut inner = rb_self.inner(ruby)?;
        let Inner {
            entry,
            info,
            size,
            consumed,
            finished,
            ..
        } = &mut *inner;
        let Some(entry) = entry.as_mut() else {
            return Err(Error::new(ruby.exception_io_error(), "closed stream"));
        };
        if let Err(e) = entry.reopen(info) {
            // The entry is gone; leave the reader at EOF rather than
            // half-open.
            *finished = true;
            return Err(zip_error(ruby, e));
        }
        *consumed = 0;
        *finished = size.is_some() && info.is_empty();
        rb_self.partial.set(None);
        inner.pending.clear();
        inner.failed = None;
        inner.raw = None;
        Ok(())
    }
}

/// Where the data of the entry whose local header is at `header_start`
/// begins: after the header's fixed part, the name and the extra field.
fn data_offset(source: &mut Source, header_start: u64) -> io::Result<u64> {
    let (name_len, extra_len) = local_header_lens(source, header_start)?;
    Ok(header_start + LOCAL_HEADER_LEN + name_len + extra_len)
}

/// The fixed part of a local file header, before the name.
pub(crate) const LOCAL_HEADER_LEN: u64 = 30;
const LOCAL_HEADER_SIGNATURE: u32 = 0x0403_4b50;

/// The lengths of the name and of the extra field that the local header
/// at `header_start` declares. The source is left just after the header's
/// fixed part.
pub(crate) fn local_header_lens(source: &mut Source, header_start: u64) -> io::Result<(u64, u64)> {
    let mut header = [0u8; LOCAL_HEADER_LEN as usize];
    source.seek_to(header_start)?;
    source.read_exact(&mut header)?;
    if u32::from_le_bytes([header[0], header[1], header[2], header[3]]) != LOCAL_HEADER_SIGNATURE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "local file header signature not found",
        ));
    }
    let name_len = u64::from(u16::from_le_bytes([header[26], header[27]]));
    let extra_len = u64::from(u16::from_le_bytes([header[28], header[29]]));
    Ok((name_len, extra_len))
}

/// The error every read raises after one failed part-way.
fn failed_error(ruby: &Ruby, reason: &str) -> Error {
    Error::new(
        ruby.get_inner(&crate::errors::ERROR),
        format!(
            "entry cannot be read further after an earlier error ({reason}); rewind to start again"
        ),
    )
}

/// Reads into `buf` until it holds `want` bytes, in `CHUNK` steps, pure
/// Rust so it can run without the GVL. Returns whether the entry ended
/// early and (when `probe`) whether data continues past the declared
/// size. On an error, `buf` keeps what was read before it.
fn fill(
    file: &mut ZipFile<'static, Source>,
    buf: &mut Vec<u8>,
    want: u64,
    probe: bool,
) -> io::Result<(bool, bool)> {
    buf.reserve(want.saturating_sub(buf.len() as u64).min(CHUNK as u64) as usize);
    let mut eof = false;
    while (buf.len() as u64) < want {
        crate::gvl::check()?;
        let step = (want - buf.len() as u64).min(CHUNK as u64) as usize;
        let start = buf.len();
        buf.resize(start + step, 0);
        let n = file.read(&mut buf[start..])?;
        buf.truncate(start + n);
        if n == 0 {
            eof = true;
            break;
        }
    }
    let mut oversize = false;
    if probe && buf.len() as u64 == want {
        let mut extra = [0u8; 1];
        oversize = file.read(&mut extra)? != 0;
    }
    Ok((eof, oversize))
}
