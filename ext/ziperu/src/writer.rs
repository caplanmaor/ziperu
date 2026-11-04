//! `Zip::Native::Writer`: writes a new archive entry by entry.
//!
//! The Ruby side (`Zip::OutputStream`) owns entry objects, defaults and the
//! IO-like methods; this is the thin layer over `zip::ZipWriter`. The sink
//! is either a file on disk or an in-memory buffer whose bytes `finish`
//! returns, which is how `write_buffer(io)` feeds an arbitrary Ruby IO.

use std::cell::RefCell;
use std::fs;
use std::io::{self, BufWriter, Cursor, Seek, SeekFrom, Write};

use magnus::{prelude::*, Error, RHash, RString, Ruby};
use zip::write::FullFileOptions;
use zip::{AesMode, CompressionMethod, DateTime, ZipWriter};

use crate::archive::Archive;
use crate::errors::{io_error, zip_error};

pub enum Sink {
    File(BufWriter<fs::File>),
    Memory(Cursor<Vec<u8>>),
}

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Sink::File(f) => f.write(buf),
            Sink::Memory(c) => c.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Sink::File(f) => f.flush(),
            Sink::Memory(c) => c.flush(),
        }
    }
}

impl Seek for Sink {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match self {
            Sink::File(f) => f.seek(pos),
            Sink::Memory(c) => c.seek(pos),
        }
    }
}

#[magnus::wrap(class = "Zip::Native::Writer", free_immediately)]
pub struct Writer {
    // `None` once finished. Single-threaded under the GVL.
    inner: RefCell<Option<ZipWriter<Sink>>>,
}

/// Per-entry settings, read from the Hash Ruby passes to `start_entry`.
struct EntryOptions {
    method: u16,
    level: Option<i64>,
    dos_date: u16,
    dos_time: u16,
    unix_perms: Option<u32>,
    large_file: bool,
    comment: Option<String>,
    /// Concatenated local-format extra fields: id, len, data.
    extra: Vec<u8>,
    password: Option<Vec<u8>>,
    aes_mode: Option<u8>,
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
            large_file: opt("large_file")?
                .map(bool::try_convert)
                .transpose()?
                .unwrap_or(false),
            comment: opt("comment")?.map(String::try_convert).transpose()?,
            extra: opt("extra")?
                .map(RString::try_convert)
                .transpose()?
                .map(|s| unsafe { s.as_slice() }.to_vec())
                .unwrap_or_default(),
            password: opt("password")?
                .map(RString::try_convert)
                .transpose()?
                .map(|s| unsafe { s.as_slice() }.to_vec()),
            aes_mode: opt("aes_mode")?.map(u8::try_convert).transpose()?,
        })
    }

    fn to_file_options(&self, ruby: &Ruby) -> Result<FullFileOptions<'_, 'static>, Error> {
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
        let mut options = FullFileOptions::default()
            .compression_method(method)
            .compression_level(self.level)
            .large_file(self.large_file)
            .last_modified_time(
                DateTime::try_from_msdos(self.dos_date, self.dos_time)
                    .unwrap_or_else(|_| DateTime::default_for_write()),
            );
        if let Some(perms) = self.unix_perms {
            options = options.unix_permissions(perms);
        }
        if let Some(comment) = &self.comment {
            options = options.with_file_comment(comment.as_str());
        }
        if let Some(password) = &self.password {
            let mode = match self.aes_mode {
                Some(1) => AesMode::Aes128,
                Some(2) => AesMode::Aes192,
                _ => AesMode::Aes256,
            };
            options = options.with_aes_encryption_bytes(mode, password);
        }
        let mut i = 0;
        while i + 4 <= self.extra.len() {
            let id = u16::from_le_bytes([self.extra[i], self.extra[i + 1]]);
            let len = u16::from_le_bytes([self.extra[i + 2], self.extra[i + 3]]) as usize;
            let data = self.extra.get(i + 4..i + 4 + len).unwrap_or(&[]);
            options
                .add_extra_field(id, data, false)
                .map_err(|e| zip_error(ruby, e))?;
            i += 4 + len;
        }
        Ok(options)
    }
}

impl Writer {
    pub fn open_path(ruby: &Ruby, path: String) -> Result<Self, Error> {
        let file = fs::File::create(&path).map_err(|e| io_error(ruby, e))?;
        Ok(Self::new(Sink::File(BufWriter::new(file))))
    }

    pub fn open_memory() -> Self {
        Self::new(Sink::Memory(Cursor::new(Vec::new())))
    }

    fn new(sink: Sink) -> Self {
        Self {
            inner: RefCell::new(Some(ZipWriter::new(sink))),
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
        let file_options = options.to_file_options(ruby)?;
        rb_self.with_writer(ruby, |w| {
            w.start_file_with_options(file_options.name(&name))
                .map_err(|e| zip_error(ruby, e))
        })
    }

    /// Finishes the previous entry and adds a directory entry.
    pub fn add_directory(
        ruby: &Ruby,
        rb_self: &Self,
        name: String,
        opts: RHash,
    ) -> Result<(), Error> {
        let options = EntryOptions::from_hash(ruby, opts)?;
        let file_options = options.to_file_options(ruby)?;
        rb_self.with_writer(ruby, |w| {
            w.add_directory(name, file_options)
                .map_err(|e| zip_error(ruby, e))
        })
    }

    pub fn write(ruby: &Ruby, rb_self: &Self, data: RString) -> Result<usize, Error> {
        let bytes = unsafe { data.as_slice() };
        rb_self.with_writer(ruby, |w| {
            w.write_all(bytes).map_err(|e| io_error(ruby, e))?;
            Ok(bytes.len())
        })
    }

    /// Copies entry `index` of `archive` without decompressing it, under
    /// `new_name` if given.
    pub fn raw_copy(
        ruby: &Ruby,
        rb_self: &Self,
        archive: &Archive,
        index: usize,
        new_name: Option<String>,
    ) -> Result<(), Error> {
        let mut source = archive.inner.borrow_mut();
        let file = source.by_index_raw(index).map_err(|e| zip_error(ruby, e))?;
        rb_self.with_writer(ruby, |w| {
            match new_name {
                Some(name) => w.raw_copy_file_rename(file, name),
                None => w.raw_copy_file(file),
            }
            .map_err(|e| zip_error(ruby, e))
        })
    }

    pub fn set_comment(ruby: &Ruby, rb_self: &Self, comment: RString) -> Result<(), Error> {
        let bytes = unsafe { comment.as_slice() }.to_vec().into_boxed_slice();
        rb_self.with_writer(ruby, |w| {
            w.set_raw_comment(bytes).map_err(|e| zip_error(ruby, e))
        })
    }

    /// Writes the central directory. Returns the archive bytes for a memory
    /// sink, nil for a file.
    pub fn finish(ruby: &Ruby, rb_self: &Self) -> Result<Option<RString>, Error> {
        let writer = rb_self
            .inner
            .borrow_mut()
            .take()
            .ok_or_else(|| Error::new(ruby.exception_io_error(), "closed stream"))?;
        let sink = writer.finish().map_err(|e| zip_error(ruby, e))?;
        match sink {
            Sink::File(mut f) => {
                f.flush().map_err(|e| io_error(ruby, e))?;
                Ok(None)
            }
            Sink::Memory(c) => Ok(Some(ruby.str_from_slice(&c.into_inner()))),
        }
    }

    pub fn is_closed(&self) -> bool {
        self.inner.borrow().is_none()
    }

    fn with_writer<T>(
        &self,
        ruby: &Ruby,
        f: impl FnOnce(&mut ZipWriter<Sink>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let mut guard = self.inner.borrow_mut();
        let writer = guard
            .as_mut()
            .ok_or_else(|| Error::new(ruby.exception_io_error(), "closed stream"))?;
        f(writer)
    }
}
