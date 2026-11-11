//! Where a `Writer` puts its bytes: a file, an in-memory buffer, or a Ruby
//! IO-like object driven through method calls.

use std::fs;
use std::io::{self, BufWriter, Cursor, Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use magnus::{prelude::*, value::Opaque, Error, RString, Ruby, Value};

use crate::source::{resolve_seek, ruby_io_error};

pub(crate) const BUF_SIZE: usize = 64 * 1024;

pub enum Sink {
    File(BufWriter<fs::File>),
    Memory(Cursor<Vec<u8>>),
    Ruby(BufWriter<RubyOut>),
}

impl Sink {
    /// Sets bit `bit` of the little-endian u16 at `pos`.
    pub(crate) fn set_u16_bit(&mut self, pos: u64, bit: u16) -> io::Result<()> {
        let mut field = [0u8; 2];
        self.seek(SeekFrom::Start(pos))?;
        self.read_exact(&mut field)?;
        let value = u16::from_le_bytes(field) | bit;
        self.seek(SeekFrom::Start(pos))?;
        self.write_all(&value.to_le_bytes())
    }

    pub(crate) fn write_at(&mut self, pos: u64, bytes: &[u8]) -> io::Result<()> {
        self.seek(SeekFrom::Start(pos))?;
        self.write_all(bytes)
    }

    /// Makes `len` the end of what was written: an entry taken back out
    /// (`Writer::rollback_entry`) can leave bytes past the central
    /// directory that a shorter archive did not overwrite.
    pub(crate) fn end_at(&mut self, len: u64) -> io::Result<()> {
        match self {
            Sink::File(_) => self.set_len(len),
            Sink::Memory(c) => {
                c.get_mut().truncate(len as usize);
                Ok(())
            }
            Sink::Ruby(w) => {
                w.flush()?;
                w.get_mut().end = len;
                Ok(())
            }
        }
    }

    /// Cuts a file off at `len`; a no-op for the other kinds.
    pub(crate) fn set_len(&mut self, len: u64) -> io::Result<()> {
        if let Sink::File(f) = self {
            f.flush()?;
            f.get_mut().set_len(len)?;
        }
        Ok(())
    }
}

// Reading back what was written (`finish` does, to collect per-entry
// facts and patch headers) goes through the file after a flush.
impl Read for Sink {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Sink::File(f) => {
                f.flush()?;
                f.get_mut().read(buf)
            }
            Sink::Memory(c) => c.read(buf),
            Sink::Ruby(w) => {
                w.flush()?;
                w.get_mut().read(buf)
            }
        }
    }
}

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Sink::File(f) => f.write(buf),
            Sink::Memory(c) => c.write(buf),
            Sink::Ruby(w) => w.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Sink::File(f) => f.flush(),
            Sink::Memory(c) => c.flush(),
            Sink::Ruby(w) => w.flush(),
        }
    }
}

impl Seek for Sink {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match self {
            Sink::File(f) => f.seek(pos),
            Sink::Memory(c) => c.seek(pos),
            Sink::Ruby(w) => w.seek(pos),
        }
    }
}

/// A Ruby IO-like object (`write`, and for a seekable one `seek`, `tell`,
/// `read`, optionally `flush` and `truncate`) written through method calls
/// under the GVL. The writer owns the object while open, so unlike
/// `source::RubyIo` it trusts the object's own position and only seeks
/// when the two have drifted apart (every entry ends with a seek back to
/// patch its local header).
///
/// The object is kept alive by the `Writer`'s `mark`; nothing here holds a
/// GC root. `ZipWriter`'s own `Drop` finalizes an archive that was never
/// finished, which would call into Ruby from the GC's free (where no
/// object may be allocated): the `Writer` clears `attached` first, after
/// which the sink swallows everything and touches no Ruby object.
pub struct RubyOut {
    io: Opaque<Value>,
    attached: Arc<AtomicBool>,
    /// Set once a call on the IO has raised. From then on the sink takes
    /// nothing more: the crate, recovering from the error, would write
    /// again what the IO may already have half taken, and the Writer
    /// refuses every later call (see `Writer::with_state`).
    broken: Arc<AtomicBool>,
    /// Where the next write or read goes.
    pos: u64,
    /// One past the furthest byte written: the archive's end.
    pub(crate) end: u64,
    flushable: bool,
    /// False for a pipe, socket or response body: writes go out in order
    /// and nothing is ever seeked to.
    seekable: bool,
}

const SEEK_SET: i64 = 0;

impl RubyOut {
    pub(crate) fn new(
        io: Value,
        attached: Arc<AtomicBool>,
        broken: Arc<AtomicBool>,
        seekable: bool,
    ) -> Result<Self, Error> {
        Ok(Self {
            flushable: io.respond_to("flush", false)?,
            io: Opaque::from(io),
            attached,
            broken,
            pos: 0,
            end: 0,
            seekable,
        })
    }

    /// The IO, usable only on a Ruby thread holding the GVL, which every
    /// operation on a Ruby-backed sink is; `None` once detached.
    fn value(&self) -> io::Result<Option<Value>> {
        if !self.attached.load(Ordering::Acquire) {
            return Ok(None);
        }
        if self.broken.load(Ordering::Acquire) {
            return Err(io::Error::other("the IO raised earlier"));
        }
        let ruby = Ruby::get().map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Some(ruby.get_inner(self.io)))
    }

    /// Moves the object to `pos`. Always a seek, even when the object
    /// ought to be there already: a reader over the same IO (an archive
    /// being rewritten into the file it is read from) moves it between
    /// writes.
    fn sync(&mut self) -> io::Result<Option<Value>> {
        let Some(io) = self.value()? else {
            return Ok(None);
        };
        if self.seekable {
            io.funcall::<_, _, Value>("seek", (self.pos as i64, SEEK_SET))
                .map_err(|e| self.fail(e))?;
        }
        Ok(Some(io))
    }

    /// Cuts the object off at the end of the archive, so that rewriting a
    /// shorter archive into an IO leaves no stale tail with a second end
    /// of central directory record in it.
    pub(crate) fn truncate_to_end(&mut self) -> io::Result<()> {
        let Some(io) = self.value()? else {
            return Ok(());
        };
        if !self.seekable {
            return Ok(());
        }
        if io.respond_to("truncate", false).map_err(|e| self.fail(e))? {
            io.funcall::<_, _, Value>("truncate", (self.end as i64,))
                .map_err(|e| self.fail(e))?;
        }
        Ok(())
    }

    /// Leaves the object positioned at the end of the archive, where
    /// rubyzip leaves it.
    pub(crate) fn seek_to_end(&mut self) -> io::Result<()> {
        self.pos = self.end;
        self.sync().map(drop)
    }
}

impl RubyOut {
    /// The error a call on the IO raised, noting that the IO is broken.
    fn fail(&self, err: Error) -> io::Error {
        self.broken.store(true, Ordering::Release);
        ruby_io_error(err)
    }
}

impl Write for RubyOut {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let n = match self.sync()? {
            Some(io) => {
                let ruby = Ruby::get().map_err(|e| io::Error::other(e.to_string()))?;
                let chunk = ruby.str_from_slice(buf);
                let written: Value = io.funcall("write", (chunk,)).map_err(|e| self.fail(e))?;
                // `IO#write` returns the byte count; an IO-like object may
                // return anything else, in which case the whole buffer
                // counts as written.
                u64::try_convert(written)
                    .ok()
                    .map_or(buf.len(), |n| usize::try_from(n).unwrap_or(usize::MAX))
                    .min(buf.len())
            }
            None => buf.len(),
        };
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "the IO's write accepted no bytes",
            ));
        }
        self.pos += n as u64;
        self.end = self.end.max(self.pos);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        if let (true, Some(io)) = (self.flushable, self.value()?) {
            io.funcall::<_, _, Value>("flush", ())
                .map_err(|e| self.fail(e))?;
        }
        Ok(())
    }
}

impl Read for RubyOut {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(io) = self.sync()? else {
            return Ok(0);
        };
        if buf.is_empty() {
            return Ok(0);
        }
        let chunk: Option<RString> = io.funcall("read", (buf.len(),)).map_err(|e| self.fail(e))?;
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

impl Seek for RubyOut {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        // The end is the archive's, not the object's: rewriting a shorter
        // archive into an IO must not land its central directory after
        // the stale tail of the old one.
        let end = self.end;
        self.pos = resolve_seek(self.pos, || Ok(end), pos)?;
        Ok(self.pos)
    }
}
