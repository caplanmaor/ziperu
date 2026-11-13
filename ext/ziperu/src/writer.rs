//! `Ziperu::Native::Writer`: writes an archive entry by entry.
//!
//! The Ruby side (`Ziperu::OutputStream`) owns entry objects, defaults and the
//! IO-like methods; this is the thin layer over `zip::ZipWriter`. The sink
//! (`sink.rs`) is a file on disk, an in-memory buffer whose bytes `finish`
//! returns, or a Ruby IO driven through method calls: seekable (a StringIO,
//! File or Tempfile, written entry by entry) or not (a pipe, a socket, a
//! response body), in which case the crate puts each entry's sizes in a
//! data descriptor after the data and `stream_stats.rs` works out what was
//! written. ZipCrypto, which the crate cannot write, is handled in
//! `zipcrypto.rs` and patched into the headers at the end.

use std::cell::RefCell;
use std::fs;
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use magnus::{
    gc::Marker, typed_data::DataTypeFunctions, value::Opaque, Error, RArray, RHash, RString, Ruby,
    TryConvert, TypedData, Value,
};
use zip::read::ZipFile;
use zip::result::{ZipError, ZipResult};
use zip::write::StreamWriter;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::archive::Archive;
use crate::entry_options::{utf8_name, utf8_text, EntryOptions};
use crate::errors::{busy_error, zip_error, IntoRuby, NATIVE_DUPLICATE_ENTRY_ERROR};
use crate::gvl::maybe_without_gvl;
use crate::rb::bytes_of;
use crate::sink::{RubyOut, Sink, TailBuf, BUF_SIZE, PATCH_BUF_SIZE};
use crate::stream_stats::{Begun, Counting, EntryStats, StreamStats};
use crate::zipcrypto::{self, Fields, Patch, Pending};

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::Writer", free_immediately, mark)]
pub struct Writer {
    // A write releases the GVL while borrowed, so a failed borrow means
    // another thread is writing through this object.
    inner: RefCell<State>,
    /// The Ruby IO behind a `Sink::Ruby`, kept alive by `mark`. Every
    /// operation on such a sink must hold the GVL.
    io: Option<Opaque<Value>>,
    /// Cleared when this object is freed, before the `ZipWriter` inside
    /// drops, so that its finalizer cannot reach the IO (see `RubyOut`).
    attached: Option<Arc<AtomicBool>>,
    /// Set by the sink once the Ruby IO has raised: the crate and the
    /// Ruby side may no longer agree on what the archive holds (the crate
    /// takes back an entry it was finishing), so nothing more is written.
    broken: Option<Arc<AtomicBool>>,
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

/// The crate's writer over a sink it can seek in, or over one that only
/// grows, where it puts each entry's sizes in a data descriptor after the
/// data instead of seeking back, and the per-entry facts are gathered as
/// the bytes go by.
enum Zip {
    Seekable(ZipWriter<Sink>),
    Stream(ZipWriter<StreamWriter<Counting>>, Box<StreamStats>),
}

/// Runs `$body` with `$w` bound to whichever writer is inside; the body is
/// compiled once per kind, so it may use anything both offer.
macro_rules! with_zip {
    ($zip:expr, |$w:ident| $body:expr) => {
        match $zip {
            Zip::Seekable($w) => $body,
            Zip::Stream($w, _) => $body,
        }
    };
}

impl Zip {
    fn stats(&mut self) -> Option<&mut StreamStats> {
        match self {
            Zip::Seekable(_) => None,
            Zip::Stream(_, stats) => Some(stats),
        }
    }

    fn is_stream(&self) -> bool {
        matches!(self, Zip::Stream(..))
    }
}

/// The ZipCrypto bookkeeping: the entry being written, if the current one
/// is encrypted this way, and the headers to fix once the archive is
/// written.
#[derive(Default)]
struct Crypto {
    pending: Option<Pending>,
    patches: Vec<Patch>,
}

impl Crypto {
    /// Finishes a ZipCrypto entry in progress, if any, before the writer
    /// moves on to the next entry or the central directory.
    fn seal_pending<W: Write + Seek>(&mut self, w: &mut ZipWriter<W>) -> io::Result<()> {
        if let Some(pending) = self.pending.take() {
            let (last, patch) = pending.seal()?;
            w.write_all(&last)?;
            self.patches.push(patch);
        }
        Ok(())
    }
}

/// An archive opened to have entries added: what it held, and the old
/// central directory so that `abort` can put it back.
struct Append {
    /// Entries already there; `finish` reports on the ones after them.
    base: usize,
    /// Where the old central directory began.
    tail_start: u64,
    /// Its bytes, to the end of the file.
    tail: Vec<u8>,
}

struct State {
    /// `None` once finished.
    zip: Option<Zip>,
    /// Entries started so far; the next one gets this index.
    count: usize,
    crypto: Crypto,
    append: Option<Append>,
}

/// Writes below this many bytes keep the GVL (see `Writer::write`).
const INLINE_WRITE: usize = 16 * 1024;
/// How much of a large write goes in between checks for an interrupt.
const WRITE_CHUNK: usize = 1024 * 1024;
/// `write_file` reads the file through a buffer of this size.
const FILE_READ_BUF: usize = 256 * 1024;

/// Encrypted with the traditional PKWARE cipher (anything but AES).
fn is_zipcrypto<R: Read>(file: &ZipFile<'_, R>) -> bool {
    file.encrypted() && file.compression() != CompressionMethod::Aes
}

/// What a raw copy of `file` adds: its sizes and CRC are the source's.
fn known_of<R: Read>(file: &ZipFile<'_, R>) -> Begun {
    Begun::Known {
        size: file.size(),
        csize: file.compressed_size(),
        crc: file.crc32(),
    }
}
/// `add_files_parallel` hands the crate this many files per thread at a
/// time, checking for an interrupt in between.
const PARALLEL_PART_PER_THREAD: usize = 4;
/// ...or this many bytes per thread, once each thread has a file.
const PARALLEL_PART_BYTES_PER_THREAD: u64 = 8 * 1024 * 1024;

impl Writer {
    pub fn open_path(ruby: &Ruby, path: String) -> Result<Self, Error> {
        // Readable too: `finish` reads the central directory back.
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .rb(ruby)?;
        let sink = TailBuf::new(file, PATCH_BUF_SIZE).rb(ruby)?;
        Ok(Self::seekable(ZipWriter::new(Sink::File(sink))))
    }

    pub fn open_memory() -> Self {
        Self::seekable(ZipWriter::new(Sink::Memory(Cursor::new(Vec::new()))))
    }

    /// Any seekable IO-like Ruby object; the archive is written from its
    /// start, entry by entry, as the stream takes shape.
    pub fn open_io(io: Value) -> Result<Self, Error> {
        let attached = Arc::new(AtomicBool::new(true));
        let broken = Arc::new(AtomicBool::new(false));
        let out = RubyOut::new(io, Arc::clone(&attached), Arc::clone(&broken), true)?;
        let sink = Sink::Ruby(TailBuf::at(out, 0, 0, BUF_SIZE));
        Ok(Self::over_ruby_io(
            Zip::Seekable(ZipWriter::new(sink)),
            io,
            attached,
            broken,
        ))
    }

    /// A Ruby IO-like object that only takes writes (a pipe, a socket, a
    /// response body): each entry goes out as it is written, with its
    /// sizes in a data descriptor after the data, and nothing is seeked
    /// back to. ZipCrypto entries are refused, since their headers are
    /// patched at the end.
    pub fn open_stream(io: Value) -> Result<Self, Error> {
        let attached = Arc::new(AtomicBool::new(true));
        let broken = Arc::new(AtomicBool::new(false));
        let out = RubyOut::new(io, Arc::clone(&attached), Arc::clone(&broken), false)?;
        let sink = Sink::Ruby(TailBuf::at(out, 0, 0, BUF_SIZE));
        let (counting, stats) = Counting::new(sink);
        Ok(Self::over_ruby_io(
            Zip::Stream(ZipWriter::new_stream(counting), Box::new(stats)),
            io,
            attached,
            broken,
        ))
    }

    /// Opens the archive at `path` to add entries to it. The crate reads
    /// its central directory and writes the new entries over it, then a
    /// central directory for all; the entries already there are not
    /// touched. The old central directory is kept in memory so that
    /// `abort` can put it back if the append fails.
    pub fn open_append(ruby: &Ruby, path: String) -> Result<Self, Error> {
        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .rb(ruby)?;
        let (tail_start, base) = {
            let archive = ZipArchive::new(io::BufReader::new(&mut file)).rb(ruby)?;
            (archive.central_directory_start(), archive.len())
        };
        let mut tail = Vec::new();
        file.seek(SeekFrom::Start(tail_start))
            .and_then(|_| file.read_to_end(&mut tail))
            .rb(ruby)?;
        let sink = TailBuf::new(file, PATCH_BUF_SIZE).rb(ruby)?;
        let mut zip = ZipWriter::new_append(Sink::File(sink)).rb(ruby)?;
        // The crate leaves the position where its reading ended, at the
        // end of the file, and would write the new entries after the old
        // central directory, leaving it as dead bytes.
        // SAFETY: nothing is written yet; the crate takes the position as
        // where the next entry begins.
        if let Some(sink) = unsafe { zip.get_mut() } {
            sink.seek(SeekFrom::Start(tail_start)).rb(ruby)?;
        }
        let out = Self::seekable(zip);
        {
            let mut state = out.inner.borrow_mut();
            state.count = base;
            state.append = Some(Append {
                base,
                tail_start,
                tail,
            });
        }
        Ok(out)
    }

    fn seekable(zip: ZipWriter<Sink>) -> Self {
        Self {
            inner: RefCell::new(State::new(Zip::Seekable(zip))),
            io: None,
            attached: None,
            broken: None,
        }
    }

    fn over_ruby_io(
        zip: Zip,
        io: Value,
        attached: Arc<AtomicBool>,
        broken: Arc<AtomicBool>,
    ) -> Self {
        Self {
            inner: RefCell::new(State::new(zip)),
            io: Some(Opaque::from(io)),
            attached: Some(attached),
            broken: Some(broken),
        }
    }

    /// An error once the sink's IO has raised (see `broken`).
    fn check_broken(&self, ruby: &Ruby) -> Result<(), Error> {
        match &self.broken {
            Some(b) if b.load(Ordering::Acquire) => Err(Error::new(
                ruby.get_inner(&crate::errors::ERROR),
                "the archive cannot be written further: its IO raised an error earlier",
            )),
            _ => Ok(()),
        }
    }

    /// True for a Ruby IO sink, whose every operation must hold the GVL.
    fn needs_gvl(&self) -> bool {
        self.io.is_some()
    }

    /// Gives up on the archive. An append is put back as it was. A
    /// writer over a Ruby IO is detached first, so that the crate, which
    /// finishes an archive when it is dropped, cannot hand that IO a
    /// central directory: what reached the IO stays an unfinished archive
    /// that no reader takes for a complete one. Any other writer is just
    /// dropped.
    pub fn abort(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let (zip, append, count) = {
            let mut state = rb_self.borrow(ruby)?;
            (state.zip.take(), state.append.take(), state.count)
        };
        if append.is_none() {
            if let Some(attached) = &rb_self.attached {
                attached.store(false, Ordering::Release);
            }
            drop(zip);
            return Ok(());
        }
        let (Some(Zip::Seekable(mut zip)), Some(append)) = (zip, append) else {
            return Ok(());
        };
        maybe_without_gvl(rb_self.needs_gvl(), || -> ZipResult<()> {
            // The crate's `finish` is the only way to the sink; what it
            // writes is overwritten or cut off just below. `abort_file`
            // takes out the last entry whichever it is, so it is only for
            // one added here: with none, it would rewind over an entry the
            // archive already had, which the tail does not cover.
            if count > append.base {
                zip.abort_file()?;
            }
            let mut sink = zip.finish()?;
            sink.seek(SeekFrom::Start(append.tail_start))?;
            sink.write_all(&append.tail)?;
            sink.flush()?;
            sink.set_len(append.tail_start + append.tail.len() as u64)?;
            Ok(())
        })
        .rb(ruby)
    }

    /// Finishes the previous entry and begins a new file entry.
    pub fn start_entry(
        ruby: &Ruby,
        rb_self: &Self,
        name: RString,
        opts: RHash,
    ) -> Result<(), Error> {
        let name = bytes_of(name);
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
        let index = rb_self.add_entry(ruby, rb_self.needs_gvl(), &name, |_, zip| {
            if options.zipcrypto && zip.is_stream() {
                return Err(stream_error(ruby, "ZipCrypto entries"));
            }
            maybe_without_gvl(rb_self.needs_gvl(), || {
                with_zip!(zip, |w| w.start_file_with_options(file_options.name(&name)))
            })
            .map_err(|e| entry_error(ruby, &name, e))?;
            Ok(Begun::Hashed)
        })?;
        let extra_flags = if options.efs {
            zipcrypto::LANGUAGE_ENCODING_FLAG
        } else {
            0
        };
        if !options.zipcrypto {
            if extra_flags != 0 {
                rb_self.flag_entry(ruby, index, extra_flags)?;
            }
            return Ok(());
        }
        // The crate has the entry; what follows is this writer's own
        // encryption header, and the bookkeeping to encrypt its data.
        rb_self.with_state(ruby, |state, zip| {
            let password = options.password.as_deref().unwrap_or_default();
            // The check byte is the high byte of the DOS time the header
            // carries, which is what the crate wrote.
            let check = (options.last_modified().timepart() >> 8) as u8;
            let begun = Pending::begin(
                index,
                password,
                options.method,
                options.flate_level(),
                check,
                extra_flags,
            )
            .and_then(|(header, pending)| {
                maybe_without_gvl(rb_self.needs_gvl(), || {
                    with_zip!(zip, |w| w.write_all(&header))
                })?;
                Ok(pending)
            });
            match begun {
                Ok(pending) => {
                    state.crypto.pending = Some(pending);
                    Ok(())
                }
                Err(e) => {
                    // Without `pending` the data written next would go in
                    // as it is, under a header that says nothing of
                    // encryption: take the entry back out instead.
                    Self::withdraw(rb_self.needs_gvl(), state, zip);
                    Err(entry_error(ruby, &name, ZipError::Io(e)))
                }
            }
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
        let index = rb_self.add_entry(ruby, rb_self.needs_gvl(), name.as_bytes(), |_, zip| {
            maybe_without_gvl(rb_self.needs_gvl(), || {
                with_zip!(zip, |w| w.add_directory(&name, file_options))
            })
            .map_err(|e| entry_error(ruby, name.as_bytes(), e))?;
            Ok(Begun::Known {
                size: 0,
                csize: 0,
                crc: 0,
            })
        })?;
        if options.efs {
            rb_self.flag_entry(ruby, index, zipcrypto::LANGUAGE_ENCODING_FLAG)?;
        }
        Ok(())
    }

    /// Sets general purpose flag bits on entry `index` once the archive is
    /// written (see `zipcrypto::Patch`). A stream cannot be patched, so
    /// the bits are dropped there.
    fn flag_entry(&self, ruby: &Ruby, index: usize, flags: u16) -> Result<(), Error> {
        self.with_state(ruby, |state, zip| {
            if !zip.is_stream() {
                state.crypto.patches.push(Patch {
                    index,
                    flags,
                    fields: None,
                });
            }
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
        rb_self
            .add_entry(ruby, rb_self.needs_gvl(), name.as_bytes(), |_, zip| {
                maybe_without_gvl(rb_self.needs_gvl(), || {
                    with_zip!(zip, |w| w.add_symlink(&name, &target, file_options))
                })
                .map_err(|e| entry_error(ruby, name.as_bytes(), e))?;
                let len = target.len() as u64;
                Ok(Begun::Known {
                    size: len,
                    csize: len,
                    crc: crc32fast::hash(target.as_bytes()),
                })
            })
            .map(drop)
    }

    pub fn write(ruby: &Ruby, rb_self: &Self, data: RString) -> Result<usize, Error> {
        // Copied out of the Ruby heap so compression can run without the
        // GVL (the string could be moved by compaction meanwhile).
        let bytes = bytes_of(data);
        let len = bytes.len();
        // Releasing the GVL and getting it back costs more than deflating a
        // few KiB, and under contention can mean waiting out another
        // thread's time slice: small writes (`puts`, `<<` of a line) keep it.
        let keep_gvl = rb_self.needs_gvl() || len < INLINE_WRITE;
        rb_self.with_state(ruby, |state, zip| {
            maybe_without_gvl(keep_gvl, || {
                // A large write goes in chunks, so an interrupt (see `gvl`)
                // is seen between them rather than after all of it.
                for chunk in bytes.chunks(WRITE_CHUNK) {
                    crate::gvl::check()?;
                    feed(state, zip, chunk)?;
                }
                io::Result::Ok(())
            })
            .rb(ruby)?;
            Ok(len)
        })
    }

    /// Writes the contents of the file at `path` to the entry in
    /// progress, as `write` would, without passing them through Ruby.
    /// Returns the byte count.
    pub fn write_file(ruby: &Ruby, rb_self: &Self, path: String) -> Result<u64, Error> {
        let mut file = fs::File::open(&path)
            .map_err(|e| io::Error::new(e.kind(), format!("{e} @ rb_sysopen - {path}")))
            .rb(ruby)?;
        rb_self.with_state(ruby, |state, zip| {
            maybe_without_gvl(rb_self.needs_gvl(), || {
                let mut buf = vec![0u8; FILE_READ_BUF];
                let mut total = 0u64;
                loop {
                    crate::gvl::check()?;
                    let n = match file.read(&mut buf) {
                        Ok(0) => return Ok(total),
                        Ok(n) => n,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e),
                    };
                    feed(state, zip, &buf[..n])?;
                    total += n as u64;
                }
            })
            .rb(ruby)
        })
    }

    /// `raw_copy` of entries `indices` of `archive` in turn, each under
    /// its own name and fields, in one call: a commit that rewrites an
    /// archive copies most entries this way, and one call each (with a
    /// source and its read buffer set up for every one) cost more than
    /// the copying. None may be a ZipCrypto entry (see `copy_zipcrypto`).
    pub fn raw_copy_many(
        ruby: &Ruby,
        rb_self: &Self,
        archive: &Archive,
        indices: Vec<usize>,
    ) -> Result<(), Error> {
        let needs_gvl = archive.needs_gvl() || rb_self.needs_gvl();
        let mut source = archive.archive(ruby)?.clone();
        for index in indices {
            let file = source.by_index_raw(index).rb(ruby)?;
            if is_zipcrypto(&file) {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("entry {index} is a ZipCrypto entry; copy it with copy_zipcrypto"),
                ));
            }
            let known = known_of(&file);
            let name = file.name_raw().to_vec();
            rb_self.add_entry(ruby, needs_gvl, &name, |_, zip| {
                maybe_without_gvl(needs_gvl, || with_zip!(zip, |w| w.raw_copy_file(file)))
                    .rb(ruby)?;
                Ok(known)
            })?;
        }
        Ok(())
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
        let needs_gvl = archive.needs_gvl() || rb_self.needs_gvl();
        let new_name = new_name.map(|n| utf8_name(ruby, n)).transpose()?;
        // A clone, so the archive's borrow is released before the GVL is.
        let mut source = archive.archive(ruby)?.clone();
        let file = source.by_index_raw(index).rb(ruby)?;
        let zipcrypto = is_zipcrypto(&file);
        let known = known_of(&file);
        let name = file.name_raw().to_vec();
        let touch = touch
            .map(|h| EntryOptions::from_hash(ruby, h))
            .transpose()?;
        let index = rb_self.add_entry(ruby, needs_gvl, &name, |_, zip| {
            if zipcrypto && zip.is_stream() {
                return Err(stream_error(ruby, "ZipCrypto entries"));
            }
            maybe_without_gvl(needs_gvl, || {
                with_zip!(zip, |w| match (new_name, touch) {
                    (Some(name), _) => w.raw_copy_file_rename(file, name),
                    (None, Some(t)) => w.raw_copy_file_touch(file, t.last_modified(), t.unix_perms),
                    (None, None) => w.raw_copy_file(file),
                })
            })
            .rb(ruby)?;
            Ok(known)
        })?;
        if zipcrypto {
            // The crate drops the encryption flag of a raw-copied
            // ZipCrypto entry; the headers are otherwise right.
            rb_self.with_state(ruby, |state, _| {
                state.crypto.patches.push(Patch {
                    index,
                    flags: zipcrypto::ENCRYPTED_FLAG,
                    fields: None,
                });
                Ok(())
            })?;
        }
        Ok(())
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
        let needs_gvl = archive.needs_gvl() || rb_self.needs_gvl();
        let name = bytes_of(name);
        let options = EntryOptions::from_hash(ruby, opts)?;
        let file_options = options.to_file_options(ruby)?;
        // A clone, so the archive's borrow is released before the GVL is.
        let mut source = archive.archive(ruby)?.clone();
        rb_self.with_state(ruby, |state, zip| {
            let Zip::Seekable(w) = zip else {
                return Err(stream_error(ruby, "ZipCrypto entries"));
            };
            let patch = maybe_without_gvl(needs_gvl, || -> ZipResult<Patch> {
                state.crypto.seal_pending(w)?;
                let mut file = source.by_index_raw(index)?;
                let fields = Fields {
                    method: options.method,
                    crc: file.crc32(),
                    size: file.size(),
                    csize: file.compressed_size(),
                };
                w.start_file_with_options(file_options.name(&name))?;
                // The crate has the entry from here on: a failure below
                // takes it back out, or the archive would carry a
                // Stored entry of partial ciphertext with no flag saying
                // it is encrypted.
                let index = state.count;
                let mut copy = || -> ZipResult<u16> {
                    let copied = io::copy(&mut file, w)?;
                    if copied != fields.csize {
                        return Err(ZipError::InvalidArchive(
                            format!(
                                "entry has {copied} bytes of data, not the {} declared",
                                fields.csize
                            )
                            .into(),
                        ));
                    }
                    let mut flags = zipcrypto::ENCRYPTED_FLAG;
                    if options.descriptor {
                        w.write_all(&zipcrypto::data_descriptor(
                            fields.crc,
                            fields.csize,
                            fields.size,
                        )?)?;
                        flags |= zipcrypto::DATA_DESCRIPTOR_FLAG;
                    }
                    Ok(flags)
                };
                match copy() {
                    Ok(flags) => {
                        state.count += 1;
                        Ok(Patch {
                            index,
                            flags,
                            fields: Some(fields),
                        })
                    }
                    Err(e) => {
                        let _ = w.abort_file();
                        Err(e)
                    }
                }
            })
            .map_err(|e| entry_error(ruby, &name, e))?;
            state.crypto.patches.push(patch);
            Ok(())
        })
    }

    /// Adds files from disk, compressed on `threads` threads: `items` is
    /// an Array of `[name, path, options]`, name being raw bytes and the
    /// options what `start_entry` takes, minus encryption. The crate
    /// compresses every file to memory on a pool, then appends them in the
    /// order given (so Ruby batches by size); the sink has to be seekable.
    pub fn add_files_parallel(
        ruby: &Ruby,
        rb_self: &Self,
        items: RArray,
        threads: usize,
    ) -> Result<(), Error> {
        struct Item {
            name: Vec<u8>,
            shown: String,
            path: String,
            options: EntryOptions,
        }
        let threads = threads.max(1);
        let mut parsed = Vec::with_capacity(items.len());
        for item in items.into_iter() {
            let item = RArray::try_convert(item)?;
            let name: RString = item.entry(0)?;
            let name = bytes_of(name);
            let options = EntryOptions::from_hash(ruby, item.entry(2)?)?;
            if options.zipcrypto || options.password.is_some() {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "encrypted entries cannot be added in parallel",
                ));
            }
            parsed.push(Item {
                shown: String::from_utf8_lossy(&name).into_owned(),
                name,
                path: item.entry(1)?,
                options,
            });
        }
        let entries = parsed
            .iter()
            .map(|i| {
                let options = i.options.to_file_options(ruby)?.name(&i.name);
                Ok((i.shown.as_str(), Path::new(&i.path), options))
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))?;
        rb_self.with_state(ruby, |state, zip| {
            let Zip::Seekable(w) = zip else {
                return Err(stream_error(ruby, "entries added in parallel"));
            };
            // The crate cannot be interrupted inside a call, so the batch
            // goes in parts of a few files per thread, with a check for an
            // interrupt (see `gvl`) between them. Should a part fail or the
            // call be interrupted, the parts already in are taken back out
            // again, last first, so the batch is added whole or not at all.
            let part_len = threads * PARALLEL_PART_PER_THREAD;
            let part_bytes = threads as u64 * PARALLEL_PART_BYTES_PER_THREAD;
            maybe_without_gvl(rb_self.needs_gvl(), || -> ZipResult<()> {
                state.crypto.seal_pending(w)?;
                let mut added = 0;
                let mut rest = entries.into_iter();
                let outcome = loop {
                    // At least a file per thread, then up to `part_len`
                    // files or `part_bytes`, whichever comes first.
                    let mut part = Vec::new();
                    let mut bytes = 0u64;
                    while part.len() < part_len && (part.len() < threads || bytes < part_bytes) {
                        let Some(item) = rest.next() else { break };
                        bytes += fs::metadata(item.1).map_or(0, |m| m.len());
                        part.push(item);
                    }
                    if part.is_empty() {
                        break Ok(());
                    }
                    if let Err(e) = crate::gvl::check() {
                        break Err(ZipError::Io(e));
                    }
                    let len = part.len();
                    if let Err(e) = pool.install(|| w.par_append_from_paths_atomic(part)) {
                        break Err(e);
                    }
                    added += len;
                };
                if outcome.is_err() {
                    for _ in 0..added {
                        let _ = w.abort_file();
                    }
                }
                outcome
            })
            .map_err(|e| entry_error(ruby, b"", e))?;
            state.count += parsed.len();
            Ok(())
        })
    }

    /// Takes the entry last begun back out of the archive: the central
    /// directory will not list it, and the next entry is written over its
    /// bytes. A stream cannot go back over bytes it has sent, so there
    /// only an entry not yet begun can be taken back, which Ruby handles
    /// by deferring the start (see `OutputStream#rollback_entry`).
    pub fn rollback_entry(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.with_state(ruby, |state, zip| {
            let Zip::Seekable(w) = zip else {
                return Err(Error::new(
                    ruby.get_inner(&crate::errors::ERROR),
                    "the entry's data has already gone out on a stream that cannot seek, \
                     and cannot be taken back",
                ));
            };
            let base = state.append.as_ref().map_or(0, |a| a.base);
            if state.count <= base {
                return Err(Error::new(
                    ruby.get_inner(&crate::errors::ERROR),
                    "there is no entry to take back",
                ));
            }
            let index = state.count - 1;
            // A ZipCrypto entry in progress has nothing to seal now, and
            // no header patch of the entry may land on the next one.
            state.crypto.pending = None;
            state.crypto.patches.retain(|p| p.index != index);
            maybe_without_gvl(rb_self.needs_gvl(), || discard_last(w)).rb(ruby)?;
            state.count = index;
            Ok(())
        })
    }

    pub fn set_comment(ruby: &Ruby, rb_self: &Self, comment: RString) -> Result<(), Error> {
        let bytes = bytes_of(comment).into_boxed_slice();
        rb_self.with_state(ruby, |_, zip| {
            with_zip!(zip, |w| w.set_raw_comment(bytes)).rb(ruby)
        })
    }

    /// Writes the central directory. Returns `[bytes, stats]`: the archive
    /// bytes for a memory sink (nil for a file or Ruby IO), and one
    /// `[header_offset, size, compressed_size, crc]` per entry in the order
    /// written (for an append, per entry added), which is how Ruby learns
    /// what a streamed entry came to.
    pub fn finish(ruby: &Ruby, rb_self: &Self) -> Result<(Option<RString>, RArray), Error> {
        rb_self.check_broken(ruby)?;
        let (zip, crypto, base) = {
            let mut state = rb_self.borrow(ruby)?;
            let zip = state.zip.take().ok_or_else(|| closed_error(ruby))?;
            let base = state.append.take().map_or(0, |a| a.base);
            (zip, std::mem::take(&mut state.crypto), base)
        };
        let (sink, stats) = maybe_without_gvl(rb_self.needs_gvl(), || match zip {
            Zip::Seekable(zip) => finish_seekable(zip, crypto),
            Zip::Stream(zip, stats) => finish_stream(zip, *stats),
        })
        .rb(ruby)?;
        let bytes = match sink {
            Sink::File(_) | Sink::Ruby(_) => None,
            Sink::Memory(c) => Some(ruby.str_from_slice(&c.into_inner())),
        };
        let out = ruby.ary_new_capa(stats.len().saturating_sub(base));
        for stat in stats.into_iter().skip(base) {
            out.push(stat.to_vec())?;
        }
        Ok((bytes, out))
    }

    pub fn is_closed(&self) -> bool {
        self.inner.try_borrow().is_ok_and(|s| s.zip.is_none())
    }

    /// Bytes handed to the sink so far, for a stream (where it is what a
    /// consumer has been given); nil for a seekable sink.
    pub fn bytes_written(ruby: &Ruby, rb_self: &Self) -> Result<Option<u64>, Error> {
        let state = rb_self.borrow(ruby)?;
        Ok(match &state.zip {
            Some(Zip::Stream(_, stats)) => Some(stats.position()),
            _ => None,
        })
    }

    /// One crate action that ends the entry in progress and begins entry
    /// number `index`: seals a pending ZipCrypto entry first, then runs
    /// `begin` (which makes the crate call and says how the new entry's
    /// facts are gathered), counts the entry, and for a stream notes where
    /// it begins. Returns the index. `begin` must leave `state.count`
    /// alone, and do nothing fallible after the crate has taken the entry.
    fn add_entry(
        &self,
        ruby: &Ruby,
        needs_gvl: bool,
        name: &[u8],
        begin: impl FnOnce(&mut State, &mut Zip) -> Result<Begun, Error>,
    ) -> Result<usize, Error> {
        self.with_state(ruby, |state, zip| {
            maybe_without_gvl(needs_gvl, || {
                with_zip!(zip, |w| state.crypto.seal_pending(w))
            })
            .map_err(|e| entry_error(ruby, name, ZipError::Io(e)))?;
            let mark = zip.stats().map_or(0, StreamStats::mark);
            let begun = begin(state, zip)?;
            let index = state.count;
            state.count += 1;
            if let Some(stats) = zip.stats() {
                let header_start = stats.seal(mark);
                stats.begin(index, header_start, begun);
            }
            Ok(index)
        })
    }

    /// Takes the entry just begun back out of the archive, after a failure
    /// that leaves it unusable: the crate forgets it and the next entry is
    /// written over its bytes. Best effort; the error that brought us here
    /// is the one reported.
    fn withdraw(needs_gvl: bool, state: &mut State, zip: &mut Zip) {
        let _ = maybe_without_gvl(needs_gvl, || match zip {
            Zip::Seekable(w) => discard_last(w),
            Zip::Stream(w, _) => w.abort_file(),
        });
        state.count = state.count.saturating_sub(1);
    }

    fn borrow(&self, ruby: &Ruby) -> Result<std::cell::RefMut<'_, State>, Error> {
        self.inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "writer"))
    }

    fn with_state<T>(
        &self,
        ruby: &Ruby,
        f: impl FnOnce(&mut State, &mut Zip) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.check_broken(ruby)?;
        let mut guard = self.borrow(ruby)?;
        let state = &mut *guard;
        let mut zip = state.zip.take().ok_or_else(|| closed_error(ruby))?;
        let result = f(state, &mut zip);
        state.zip = Some(zip);
        result
    }
}

impl State {
    fn new(zip: Zip) -> Self {
        Self {
            zip: Some(zip),
            count: 0,
            crypto: Crypto::default(),
            append: None,
        }
    }
}

/// Hands `chunk` of the entry in progress to the crate: through the
/// ZipCrypto cipher when the entry is one, and counted for a stream.
fn feed(state: &mut State, zip: &mut Zip, chunk: &[u8]) -> io::Result<()> {
    match state.crypto.pending.as_mut() {
        Some(pending) => {
            let cipher = pending.feed(chunk)?;
            with_zip!(zip, |w| w.write_all(&cipher))
        }
        None => {
            if let Some(stats) = zip.stats() {
                stats.feed(chunk);
            }
            with_zip!(zip, |w| w.write_all(chunk))
        }
    }
}

/// Takes the last entry back out of a seekable archive and cuts the sink
/// off where it began. The crate rewinds to the entry's header but cannot
/// shorten the sink, and at the end it would move the central directory
/// past the dead bytes rather than leave them after it.
fn discard_last(w: &mut ZipWriter<Sink>) -> ZipResult<()> {
    w.abort_file()?;
    // SAFETY: the sink is cut at its current position and left there, as
    // `get_mut` requires; nothing the crate has written lies beyond it.
    if let Some(sink) = unsafe { w.get_mut() } {
        let at = sink.stream_position()?;
        sink.end_at(at)?;
    }
    Ok(())
}

/// Seals a ZipCrypto entry still in progress, writes the central
/// directory, reads the archive back for the per-entry facts, and patches
/// the headers of ZipCrypto entries.
fn finish_seekable(mut zip: ZipWriter<Sink>, mut crypto: Crypto) -> ZipResult<(Sink, EntryStats)> {
    crypto.seal_pending(&mut zip)?;
    let archive = zip.finish_into_readable()?;
    let mut stats = collect_stats(&archive)?;
    let mut sink = archive.into_inner();
    if !crypto.patches.is_empty() {
        sink = zipcrypto::apply_patches(sink, &crypto.patches, &mut stats)?;
    }
    sink.flush()?;
    if let Sink::Ruby(w) = &mut sink {
        w.get_mut().truncate_to_end()?;
        w.get_mut().seek_to_end()?;
    }
    Ok((sink, stats))
}

/// Writes the central directory to a stream; the per-entry facts were
/// gathered as the entries went by (ZipCrypto never reaches a stream, so
/// there is nothing to seal or patch).
fn finish_stream(
    zip: ZipWriter<StreamWriter<Counting>>,
    mut stats: StreamStats,
) -> ZipResult<(Sink, EntryStats)> {
    let mark = stats.mark();
    let mut sink = zip.finish()?.into_inner().sink;
    stats.seal(mark);
    sink.flush()?;
    Ok((sink, std::mem::take(&mut stats.entries)))
}

/// What was written for each entry, in order; see `EntryStats`.
fn collect_stats(archive: &ZipArchive<Sink>) -> ZipResult<EntryStats> {
    let meta = archive.metadata();
    (0..meta.len())
        .map(|i| {
            let e = meta.entry(i)?;
            Ok(crate::stream_stats::EntryStat {
                header_start: e.header_start(),
                size: e.size(),
                csize: e.compressed_size(),
                crc: e.crc32(),
            })
        })
        .collect()
}

/// What a stream cannot take: anything that would need a header patched
/// once the data is written.
fn stream_error(ruby: &Ruby, what: &str) -> Error {
    Error::new(
        ruby.exception_arg_error(),
        format!(
            "{what} cannot be written to a stream (an IO that cannot seek); \
             write to a file, a StringIO or a seekable IO instead"
        ),
    )
}

fn closed_error(ruby: &Ruby) -> Error {
    Error::new(ruby.exception_io_error(), "closed stream")
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
