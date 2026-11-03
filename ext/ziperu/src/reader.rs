//! `Zip::Native::EntryReader`: a chunked, decompressing reader over one entry.
//!
//! Returns raw bytes; everything IO-shaped (`gets`, `lineno`, encodings) is
//! layered on top in `lib/zip/input_stream.rb`. Never inflates more than the
//! declared size, so a lying header cannot become a zip bomb, and reports a
//! header that lies the other way as `Zip::Native::SizeLimitError`.

use std::cell::RefCell;
use std::io::Read;

use magnus::{Error, RString, Ruby};
use zip::read::ZipFile;
use zip::result::ZipResult;
use zip::ZipArchive;

use crate::errors::{io_error, size_limit_error, zip_error};
use crate::source::Source;

const CHUNK: usize = 64 * 1024;

/// A `ZipFile` together with the archive it borrows from.
///
/// `ZipFile<'a>` borrows `&'a mut ZipArchive`; to hand one to Ruby we keep
/// the archive on the heap behind a raw pointer and give the borrow a
/// `'static` lifetime that `Drop` makes honest.
struct OwnedEntry {
    file: Option<ZipFile<'static, Source>>,
    archive: *mut ZipArchive<Source>,
}

impl OwnedEntry {
    fn open(archive: ZipArchive<Source>, index: usize, password: Option<&[u8]>) -> ZipResult<Self> {
        let mut this = Self {
            file: None,
            archive: Box::into_raw(Box::new(archive)),
        };
        this.reopen(index, password)?;
        Ok(this)
    }

    fn reopen(&mut self, index: usize, password: Option<&[u8]>) -> ZipResult<()> {
        self.file = None;
        // SAFETY: `archive` is a live heap allocation that only `Drop` frees,
        // after `file` has been dropped, so the borrow never outlives it.
        // Nothing else holds a reference to the allocation.
        let archive: &'static mut ZipArchive<Source> = unsafe { &mut *self.archive };
        self.file = Some(match password {
            Some(pw) => archive.by_index_decrypt(index, pw)?,
            None => archive.by_index(index)?,
        });
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
        unsafe { drop(Box::from_raw(self.archive)) };
    }
}

struct Inner {
    entry: OwnedEntry,
    index: usize,
    password: Option<Vec<u8>>,
    size: u64,
    consumed: u64,
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
        archive: ZipArchive<Source>,
        index: usize,
        password: Option<Vec<u8>>,
    ) -> Result<Self, Error> {
        let mut entry = OwnedEntry::open(archive, index, password.as_deref())
            .map_err(|e| zip_error(ruby, e))?;
        let size = entry.file().size();
        Ok(Self {
            inner: RefCell::new(Inner {
                entry,
                index,
                password,
                size,
                consumed: 0,
            }),
        })
    }

    pub fn size(&self) -> u64 {
        self.inner.borrow().size
    }

    pub fn pos(&self) -> u64 {
        self.inner.borrow().consumed
    }

    pub fn is_eof(&self) -> bool {
        let inner = self.inner.borrow();
        inner.consumed >= inner.size
    }

    /// Up to `maxlen` bytes (all remaining bytes when nil) as a binary
    /// String, or nil once the entry is exhausted. Short only at EOF.
    pub fn read(
        ruby: &Ruby,
        rb_self: &Self,
        maxlen: Option<usize>,
    ) -> Result<Option<RString>, Error> {
        let mut inner = rb_self.inner.borrow_mut();
        let remaining = inner.size - inner.consumed;
        if remaining == 0 {
            return Ok(None);
        }
        let want = match maxlen {
            Some(n) => (n as u64).min(remaining),
            None => remaining,
        };

        let mut buf = Vec::with_capacity(want.min(CHUNK as u64) as usize);
        let mut filled = 0u64;
        while filled < want {
            let step = (want - filled).min(CHUNK as u64) as usize;
            let start = buf.len();
            buf.resize(start + step, 0);
            let n = inner
                .entry
                .file()
                .read(&mut buf[start..])
                .map_err(|e| io_error(ruby, e))?;
            buf.truncate(start + n);
            if n == 0 {
                break;
            }
            filled += n as u64;
        }

        inner.consumed += filled;
        if filled == 0 {
            // Shorter than declared; the crate's CRC check normally raises
            // before we get here. Treat as end of stream.
            inner.consumed = inner.size;
            return Ok(None);
        }
        if inner.consumed == inner.size {
            // One more byte would mean the header lied about the size.
            let mut probe = [0u8; 1];
            match inner.entry.file().read(&mut probe) {
                Ok(0) => {}
                Ok(_) => return Err(size_limit_error(ruby)),
                Err(e) => return Err(io_error(ruby, e)),
            }
        }
        Ok(Some(ruby.str_from_slice(&buf)))
    }

    pub fn rewind(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut inner = rb_self.inner.borrow_mut();
        let Inner {
            entry,
            index,
            password,
            ..
        } = &mut *inner;
        entry
            .reopen(*index, password.as_deref())
            .map_err(|e| zip_error(ruby, e))?;
        inner.consumed = 0;
        Ok(())
    }
}
