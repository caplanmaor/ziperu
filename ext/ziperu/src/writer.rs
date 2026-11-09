//! `Ziperu::Native::Writer`: writes a new archive entry by entry.
//!
//! The Ruby side (`Ziperu::OutputStream`) owns entry objects, defaults and the
//! IO-like methods; this is the thin layer over `zip::ZipWriter`. The sink
//! is a file on disk, a seekable Ruby IO driven through method calls (how
//! `write_buffer(io)` streams entry by entry into a StringIO, File or
//! Tempfile), or an in-memory buffer whose bytes `finish` returns, for an
//! IO that cannot seek.

use std::cell::RefCell;
use std::fs;
use std::io::{self, BufWriter, Cursor, Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use magnus::{
    gc::Marker, prelude::*, typed_data::DataTypeFunctions, value::Opaque, Error, RArray, RHash,
    RString, Ruby, TypedData, Value,
};
use zip::result::{ZipError, ZipResult};
use zip::write::FullFileOptions;
use zip::{AesMode, CompressionMethod, DateTime, System, ZipArchive, ZipWriter};

use crate::archive::Archive;
use crate::errors::{busy_error, io_error, zip_error, ERROR, NATIVE_DUPLICATE_ENTRY_ERROR};
use crate::gvl::maybe_without_gvl;
use crate::source::{resolve_seek, ruby_io_error};
use crate::zipcrypto;

const BUF_SIZE: usize = 64 * 1024;

pub enum Sink {
    File(BufWriter<fs::File>),
    Memory(Cursor<Vec<u8>>),
    Ruby(BufWriter<RubyOut>),
}

impl Sink {
    /// Sets bit `bit` of the little-endian u16 at `pos`.
    fn set_u16_bit(&mut self, pos: u64, bit: u16) -> io::Result<()> {
        let mut field = [0u8; 2];
        self.seek(SeekFrom::Start(pos))?;
        self.read_exact(&mut field)?;
        let value = u16::from_le_bytes(field) | bit;
        self.seek(SeekFrom::Start(pos))?;
        self.write_all(&value.to_le_bytes())
    }

    fn write_at(&mut self, pos: u64, bytes: &[u8]) -> io::Result<()> {
        self.seek(SeekFrom::Start(pos))?;
        self.write_all(bytes)
    }

    /// Applies a header patch to the local header at `local` and the
    /// central record at `central`.
    fn apply(&mut self, patch: &Patch, local: u64, central: u64) -> io::Result<()> {
        self.set_u16_bit(local + 6, patch.flags)?;
        self.set_u16_bit(central + 8, patch.flags)?;
        if let Some((method, crc, size, csize)) = patch.fields {
            let size = u32::try_from(size).unwrap_or(u32::MAX);
            let csize = u32::try_from(csize).unwrap_or(u32::MAX);
            self.write_at(local + 8, &method.to_le_bytes())?;
            self.write_at(local + 14, &crc.to_le_bytes())?;
            self.write_at(local + 18, &csize.to_le_bytes())?;
            self.write_at(local + 22, &size.to_le_bytes())?;
            self.write_at(central + 10, &method.to_le_bytes())?;
            self.write_at(central + 16, &crc.to_le_bytes())?;
            self.write_at(central + 20, &csize.to_le_bytes())?;
            self.write_at(central + 24, &size.to_le_bytes())?;
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

/// A seekable Ruby IO-like object (`write`, `seek`, `tell`, `read` and
/// optionally `flush`) written through method calls under the GVL. The
/// writer owns the object while open, so unlike `source::RubyIo` it trusts
/// the object's own position and only seeks when the two have drifted
/// apart (every entry ends with a seek back to patch its local header).
///
/// The object is kept alive by the `Writer`'s `mark`; nothing here holds a
/// GC root. `ZipWriter`'s own `Drop` finalizes an archive that was never
/// finished, which would call into Ruby from the GC's free (where no
/// object may be allocated): the `Writer` clears `attached` first, after
/// which the sink swallows everything and touches no Ruby object.
pub struct RubyOut {
    io: Opaque<Value>,
    attached: Arc<AtomicBool>,
    /// Where the next write or read goes.
    pos: u64,
    /// One past the furthest byte written: the archive's end.
    end: u64,
    flushable: bool,
}

const SEEK_SET: i64 = 0;

impl RubyOut {
    fn new(io: Value, attached: Arc<AtomicBool>) -> Result<Self, Error> {
        Ok(Self {
            flushable: io.respond_to("flush", false)?,
            io: Opaque::from(io),
            attached,
            pos: 0,
            end: 0,
        })
    }

    /// The IO, usable only on a Ruby thread holding the GVL, which every
    /// operation on a Ruby-backed sink is; `None` once detached.
    fn value(&self) -> io::Result<Option<Value>> {
        if !self.attached.load(Ordering::Acquire) {
            return Ok(None);
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
        io.funcall::<_, _, Value>("seek", (self.pos as i64, SEEK_SET))
            .map_err(ruby_io_error)?;
        Ok(Some(io))
    }

    /// Cuts the object off at the end of the archive, so that rewriting a
    /// shorter archive into an IO leaves no stale tail with a second end
    /// of central directory record in it.
    fn truncate_to_end(&mut self) -> io::Result<()> {
        let Some(io) = self.value()? else {
            return Ok(());
        };
        if io.respond_to("truncate", false).map_err(ruby_io_error)? {
            io.funcall::<_, _, Value>("truncate", (self.end as i64,))
                .map_err(ruby_io_error)?;
        }
        Ok(())
    }

    /// Leaves the object positioned at the end of the archive, where
    /// rubyzip leaves it.
    fn seek_to_end(&mut self) -> io::Result<()> {
        self.pos = self.end;
        self.sync().map(drop)
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
                let written: Value = io.funcall("write", (chunk,)).map_err(ruby_io_error)?;
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
                .map_err(ruby_io_error)?;
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

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::Writer", free_immediately, mark)]
pub struct Writer {
    // A write releases the GVL while borrowed, so a failed borrow means
    // another thread is writing through this object.
    inner: RefCell<State>,
    /// The Ruby IO behind a `Sink::Ruby`, kept alive by `mark`.
    io: Option<Opaque<Value>>,
    /// Cleared when this object is freed, before the `ZipWriter` inside
    /// drops, so that its finalizer cannot reach the IO (see `RubyOut`).
    attached: Option<Arc<AtomicBool>>,
    /// True for a Ruby IO sink, whose every operation must hold the GVL.
    needs_gvl: bool,
}

impl DataTypeFunctions for Writer {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        if let Some(attached) = &self.attached {
            attached.store(false, Ordering::Release);
        }
    }
}

struct State {
    /// `None` once finished.
    writer: Option<ZipWriter<Sink>>,
    /// Entries started so far; the next one gets this index.
    count: usize,
    /// Header fields to set once the archive is written; see `Patch`.
    patches: Vec<Patch>,
    /// The ZipCrypto entry being written, if the current one is.
    pending: Option<Pending>,
}

/// What the crate wrote for an entry is not quite right for ZipCrypto,
/// which it cannot write, and `finish` corrects it in both headers
/// afterwards: such an entry goes to the crate as a Stored entry whose
/// content is the ciphertext (and, when bit 3 is set, the data
/// descriptor), so its method, CRC, sizes and flags describe the real
/// entry only after the patch.
struct Patch {
    index: usize,
    /// General purpose flag bits to set.
    flags: u16,
    /// Compression method, CRC-32, uncompressed and compressed size.
    fields: Option<(u16, u32, u64, u64)>,
}

/// A ZipCrypto entry in progress: the data is deflated here (if at all),
/// encrypted, and handed to the crate as the content of a Stored entry.
struct Pending {
    index: usize,
    keys: zipcrypto::Keys,
    method: u16,
    deflate: Option<flate2::write::DeflateEncoder<Vec<u8>>>,
    crc: crc32fast::Hasher,
    size: u64,
    /// Encryption header and ciphertext written so far.
    csize: u64,
}

impl Pending {
    /// Takes in plaintext and returns the ciphertext to write.
    fn feed(&mut self, mut bytes: Vec<u8>) -> io::Result<Vec<u8>> {
        self.crc.update(&bytes);
        self.size += bytes.len() as u64;
        let mut out = match self.deflate.as_mut() {
            Some(encoder) => {
                encoder.write_all(&bytes)?;
                std::mem::take(encoder.get_mut())
            }
            None => std::mem::take(&mut bytes),
        };
        self.keys.encrypt(&mut out);
        self.csize += out.len() as u64;
        Ok(out)
    }

    /// Flushes the compressor; returns the last ciphertext, followed by
    /// the data descriptor, and the patch.
    fn seal(mut self) -> io::Result<(Vec<u8>, Patch)> {
        let mut out = match self.deflate.take() {
            Some(encoder) => encoder.finish()?,
            None => Vec::new(),
        };
        self.keys.encrypt(&mut out);
        self.csize += out.len() as u64;
        let crc = self.crc.finalize();
        out.extend_from_slice(&data_descriptor(crc, self.csize, self.size)?);
        let patch = Patch {
            index: self.index,
            // Encrypted, and (bit 3) the check byte is the DOS time's.
            flags: ENCRYPTED_FLAG | DATA_DESCRIPTOR_FLAG,
            fields: Some((self.method, crc, self.size, self.csize)),
        };
        Ok((out, patch))
    }
}

/// The data descriptor that follows an entry whose header has bit 3 set.
/// The check byte of a ZipCrypto entry written in one pass has to come
/// from the DOS time, which is what bit 3 declares, and readers that
/// take the flag at its word (Info-ZIP's overlap check, for one) expect
/// the descriptor after the data. ZipCrypto entries stay below 4 GiB,
/// so the sizes are 32-bit.
fn data_descriptor(crc: u32, csize: u64, size: u64) -> io::Result<[u8; 16]> {
    let (Ok(csize), Ok(size)) = (u32::try_from(csize), u32::try_from(size)) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "ZipCrypto entries of 4 GiB or more are not supported",
        ));
    };
    let mut out = [0u8; 16];
    out[..4].copy_from_slice(&DATA_DESCRIPTOR_SIGNATURE.to_le_bytes());
    out[4..8].copy_from_slice(&crc.to_le_bytes());
    out[8..12].copy_from_slice(&csize.to_le_bytes());
    out[12..].copy_from_slice(&size.to_le_bytes());
    Ok(out)
}

/// Finishes a ZipCrypto entry in progress, if any, before the writer
/// moves on to the next entry or the central directory.
fn seal_pending(state: &mut State, w: &mut ZipWriter<Sink>) -> io::Result<()> {
    if let Some(pending) = state.pending.take() {
        let (last, patch) = pending.seal()?;
        w.write_all(&last)?;
        state.patches.push(patch);
    }
    Ok(())
}

/// What `finish` reports about each written entry, in order: local header
/// offset, size, compressed size, CRC-32.
type EntryStats = Vec<[u64; 4]>;

/// General purpose flag bit 0: the entry is encrypted.
const ENCRYPTED_FLAG: u16 = 1;
/// General purpose flag bit 3: sizes may follow the data, and (what
/// matters here) a ZipCrypto check byte comes from the DOS time.
const DATA_DESCRIPTOR_FLAG: u16 = 8;
/// "PK\x07\x08", the optional signature that opens a data descriptor.
const DATA_DESCRIPTOR_SIGNATURE: u32 = 0x0807_4b50;
/// The ZipCrypto encryption header that precedes the ciphertext.
const ZIPCRYPTO_HEADER_LEN: u64 = 12;

/// Per-entry settings, read from the Hash Ruby passes to `start_entry`.
struct EntryOptions {
    method: u16,
    level: Option<i64>,
    dos_date: u16,
    dos_time: u16,
    unix_perms: Option<u32>,
    /// The "made by" host system byte (rubyzip's fstype), kept from the
    /// entry rather than defaulting to the platform the writer runs on.
    fstype: Option<u8>,
    large_file: bool,
    comment: Option<String>,
    /// Concatenated local-format extra fields: id, len, data.
    extra: Vec<u8>,
    /// The central-directory forms; fields present only here are written
    /// only there (rubyzip keeps unknown fields it was handed that way).
    central_extra: Vec<u8>,
    password: Option<Vec<u8>>,
    aes_mode: Option<u8>,
    /// For `copy_zipcrypto`: the source entry was written in one pass
    /// (bit 3), so a data descriptor follows its data.
    descriptor: bool,
    /// Encrypt with ZipCrypto (using `password`) rather than AES.
    zipcrypto: bool,
}

impl EntryOptions {
    fn from_hash(ruby: &Ruby, h: RHash) -> Result<Self, Error> {
        let get = |key: &str| h.get(ruby.to_symbol(key));
        let opt = |key: &str| -> Result<Option<magnus::Value>, Error> {
            Ok(get(key).filter(|v| !v.is_nil()))
        };
        Ok(Self {
            method: opt("method")?
                .map(u16::try_convert)
                .transpose()?
                .unwrap_or(8),
            level: opt("level")?.map(i64::try_convert).transpose()?,
            dos_date: opt("dos_date")?
                .map(u16::try_convert)
                .transpose()?
                .unwrap_or(0),
            dos_time: opt("dos_time")?
                .map(u16::try_convert)
                .transpose()?
                .unwrap_or(0),
            unix_perms: opt("unix_perms")?.map(u32::try_convert).transpose()?,
            fstype: opt("fstype")?.map(u8::try_convert).transpose()?,
            large_file: opt("large_file")?
                .map(bool::try_convert)
                .transpose()?
                .unwrap_or(false),
            comment: opt("comment")?
                .map(|v| utf8_text(ruby, "entry comment", RString::try_convert(v)?))
                .transpose()?,
            extra: opt("extra")?
                .map(RString::try_convert)
                .transpose()?
                .map(|s| unsafe { s.as_slice() }.to_vec())
                .unwrap_or_default(),
            central_extra: opt("central_extra")?
                .map(RString::try_convert)
                .transpose()?
                .map(|s| unsafe { s.as_slice() }.to_vec())
                .unwrap_or_default(),
            password: opt("password")?
                .map(RString::try_convert)
                .transpose()?
                .map(|s| unsafe { s.as_slice() }.to_vec()),
            aes_mode: opt("aes_mode")?.map(u8::try_convert).transpose()?,
            zipcrypto: opt("zipcrypto")?
                .map(bool::try_convert)
                .transpose()?
                .unwrap_or(false),
            descriptor: opt("descriptor")?
                .map(bool::try_convert)
                .transpose()?
                .unwrap_or(false),
        })
    }

    /// The modification time the headers carry: the entry's DOS time, or
    /// the crate's default when that pair is not a valid date.
    fn last_modified(&self) -> DateTime {
        DateTime::try_from_msdos(self.dos_date, self.dos_time)
            .unwrap_or_else(|_| DateTime::default_for_write())
    }

    /// The deflate level for data this writer compresses itself.
    fn flate_level(&self) -> flate2::Compression {
        match self.level {
            Some(level @ 0..=9) => flate2::Compression::new(level as u32),
            _ => flate2::Compression::default(),
        }
    }

    fn to_file_options(&self, ruby: &Ruby) -> Result<FullFileOptions<'_, 'static>, Error> {
        // A ZipCrypto entry reaches the crate as Stored ciphertext whose
        // 32-bit header fields are patched later, so no zip64 fields; the
        // real method is this writer's business (see `Pending`).
        let (method, large_file) = if self.zipcrypto {
            (CompressionMethod::Stored, false)
        } else {
            let method = match self.method {
                0 => CompressionMethod::Stored,
                8 => CompressionMethod::Deflated,
                12 => CompressionMethod::Bzip2,
                93 => CompressionMethod::Zstd,
                other => {
                    return Err(Error::new(
                        ruby.exception_arg_error(),
                        format!("unsupported compression method for writing: {other}"),
                    ))
                }
            };
            (method, self.large_file)
        };
        let mut options = FullFileOptions::default()
            .compression_method(method)
            .compression_level(self.level)
            .large_file(large_file)
            .last_modified_time(self.last_modified());
        if let Some(perms) = self.unix_perms {
            options = options.unix_permissions(perms);
        }
        if let Some(fstype) = self.fstype {
            options = options.system(System::from(fstype));
        }
        if let Some(comment) = &self.comment {
            options = options.with_file_comment(comment.as_str());
        }
        if let (Some(password), false) = (&self.password, self.zipcrypto) {
            let mode = match self.aes_mode {
                Some(1) => AesMode::Aes128,
                Some(2) => AesMode::Aes192,
                _ => AesMode::Aes256,
            };
            options = options.with_aes_encryption_bytes(mode, password);
        }
        let mut local_ids = Vec::new();
        for (id, data) in extra_fields(&self.extra) {
            local_ids.push(id);
            options
                .add_extra_field(id, data, false)
                .map_err(|e| zip_error(ruby, e))?;
        }
        for (id, data) in extra_fields(&self.central_extra) {
            if !local_ids.contains(&id) {
                options
                    .add_extra_field(id, data, true)
                    .map_err(|e| zip_error(ruby, e))?;
            }
        }
        Ok(options)
    }
}

impl Writer {
    pub fn open_path(ruby: &Ruby, path: String) -> Result<Self, Error> {
        // Readable too: `finish` reads the central directory back.
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .map_err(|e| io_error(ruby, e))?;
        Ok(Self::new(Sink::File(BufWriter::new(file)), None, None))
    }

    pub fn open_memory() -> Self {
        Self::new(Sink::Memory(Cursor::new(Vec::new())), None, None)
    }

    /// Any seekable IO-like Ruby object; the archive is written from its
    /// start, entry by entry, as the stream takes shape.
    pub fn open_io(io: Value) -> Result<Self, Error> {
        let attached = Arc::new(AtomicBool::new(true));
        let out = RubyOut::new(io, Arc::clone(&attached))?;
        Ok(Self::new(
            Sink::Ruby(BufWriter::with_capacity(BUF_SIZE, out)),
            Some(Opaque::from(io)),
            Some(attached),
        ))
    }

    fn new(sink: Sink, io: Option<Opaque<Value>>, attached: Option<Arc<AtomicBool>>) -> Self {
        Self {
            inner: RefCell::new(State {
                writer: Some(ZipWriter::new(sink)),
                count: 0,
                patches: Vec::new(),
                pending: None,
            }),
            io,
            attached,
            needs_gvl: io.is_some(),
        }
    }

    /// Finishes the previous entry and begins a new file entry.
    pub fn start_entry(
        ruby: &Ruby,
        rb_self: &Self,
        name: RString,
        opts: RHash,
    ) -> Result<(), Error> {
        let name = unsafe { name.as_slice() }.to_vec();
        let options = EntryOptions::from_hash(ruby, opts)?;
        if options.zipcrypto && !matches!(options.method, 0 | 8) {
            return Err(Error::new(
                ruby.exception_arg_error(),
                format!(
                    "ZipCrypto entries can be Stored or Deflated, not method {}",
                    options.method
                ),
            ));
        }
        let file_options = options.to_file_options(ruby)?;
        // Starting an entry flushes the previous one's compressor, which is
        // real work for a large entry; nothing Ruby-owned is touched unless
        // the sink is a Ruby IO.
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(rb_self.needs_gvl, || -> ZipResult<()> {
                seal_pending(state, w)?;
                w.start_file_with_options(file_options.name(&name))?;
                // The crate has the entry from here on, whatever happens
                // to the rest; later patches count on the index.
                let index = state.count;
                state.count += 1;
                if options.zipcrypto {
                    let password = options.password.as_deref().unwrap_or_default();
                    let mut keys = zipcrypto::Keys::new(password);
                    // The check byte is the high byte of the DOS time the
                    // header carries, which is what the crate wrote.
                    let header = keys.header((options.last_modified().timepart() >> 8) as u8)?;
                    w.write_all(&header)?;
                    let deflate = (options.method == 8).then(|| {
                        flate2::write::DeflateEncoder::new(Vec::new(), options.flate_level())
                    });
                    state.pending = Some(Pending {
                        index,
                        keys,
                        method: options.method,
                        deflate,
                        crc: crc32fast::Hasher::new(),
                        size: 0,
                        csize: ZIPCRYPTO_HEADER_LEN,
                    });
                }
                Ok(())
            })
            .map_err(|e| entry_error(ruby, &name, e))
        })
    }

    /// Finishes the previous entry and adds a directory entry.
    pub fn add_directory(
        ruby: &Ruby,
        rb_self: &Self,
        name: RString,
        opts: RHash,
    ) -> Result<(), Error> {
        let name = utf8_name(ruby, name)?;
        let options = EntryOptions::from_hash(ruby, opts)?;
        let file_options = options.to_file_options(ruby)?;
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(rb_self.needs_gvl, || {
                seal_pending(state, w)?;
                w.add_directory(&name, file_options)
            })
            .map_err(|e| entry_error(ruby, name.as_bytes(), e))?;
            state.count += 1;
            Ok(())
        })
    }

    /// Finishes the previous entry and adds a symlink entry pointing at
    /// `target` (stored as the entry's content, with `S_IFLNK` in the
    /// external attributes).
    pub fn add_symlink(
        ruby: &Ruby,
        rb_self: &Self,
        name: RString,
        target: RString,
        opts: RHash,
    ) -> Result<(), Error> {
        let name = utf8_name(ruby, name)?;
        let target = utf8_text(ruby, "symlink target", target)?;
        let options = EntryOptions::from_hash(ruby, opts)?;
        let file_options = options.to_file_options(ruby)?;
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(rb_self.needs_gvl, || {
                seal_pending(state, w)?;
                w.add_symlink(&name, &target, file_options)
            })
            .map_err(|e| entry_error(ruby, name.as_bytes(), e))?;
            state.count += 1;
            Ok(())
        })
    }

    pub fn write(ruby: &Ruby, rb_self: &Self, data: RString) -> Result<usize, Error> {
        // Copied out of the Ruby heap so compression can run without the
        // GVL (the string could be moved by compaction meanwhile).
        let bytes = unsafe { data.as_slice() }.to_vec();
        let len = bytes.len();
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(rb_self.needs_gvl, || match state.pending.as_mut() {
                Some(pending) => {
                    let cipher = pending.feed(bytes)?;
                    w.write_all(&cipher)
                }
                None => w.write_all(&bytes),
            })
            .map_err(|e| io_error(ruby, e))?;
            Ok(len)
        })
    }

    /// Copies entry `index` of `archive` without decompressing it, under
    /// `new_name` if given. `touch` is an optional Hash with `dos_date`,
    /// `dos_time` and `unix_perms` to write instead of the source's; the
    /// crate offers that or a rename, not both.
    pub fn raw_copy(
        ruby: &Ruby,
        rb_self: &Self,
        archive: &Archive,
        index: usize,
        new_name: Option<RString>,
        touch: Option<RHash>,
    ) -> Result<(), Error> {
        let needs_gvl = archive.needs_gvl() || rb_self.needs_gvl;
        let new_name = new_name.map(|n| utf8_name(ruby, n)).transpose()?;
        // A clone, so the archive's borrow is released before the GVL is.
        let mut source = archive.archive(ruby)?.clone();
        let file = source.by_index_raw(index).map_err(|e| zip_error(ruby, e))?;
        let zipcrypto = file.encrypted() && file.compression() != CompressionMethod::Aes;
        let touch = touch
            .map(|h| EntryOptions::from_hash(ruby, h))
            .transpose()?;
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(needs_gvl, || {
                seal_pending(state, w)?;
                match (new_name, touch) {
                    (Some(name), _) => w.raw_copy_file_rename(file, name),
                    (None, Some(t)) => {
                        let mtime = DateTime::try_from_msdos(t.dos_date, t.dos_time)
                            .unwrap_or_else(|_| DateTime::default_for_write());
                        w.raw_copy_file_touch(file, mtime, t.unix_perms)
                    }
                    (None, None) => w.raw_copy_file(file),
                }
            })
            .map_err(|e| zip_error(ruby, e))?;
            if zipcrypto {
                state.patches.push(Patch {
                    index: state.count,
                    flags: ENCRYPTED_FLAG,
                    fields: None,
                });
            }
            state.count += 1;
            Ok(())
        })
    }

    /// Copies ZipCrypto entry `index` of `archive` byte for byte, under
    /// the name and options Ruby passes (its extra fields, comment, time
    /// and permissions, so a rename or chmod is carried too). The crate's
    /// raw copy cannot write such an entry faithfully: it drops the
    /// encryption flag and, for one written in a single pass (bit 3), the
    /// data descriptor after the ciphertext, so the entry goes in as
    /// Stored content and the headers are patched in `finish`, exactly as
    /// for an entry this writer encrypts itself.
    pub fn copy_zipcrypto(
        ruby: &Ruby,
        rb_self: &Self,
        archive: &Archive,
        index: usize,
        name: RString,
        opts: RHash,
    ) -> Result<(), Error> {
        let needs_gvl = archive.needs_gvl() || rb_self.needs_gvl;
        let name = unsafe { name.as_slice() }.to_vec();
        let options = EntryOptions::from_hash(ruby, opts)?;
        let file_options = options.to_file_options(ruby)?;
        // A clone, so the archive's borrow is released before the GVL is.
        let mut source = archive.archive(ruby)?.clone();
        rb_self.with_state(ruby, |state, w| {
            maybe_without_gvl(needs_gvl, || -> ZipResult<()> {
                seal_pending(state, w)?;
                let mut file = source.by_index_raw(index)?;
                let (crc, size, csize) = (file.crc32(), file.size(), file.compressed_size());
                w.start_file_with_options(file_options.name(&name))?;
                let index = state.count;
                state.count += 1;
                let copied = io::copy(&mut file, w)?;
                if copied != csize {
                    return Err(ZipError::InvalidArchive(
                        format!("entry has {copied} bytes of data, not the {csize} declared")
                            .into(),
                    ));
                }
                let mut flags = ENCRYPTED_FLAG;
                if options.descriptor {
                    w.write_all(&data_descriptor(crc, csize, size)?)?;
                    flags |= DATA_DESCRIPTOR_FLAG;
                }
                state.patches.push(Patch {
                    index,
                    flags,
                    fields: Some((options.method, crc, size, csize)),
                });
                Ok(())
            })
            .map_err(|e| entry_error(ruby, &name, e))
        })
    }

    pub fn set_comment(ruby: &Ruby, rb_self: &Self, comment: RString) -> Result<(), Error> {
        let bytes = unsafe { comment.as_slice() }.to_vec().into_boxed_slice();
        rb_self.with_writer(ruby, |w| {
            w.set_raw_comment(bytes).map_err(|e| zip_error(ruby, e))
        })
    }

    /// Writes the central directory. Returns `[bytes, stats]`: the archive
    /// bytes for a memory sink (nil for a file or Ruby IO), and one
    /// `[header_offset, size, compressed_size, crc]` per entry in the order
    /// written, which is how Ruby learns what a streamed entry came to.
    pub fn finish(ruby: &Ruby, rb_self: &Self) -> Result<(Option<RString>, RArray), Error> {
        let mut state = rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "writer"))?;
        let writer = state
            .writer
            .take()
            .ok_or_else(|| Error::new(ruby.exception_io_error(), "closed stream"))?;
        let mut patches = std::mem::take(&mut state.patches);
        let pending = state.pending.take();
        drop(state);
        // Finishes the last entry and writes the central directory, then
        // reads that directory back for the stats and the header patches.
        let needs_gvl = rb_self.needs_gvl;
        let (sink, stats) = maybe_without_gvl(needs_gvl, || -> ZipResult<(Sink, EntryStats)> {
            let archive = finalize(writer, pending, &mut patches)?;
            let mut stats = collect_stats(&archive)?;
            let mut sink = archive.into_inner();
            if !patches.is_empty() {
                sink = apply_patches(sink, &patches, &mut stats)?;
            }
            sink.flush()?;
            if let Sink::Ruby(w) = &mut sink {
                w.get_mut().truncate_to_end()?;
                w.get_mut().seek_to_end()?;
            }
            Ok((sink, stats))
        })
        .map_err(|e| zip_error(ruby, e))?;
        let bytes = match sink {
            Sink::File(_) | Sink::Ruby(_) => None,
            Sink::Memory(c) => Some(ruby.str_from_slice(&c.into_inner())),
        };
        let out = ruby.ary_new_capa(stats.len());
        for entry in stats {
            out.push(entry.to_vec())?;
        }
        Ok((bytes, out))
    }

    pub fn is_closed(&self) -> bool {
        self.inner.try_borrow().is_ok_and(|s| s.writer.is_none())
    }

    fn with_writer<T>(
        &self,
        ruby: &Ruby,
        f: impl FnOnce(&mut ZipWriter<Sink>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.with_state(ruby, |_, w| f(w))
    }

    fn with_state<T>(
        &self,
        ruby: &Ruby,
        f: impl FnOnce(&mut State, &mut ZipWriter<Sink>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let mut guard = self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "writer"))?;
        let state = &mut *guard;
        let mut writer = state
            .writer
            .take()
            .ok_or_else(|| Error::new(ruby.exception_io_error(), "closed stream"))?;
        let result = f(state, &mut writer);
        state.writer = Some(writer);
        result
    }
}

/// Seals a ZipCrypto entry still in progress and writes the central
/// directory; the archive comes back readable for `collect_stats`.
fn finalize(
    mut writer: ZipWriter<Sink>,
    pending: Option<Pending>,
    patches: &mut Vec<Patch>,
) -> ZipResult<ZipArchive<Sink>> {
    if let Some(pending) = pending {
        let (last, patch) = pending.seal()?;
        writer.write_all(&last)?;
        patches.push(patch);
    }
    writer.finish_into_readable()
}

/// What was written for each entry, in order; see `EntryStats`.
fn collect_stats(archive: &ZipArchive<Sink>) -> ZipResult<EntryStats> {
    let meta = archive.metadata();
    (0..meta.len())
        .map(|i| {
            let e = meta.entry(i)?;
            Ok([
                e.header_start(),
                e.size(),
                e.compressed_size(),
                u64::from(e.crc32()),
            ])
        })
        .collect()
}

/// Corrects the headers the crate wrote for ZipCrypto entries (see
/// `Patch`), and the stats to match.
fn apply_patches(sink: Sink, patches: &[Patch], stats: &mut EntryStats) -> ZipResult<Sink> {
    // The writer's own view has no central record offsets (it never read
    // them); parse what was just written to get them.
    let reread = ZipArchive::new(sink)?;
    let targets = {
        let meta = reread.metadata();
        patches
            .iter()
            .map(|p| {
                let e = meta.entry(p.index)?;
                Ok((e.header_start(), e.central_header_start()))
            })
            .collect::<ZipResult<Vec<_>>>()?
    };
    let mut sink = reread.into_inner();
    for (patch, (local, central)) in patches.iter().zip(targets) {
        sink.apply(patch, local, central)?;
        if let (Some((_, crc, size, csize)), Some(stat)) =
            (patch.fields, stats.get_mut(patch.index))
        {
            stat[1] = size;
            stat[2] = csize;
            stat[3] = u64::from(crc);
        }
    }
    Ok(sink)
}

/// Walks concatenated extra fields (id, length, data) as `(id, data)`.
fn extra_fields(bytes: &[u8]) -> impl Iterator<Item = (u16, &[u8])> {
    let mut i = 0;
    std::iter::from_fn(move || {
        if i + 4 > bytes.len() {
            return None;
        }
        let id = u16::from_le_bytes([bytes[i], bytes[i + 1]]);
        let len = u16::from_le_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        let data = bytes.get(i + 4..i + 4 + len).unwrap_or(&[]);
        i += 4 + len;
        Some((id, data))
    })
}

/// The crate takes directory names, rename targets and entry comments as
/// `str` (file names are raw bytes), so this limit is stated plainly
/// rather than surfacing as a conversion error.
fn utf8_name(ruby: &Ruby, name: RString) -> Result<String, Error> {
    utf8_text(ruby, "entry name", name)
}

fn utf8_text(ruby: &Ruby, what: &str, text: RString) -> Result<String, Error> {
    let bytes = unsafe { text.as_slice() };
    String::from_utf8(bytes.to_vec()).map_err(|_| {
        Error::new(
            ruby.get_inner(&ERROR),
            format!(
                "{what} {:?} is not valid UTF-8, which the native writer needs for directory names, renames and comments",
                String::from_utf8_lossy(bytes)
            ),
        )
    })
}

/// `zip_error`, except that the crate's duplicate-name message (which
/// shows the name as a Debug dump) is replaced with one naming the entry.
fn entry_error(ruby: &Ruby, name: &[u8], err: ZipError) -> Error {
    match &err {
        ZipError::InvalidArchive(msg) if msg.starts_with("Duplicate filename") => Error::new(
            ruby.get_inner(&NATIVE_DUPLICATE_ENTRY_ERROR),
            format!(
                "entry {:?} was already written to this stream",
                String::from_utf8_lossy(name)
            ),
        ),
        _ => zip_error(ruby, err),
    }
}
