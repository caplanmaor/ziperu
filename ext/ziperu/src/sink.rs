//! Where a `Writer` puts its bytes: a file, an in-memory buffer, or a Ruby
//! IO-like object driven through method calls.

use std::fs;
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use magnus::{prelude::*, value::Opaque, Error, RString, Ruby, Value};

use crate::rb::copy_chunk;
use crate::source::{resolve_seek, ruby_io_error};

pub(crate) const BUF_SIZE: usize = 64 * 1024;
/// How much a file sink holds back. Every entry ends with a seek back to
/// its local header: while the header is still in the buffer, that costs
/// no system call. A Ruby IO sink holds `BUF_SIZE`, so that the IO keeps
/// receiving the archive as it is written.
pub(crate) const PATCH_BUF_SIZE: usize = 512 * 1024;

pub enum Sink {
    File(TailBuf<fs::File>),
    Memory(Cursor<Vec<u8>>),
    Ruby(TailBuf<RubyOut>),
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
                w.len = len;
                Ok(())
            }
        }
    }

    /// Cuts a file off at `len`; a no-op for the other kinds.
    pub(crate) fn set_len(&mut self, len: u64) -> io::Result<()> {
        if let Sink::File(f) = self {
            f.flush()?;
            f.get_mut().set_len(len)?;
            f.len = len;
        }
        Ok(())
    }
}

// Reading back what was written (`finish` does, to collect per-entry
// facts and patch headers).
impl Read for Sink {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Sink::File(f) => f.read(buf),
            Sink::Memory(c) => c.read(buf),
            Sink::Ruby(w) => w.read(buf),
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

/// A write buffer over a seekable writer that a seek does not flush: the
/// crate's seek back to each entry's local header, and its writes there,
/// land in the buffer while the header is still in it. `std::io::BufWriter`
/// flushes on every seek, which for an archive of small entries is several
/// system calls (or Ruby calls) per entry.
///
/// Bytes not yet handed on are `buf`, which belongs at `base`. A write
/// anywhere else hands the buffer on first and starts a new one there; a
/// read hands it on and reads from the inner writer.
/// Positional writes are idempotent, so after a failed hand-off the
/// buffer is kept and a later flush writes it again from `base`. Dropping
/// it flushes, as `BufWriter` does.
pub struct TailBuf<W: Write + Read + Seek> {
    inner: W,
    buf: Vec<u8>,
    base: u64,
    pos: u64,
    /// The end of what has been written, buffered or not.
    pub(crate) len: u64,
    /// Where `inner` is, when known, to spare a seek.
    inner_pos: Option<u64>,
    cap: usize,
    /// Bytes read ahead from `inner` at `ahead_start`, for the crate's
    /// many small reads of a central directory (an append reads the old
    /// one, finishing reads the new one back). Dropped on any write.
    ahead: Vec<u8>,
    ahead_start: u64,
}

/// How much a read from the inner writer takes at a time.
const READ_AHEAD: usize = 64 * 1024;

impl<W: Write + Read + Seek> TailBuf<W> {
    /// Takes `inner` at its current position; its end is the end so far.
    pub(crate) fn new(mut inner: W, cap: usize) -> io::Result<Self> {
        let pos = inner.stream_position()?;
        let len = inner.seek(SeekFrom::End(0))?;
        inner.seek(SeekFrom::Start(pos))?;
        Ok(Self {
            inner,
            buf: Vec::new(),
            base: pos,
            pos,
            len,
            inner_pos: Some(pos),
            cap,
            ahead: Vec::new(),
            ahead_start: 0,
        })
    }

    /// Takes `inner` as being at `pos` with `len` bytes written, without
    /// asking it.
    pub(crate) fn at(inner: W, pos: u64, len: u64, cap: usize) -> Self {
        Self {
            inner,
            buf: Vec::new(),
            base: pos,
            pos,
            len,
            inner_pos: None,
            cap,
            ahead: Vec::new(),
            ahead_start: 0,
        }
    }

    /// The inner writer. Anything still buffered is not in it yet: flush
    /// first to see everything. Its position may be moved.
    pub(crate) fn get_mut(&mut self) -> &mut W {
        self.inner_pos = None;
        self.ahead.clear();
        &mut self.inner
    }

    fn seek_inner(&mut self, at: u64) -> io::Result<()> {
        if self.inner_pos != Some(at) {
            self.inner_pos = None;
            self.inner.seek(SeekFrom::Start(at))?;
            self.inner_pos = Some(at);
        }
        Ok(())
    }

    fn write_through(&mut self, at: u64, bytes: &[u8]) -> io::Result<()> {
        self.seek_inner(at)?;
        if let Err(e) = self.inner.write_all(bytes) {
            self.inner_pos = None;
            return Err(e);
        }
        self.inner_pos = Some(at + bytes.len() as u64);
        Ok(())
    }

    fn flush_buf(&mut self) -> io::Result<()> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let buf = std::mem::take(&mut self.buf);
        let result = self.write_through(self.base, &buf);
        self.buf = buf;
        result?;
        self.base += self.buf.len() as u64;
        self.buf.clear();
        Ok(())
    }

    fn buf_end(&self) -> u64 {
        self.base + self.buf.len() as u64
    }
}

impl<W: Write + Read + Seek> Write for TailBuf<W> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        if data.is_empty() {
            return Ok(0);
        }
        self.ahead.clear();
        let at = self.pos;
        if at < self.base || at > self.buf_end() {
            self.flush_buf()?;
            self.base = at;
        }
        if self.buf.is_empty() && data.len() >= self.cap {
            // A large write goes straight on rather than through the buffer.
            self.write_through(at, data)?;
            self.base = at + data.len() as u64;
        } else {
            let off = (at - self.base) as usize;
            let overlap = (self.buf.len() - off).min(data.len());
            self.buf[off..off + overlap].copy_from_slice(&data[..overlap]);
            self.buf.extend_from_slice(&data[overlap..]);
        }
        self.pos = at + data.len() as u64;
        self.len = self.len.max(self.pos);
        if self.buf.len() >= self.cap {
            self.flush_buf()?;
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flush_buf()?;
        self.inner.flush()
    }
}

impl<W: Write + Read + Seek> Read for TailBuf<W> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        let at = self.pos;
        let ahead_end = self.ahead_start + self.ahead.len() as u64;
        if at < self.ahead_start || at >= ahead_end {
            // Always from the inner writer, even what is still buffered:
            // only finishing reads back, and an IO that cannot be read
            // from (a File opened "wb") then fails whatever the archive's
            // size.
            self.flush_buf()?;
            self.seek_inner(at)?;
            let mut ahead = std::mem::take(&mut self.ahead);
            ahead.resize(READ_AHEAD.max(out.len()), 0);
            let n = match self.inner.read(&mut ahead) {
                Ok(n) => n,
                Err(e) => {
                    self.inner_pos = None;
                    return Err(e);
                }
            };
            ahead.truncate(n);
            self.inner_pos = Some(at + n as u64);
            self.ahead = ahead;
            self.ahead_start = at;
            if n == 0 {
                return Ok(0);
            }
        }
        let off = (at - self.ahead_start) as usize;
        let n = (self.ahead.len() - off).min(out.len());
        out[..n].copy_from_slice(&self.ahead[off..off + n]);
        self.pos = at + n as u64;
        Ok(n)
    }
}

impl<W: Write + Read + Seek> Seek for TailBuf<W> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let len = self.len;
        self.pos = resolve_seek(self.pos, || Ok(len), pos)?;
        Ok(self.pos)
    }

    fn stream_position(&mut self) -> io::Result<u64> {
        Ok(self.pos)
    }
}

impl<W: Write + Read + Seek> Drop for TailBuf<W> {
    fn drop(&mut self) {
        let _ = self.flush_buf();
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
        let n = copy_chunk(chunk, buf);
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

#[cfg(test)]
mod tail_buf_tests {
    use super::*;

    fn check(cap: usize, ops: &[(u64, &[u8])]) {
        let mut want = Vec::new();
        let mut tb = TailBuf::new(Cursor::new(Vec::new()), cap).unwrap();
        for (at, data) in ops {
            let at = *at as usize;
            if want.len() < at + data.len() {
                want.resize(at + data.len(), 0);
            }
            want[at..at + data.len()].copy_from_slice(data);
            tb.seek(SeekFrom::Start(at as u64)).unwrap();
            tb.write_all(data).unwrap();
            // Reading back anywhere sees what was written.
            let mut back = vec![0; data.len()];
            tb.seek(SeekFrom::Start(at as u64)).unwrap();
            tb.read_exact(&mut back).unwrap();
            assert_eq!(&back, data);
            assert_eq!(tb.seek(SeekFrom::End(0)).unwrap(), want.len() as u64);
        }
        tb.flush().unwrap();
        assert_eq!(tb.get_mut().get_ref(), &want);
    }

    #[test]
    fn patches_land_where_they_belong() {
        for cap in [1, 3, 8, 64, 1 << 20] {
            check(
                cap,
                &[
                    (0, b"header"),
                    (6, b"0123456789"),
                    (2, b"XY"),
                    (16, b"tail"),
                ],
            );
            check(
                cap,
                &[
                    (0, b"aaaaaaaaaaaaaaaaaaaa"),
                    (3, b"bbbbbbbbbbbbbbbbbbbbbbbbbb"),
                    (1, b"c"),
                    (40, b"gap"),
                ],
            );
            check(
                cap,
                &[
                    (5, b"late"),
                    (0, b"early"),
                    (7, b"middle-overwrite-and-extend"),
                ],
            );
        }
    }

    #[test]
    fn starts_where_the_inner_writer_is() {
        let mut c = Cursor::new(b"existing".to_vec());
        c.seek(SeekFrom::Start(3)).unwrap();
        let mut tb = TailBuf::new(c, 4).unwrap();
        assert_eq!(tb.seek(SeekFrom::End(0)).unwrap(), 8);
        tb.seek(SeekFrom::Start(3)).unwrap();
        tb.write_all(b"--").unwrap();
        tb.flush().unwrap();
        assert_eq!(tb.get_mut().get_ref(), b"exi--ing");
    }
}
