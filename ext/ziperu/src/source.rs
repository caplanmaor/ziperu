//! Where an archive's bytes come from.
//!
//! Chosen once at open time. Every variant is cheaply `Clone`: an entry
//! reader takes its own clone of the `ZipArchive` (the parsed central
//! directory is behind an `Arc`, so only the reader is duplicated) and
//! therefore needs an independent cursor over the same bytes.
//!
//! `File` is the fast path (pure Rust I/O, runs without the GVL); `Memory`
//! backs a String buffer; `Ruby` drives any seekable IO-like object through
//! `seek`/`read` calls, so `open_buffer` on a large Tempfile does not have
//! to be slurped into memory first.

use std::fmt;
use std::fs;
use std::io::{self, BufReader, Cursor, Read, Seek, SeekFrom};
use std::sync::Arc;

use magnus::{prelude::*, value::Opaque, Error, RString, Ruby, Value};

const BUF_SIZE: usize = 64 * 1024;

pub enum Source {
    File(BufReader<SharedFile>),
    Memory(Cursor<Arc<[u8]>>),
    Ruby(BufReader<RubyIo>),
}

impl Source {
    pub fn file(file: fs::File) -> Self {
        Source::File(BufReader::with_capacity(BUF_SIZE, SharedFile::new(file)))
    }

    pub fn memory(bytes: Vec<u8>) -> Self {
        Source::Memory(Cursor::new(Arc::from(bytes)))
    }

    pub fn ruby(io: Value) -> Result<Self, Error> {
        Ok(Source::Ruby(BufReader::with_capacity(
            BUF_SIZE,
            RubyIo::new(io)?,
        )))
    }

    /// Reads from a Ruby IO call back into the interpreter, so anything
    /// over this source must keep the GVL; the other sources can drop it.
    pub fn needs_gvl(&self) -> bool {
        matches!(self, Source::Ruby(_))
    }

    /// The Ruby IO behind a `Ruby` source, for the owner to mark.
    pub fn ruby_io(&self) -> Option<Opaque<Value>> {
        match self {
            Source::Ruby(r) => Some(r.get_ref().io),
            _ => None,
        }
    }
}

impl Clone for Source {
    fn clone(&self) -> Self {
        // Position the clone where the logical stream is, not where the
        // buffered reader has read ahead to.
        match self {
            Source::File(r) => {
                let inner = r.get_ref();
                Source::File(BufReader::with_capacity(
                    BUF_SIZE,
                    SharedFile {
                        file: Arc::clone(&inner.file),
                        pos: inner.pos - r.buffer().len() as u64,
                    },
                ))
            }
            Source::Memory(c) => Source::Memory(c.clone()),
            Source::Ruby(r) => {
                let inner = r.get_ref();
                Source::Ruby(BufReader::with_capacity(
                    BUF_SIZE,
                    RubyIo {
                        io: inner.io,
                        pos: inner.pos - r.buffer().len() as u64,
                        len: inner.len,
                    },
                ))
            }
        }
    }
}

impl Read for Source {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Source::File(f) => f.read(buf),
            Source::Memory(c) => c.read(buf),
            Source::Ruby(r) => r.read(buf),
        }
    }
}

impl Seek for Source {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match self {
            Source::File(f) => f.seek(pos),
            Source::Memory(c) => c.seek(pos),
            Source::Ruby(r) => r.seek(pos),
        }
    }
}

/// One OS file handle shared between cursors, each with its own position.
/// Reads are positional (`pread`/`ReadFile` with an offset), so clones never
/// disturb each other and no file is ever reopened by path.
#[derive(Clone)]
pub struct SharedFile {
    file: Arc<fs::File>,
    pos: u64,
}

impl SharedFile {
    fn new(file: fs::File) -> Self {
        Self {
            file: Arc::new(file),
            pos: 0,
        }
    }
}

impl Read for SharedFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = read_at(&self.file, buf, self.pos)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for SharedFile {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let end = || self.file.metadata().map(|m| m.len());
        self.pos = resolve_seek(self.pos, end, pos)?;
        Ok(self.pos)
    }
}

/// A Ruby IO-like object (anything with `seek`, `read` and `tell`), driven
/// through method calls under the GVL. One object is shared by all cursors
/// over it, each of which seeks before it reads, so the object's own
/// position is meaningless between calls (rubyzip moves it around too).
///
/// The object is kept alive by the `mark` function of whatever wraps the
/// source (an `Archive` or `EntryReader`), which gets it from
/// [`Source::ruby_io`]; nothing here registers a GC root, so dropping a
/// source never calls into Ruby and the wrappers can be freed immediately.
pub struct RubyIo {
    io: Opaque<Value>,
    pos: u64,
    len: u64,
}

const SEEK_SET: i64 = 0;
const SEEK_END: i64 = 2;

impl RubyIo {
    fn new(io: Value) -> Result<Self, Error> {
        io.funcall::<_, _, Value>("seek", (0i64, SEEK_END))?;
        let len: u64 = io.funcall("tell", ())?;
        Ok(Self {
            io: Opaque::from(io),
            pos: 0,
            len,
        })
    }

    /// The IO, usable only on a Ruby thread holding the GVL, which every
    /// read over a Ruby-backed source is.
    fn value(&self) -> io::Result<Value> {
        let ruby = Ruby::get().map_err(|e| io::Error::other(e.to_string()))?;
        Ok(ruby.get_inner(self.io))
    }
}

/// A Ruby exception (or non-local jump: `throw`, `Timeout`) raised inside
/// the IO's `read` or `seek`, carried through the Rust layers as an
/// `io::Error` so that `errors::io_error` can re-raise the original.
pub struct RubyError(pub Error);

// SAFETY: created and consumed only under the GVL (a Ruby-backed source
// never runs with it released), so the `Value` inside is never touched
// from another thread; the bounds are only there to fit in `io::Error`.
unsafe impl Send for RubyError {}
unsafe impl Sync for RubyError {}

impl fmt::Debug for RubyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&self.0, f)
    }
}

impl fmt::Display for RubyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

impl std::error::Error for RubyError {}

fn ruby_io_error(err: Error) -> io::Error {
    io::Error::other(RubyError(err))
}

impl Read for RubyIo {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos >= self.len {
            return Ok(0);
        }
        let io = self.value()?;
        io.funcall::<_, _, Value>("seek", (self.pos as i64, SEEK_SET))
            .map_err(ruby_io_error)?;
        let chunk: Option<RString> = io.funcall("read", (buf.len(),)).map_err(ruby_io_error)?;
        let Some(chunk) = chunk else {
            return Ok(0);
        };
        // SAFETY: the slice is copied out before any other Ruby call.
        let bytes = unsafe { chunk.as_slice() };
        let n = bytes.len().min(buf.len());
        buf[..n].copy_from_slice(&bytes[..n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for RubyIo {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let len = self.len;
        self.pos = resolve_seek(self.pos, || Ok(len), pos)?;
        Ok(self.pos)
    }
}

/// The absolute position `pos` names, given the current one and a way to
/// find the end.
fn resolve_seek(
    current: u64,
    end: impl FnOnce() -> io::Result<u64>,
    pos: SeekFrom,
) -> io::Result<u64> {
    let (base, offset) = match pos {
        SeekFrom::Start(p) => return Ok(p),
        SeekFrom::Current(o) => (current as i64, o),
        SeekFrom::End(o) => (end()? as i64, o),
    };
    base.checked_add(offset)
        .filter(|t| *t >= 0)
        .map(|t| t as u64)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid seek to a negative or overflowing position",
            )
        })
}

#[cfg(unix)]
fn read_at(file: &fs::File, buf: &mut [u8], pos: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    file.read_at(buf, pos)
}

#[cfg(windows)]
fn read_at(file: &fs::File, buf: &mut [u8], pos: u64) -> io::Result<usize> {
    use std::os::windows::fs::FileExt;
    file.seek_read(buf, pos)
}
