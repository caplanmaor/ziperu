//! `Ziperu::Native::EntryReader`: a chunked, decompressing reader over one entry.
//!
//! Returns raw bytes; everything IO-shaped (`gets`, `lineno`, encodings) is
//! layered on top in `lib/ziperu/input_stream.rb`. With `enforce_size` (the
//! default) it never inflates more than the declared size, so a lying header
//! cannot become a zip bomb, and reports a header that lies the other way as
//! `Ziperu::Native::SizeLimitError`. Without it, it reads to the true end of
//! the data, which is what rubyzip does when `Ziperu.validate_entry_sizes` is
//! off.

use std::cell::{RefCell, RefMut};
use std::io::{self, Read, Seek, SeekFrom};

use magnus::{
    gc::Marker, typed_data::DataTypeFunctions, value::Opaque, Error, RString, Ruby, TypedData,
    Value,
};
use zip::read::{read_zipfile_from_stream_with_options, ZipFile, ZipReadOptions};
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
                let archive: &'static mut ZipArchive<Source> = unsafe { &mut *archive };
                let index = info.index.ok_or(ZipError::FileNotFound)?;
                archive.by_index_with_options(index, options)?
            }
            Owner::Source(source) => {
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
    consumed: u64,
    finished: bool,
    /// Reads over a Ruby IO must keep the GVL; the rest release it.
    needs_gvl: bool,
}

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::EntryReader", free_immediately, mark)]
pub struct EntryReader {
    // A read releases the GVL while borrowed, so a failed borrow means
    // another thread is reading through this same object right now.
    inner: RefCell<Inner>,
    /// The Ruby IO behind a `Source::Ruby`, kept alive by `mark`.
    io: Option<Opaque<Value>>,
}

impl DataTypeFunctions for EntryReader {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
    }
}

// SAFETY: the raw pointer in `OwnedEntry` is only dereferenced from methods
// called while holding the GVL, so the reader is never used concurrently.
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
        let info = {
            // From the parsed central directory: no seek to the local
            // header, which the reader is about to do anyway.
            let meta = archive.metadata();
            let raw = meta.entry(index).rb(ruby)?;
            EntryInfo {
                index: Some(index),
                header_start: raw.header_start(),
                size: raw.size(),
                compressed_size: raw.compressed_size(),
                crc32: raw.crc32(),
            }
        };
        Self::open_at(ruby, archive, info, password, enforce_size, needs_gvl, io)
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
        let entry = OwnedEntry::open(archive, enforce_size, password, &info).rb(ruby)?;
        let size = enforce_size.then_some(info.size);
        // Nothing to read only when there is no data either: an entry
        // declared empty but holding data is a lie the crate's size check
        // should catch.
        let finished = size == Some(0) && info.compressed_size == 0;
        Ok(Self {
            inner: RefCell::new(Inner {
                entry: Some(entry),
                info,
                size,
                consumed: 0,
                finished,
                needs_gvl,
            }),
            io,
        })
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
        if inner.finished {
            return Ok(None);
        }
        if maxlen == Some(0) {
            // `read(0)` asks for nothing, which is not the end of the
            // entry: below, an empty fill means exactly that.
            return Ok(Some(ruby.str_new("")));
        }
        let remaining = inner.size.map(|s| s - inner.consumed).unwrap_or(u64::MAX);
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
        let Some(file) = inner.entry.as_mut().and_then(|e| e.file.as_mut()) else {
            // Closed, or a rewind failed to reopen it.
            return Ok(None);
        };
        let (buf, eof, oversize) = maybe_without_gvl(keep_gvl, || fill(file, want, probe))
            .map_err(|e| read_error(ruby, e))?;

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
        *finished = *size == Some(0) && info.compressed_size == 0;
        Ok(())
    }
}

/// Reads up to `want` bytes in `CHUNK` steps, pure Rust so it can run
/// without the GVL. Returns the bytes, whether the entry ended early, and
/// (when `probe`) whether data continues past the declared size.
fn fill(
    file: &mut ZipFile<'static, Source>,
    want: u64,
    probe: bool,
) -> io::Result<(Vec<u8>, bool, bool)> {
    let mut buf = Vec::with_capacity(want.min(CHUNK as u64) as usize);
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
    Ok((buf, eof, oversize))
}
