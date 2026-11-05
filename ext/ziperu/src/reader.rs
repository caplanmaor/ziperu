//! `Zip::Native::EntryReader`: a chunked, decompressing reader over one entry.
//!
//! Returns raw bytes; everything IO-shaped (`gets`, `lineno`, encodings) is
//! layered on top in `lib/zip/input_stream.rb`. With `enforce_size` (the
//! default) it never inflates more than the declared size, so a lying header
//! cannot become a zip bomb, and reports a header that lies the other way as
//! `Zip::Native::SizeLimitError`. Without it, it reads to the true end of
//! the data, which is what rubyzip does when `Zip.validate_entry_sizes` is
//! off.

use std::cell::RefCell;
use std::io::{self, Read, Seek, SeekFrom};

use magnus::{Error, RString, Ruby};
use zip::read::{read_zipfile_from_stream_with_options, ZipFile, ZipReadOptions};
use zip::result::{ZipError, ZipResult};
use zip::ZipArchive;

use crate::errors::{io_error, size_limit_error, zip_error};
use crate::gvl::maybe_without_gvl;
use crate::source::Source;

const CHUNK: usize = 64 * 1024;

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
struct EntryInfo {
    index: usize,
    header_start: u64,
    compressed_size: u64,
    crc32: u32,
}

impl OwnedEntry {
    fn open(
        archive: ZipArchive<Source>,
        enforce_size: bool,
        password: Option<Vec<u8>>,
        info: &EntryInfo,
    ) -> ZipResult<Self> {
        let owner = if enforce_size {
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
                archive.by_index_with_options(info.index, options)?
            }
            Owner::Source(source) => {
                let source: &'static mut Source = unsafe { &mut *source };
                source.seek(SeekFrom::Start(info.header_start))?;
                // Sizes and CRC from the central directory, so entries whose
                // local header defers to a data descriptor still read; the
                // uncompressed size is set absurdly high to lift the limit.
                let options = options
                    .override_compressed_size(info.compressed_size)
                    .override_uncompressed_size(u64::MAX)
                    .override_crc(info.crc32);
                read_zipfile_from_stream_with_options(source, options)?.ok_or(
                    ZipError::InvalidArchive("expected a local file header".into()),
                )?
            }
        };
        self.file = Some(file);
        Ok(())
    }

    fn file(&mut self) -> &mut ZipFile<'static, Source> {
        self.file.as_mut().expect("entry is open")
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
    entry: OwnedEntry,
    info: EntryInfo,
    /// Declared size, or `None` when reading to the true end of the data.
    size: Option<u64>,
    consumed: u64,
    finished: bool,
    /// Reads over a Ruby IO must keep the GVL; the rest release it.
    needs_gvl: bool,
}

#[magnus::wrap(class = "Zip::Native::EntryReader", free_immediately)]
pub struct EntryReader {
    // Single-threaded under the GVL.
    inner: RefCell<Inner>,
}

// SAFETY: the raw pointer in `OwnedEntry` is only dereferenced from methods
// called while holding the GVL, so the reader is never used concurrently.
unsafe impl Send for EntryReader {}

impl EntryReader {
    pub(crate) fn open(
        ruby: &Ruby,
        mut archive: ZipArchive<Source>,
        index: usize,
        password: Option<Vec<u8>>,
        enforce_size: bool,
        needs_gvl: bool,
    ) -> Result<Self, Error> {
        let (declared, info) = {
            let raw = archive
                .by_index_raw(index)
                .map_err(|e| zip_error(ruby, e))?;
            (
                raw.size(),
                EntryInfo {
                    index,
                    header_start: raw.header_start(),
                    compressed_size: raw.compressed_size(),
                    crc32: raw.crc32(),
                },
            )
        };
        let entry = OwnedEntry::open(archive, enforce_size, password, &info)
            .map_err(|e| zip_error(ruby, e))?;
        let size = enforce_size.then_some(declared);
        Ok(Self {
            inner: RefCell::new(Inner {
                entry,
                info,
                size,
                consumed: 0,
                finished: size == Some(0),
                needs_gvl,
            }),
        })
    }

    /// The declared size, or nil when not enforcing it.
    pub fn size(&self) -> Option<u64> {
        self.inner.borrow().size
    }

    pub fn pos(&self) -> u64 {
        self.inner.borrow().consumed
    }

    pub fn is_eof(&self) -> bool {
        self.inner.borrow().finished
    }

    /// Releases the entry and its file handle now rather than at GC time;
    /// reads afterwards return nil.
    pub fn close(&self) {
        let mut inner = self.inner.borrow_mut();
        inner.entry.file = None;
        inner.finished = true;
    }

    /// Up to `maxlen` bytes (all remaining bytes when nil) as a binary
    /// String, or nil once the entry is exhausted. Short only at EOF.
    pub fn read(
        ruby: &Ruby,
        rb_self: &Self,
        maxlen: Option<usize>,
    ) -> Result<Option<RString>, Error> {
        let mut inner = rb_self.inner.borrow_mut();
        if inner.finished {
            return Ok(None);
        }
        let remaining = inner.size.map(|s| s - inner.consumed).unwrap_or(u64::MAX);
        let want = match maxlen {
            Some(n) => (n as u64).min(remaining),
            None => remaining,
        };

        // This read reaches the declared size: one more byte would mean the
        // header lied, so probe for it.
        let probe = inner.size == Some(inner.consumed + want);
        let needs_gvl = inner.needs_gvl;
        let (buf, eof, oversize) =
            maybe_without_gvl(needs_gvl, || fill(inner.entry.file(), want, probe))
                .map_err(|e| io_error(ruby, e))?;

        let filled = buf.len() as u64;
        inner.consumed += filled;
        if eof {
            inner.finished = true;
        }
        if filled == 0 {
            // Shorter than declared; the crate's CRC check normally raises
            // before we get here. Treat as end of stream.
            return Ok(None);
        }
        if oversize {
            return Err(size_limit_error(ruby));
        }
        if probe && filled == want {
            inner.finished = true;
        }
        Ok(Some(ruby.str_from_slice(&buf)))
    }

    pub fn rewind(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut inner = rb_self.inner.borrow_mut();
        let Inner { entry, info, .. } = &mut *inner;
        entry.reopen(info).map_err(|e| zip_error(ruby, e))?;
        inner.consumed = 0;
        inner.finished = inner.size == Some(0);
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
