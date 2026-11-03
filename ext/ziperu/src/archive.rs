//! `Zip::Native::Archive`: a read-only handle on a parsed central directory.
//!
//! Entry metadata crosses the Ruby boundary as plain Hashes (all at once via
//! `entries`, or one at a time via `entry_meta`); afterwards Ruby only talks
//! to the archive by index.

use std::cell::RefCell;
use std::fs;
use std::io::Read;

use magnus::{prelude::*, Error, RArray, RHash, RString, Ruby};
use zip::read::ZipFile;
use zip::ZipArchive;

use crate::errors::{io_error, zip_error};
use crate::reader::EntryReader;
use crate::source::Source;

#[magnus::wrap(class = "Zip::Native::Archive", free_immediately)]
pub struct Archive {
    // Single-threaded under the GVL; RefCell gives us &mut for by_index.
    inner: RefCell<ZipArchive<Source>>,
}

impl Archive {
    pub fn open_path(ruby: &Ruby, path: String) -> Result<Self, Error> {
        let file = fs::File::open(&path).map_err(|e| io_error(ruby, e))?;
        Self::from_source(ruby, Source::file(file))
    }

    pub fn open_bytes(ruby: &Ruby, bytes: RString) -> Result<Self, Error> {
        // Copy once; the Ruby string may be mutated or GC'd after this call.
        let vec = unsafe { bytes.as_slice() }.to_vec();
        Self::from_source(ruby, Source::memory(vec))
    }

    fn from_source(ruby: &Ruby, source: Source) -> Result<Self, Error> {
        let archive = ZipArchive::new(source).map_err(|e| zip_error(ruby, e))?;
        Ok(Self {
            inner: RefCell::new(archive),
        })
    }

    pub fn entry_count(&self) -> usize {
        self.inner.borrow().len()
    }

    pub fn comment(ruby: &Ruby, rb_self: &Self) -> RString {
        ruby.str_from_slice(rb_self.inner.borrow().comment())
    }

    /// One Hash per entry, in central-directory order.
    pub fn entries(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let mut archive = rb_self.inner.borrow_mut();
        let out = ruby.ary_new_capa(archive.len());
        for i in 0..archive.len() {
            let entry = archive.by_index_raw(i).map_err(|e| zip_error(ruby, e))?;
            out.push(entry_hash(ruby, i, &entry)?)?;
        }
        Ok(out)
    }

    /// The Hash for a single entry.
    pub fn entry_meta(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RHash, Error> {
        let mut archive = rb_self.inner.borrow_mut();
        let entry = archive
            .by_index_raw(index)
            .map_err(|e| zip_error(ruby, e))?;
        entry_hash(ruby, index, &entry)
    }

    /// A chunked reader over entry `index`, with its own cursor.
    pub fn open_entry(
        ruby: &Ruby,
        rb_self: &Self,
        index: usize,
        password: Option<RString>,
    ) -> Result<EntryReader, Error> {
        let password = password.map(|p| unsafe { p.as_slice() }.to_vec());
        let archive = rb_self.inner.borrow().clone();
        EntryReader::open(ruby, archive, index, password)
    }

    /// Whole decompressed entry as a binary String.
    pub fn read_entry(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        let mut archive = rb_self.inner.borrow_mut();
        let mut entry = archive.by_index(index).map_err(|e| zip_error(ruby, e))?;
        let mut buf = Vec::with_capacity(entry.size().min(u32::MAX as u64) as usize);
        entry.read_to_end(&mut buf).map_err(|e| io_error(ruby, e))?;
        Ok(ruby.str_from_slice(&buf))
    }
}

fn entry_hash(ruby: &Ruby, index: usize, entry: &ZipFile<'_, Source>) -> Result<RHash, Error> {
    let h = ruby.hash_new();
    let set = |key: &str, value: magnus::Value| -> Result<(), Error> {
        h.aset(ruby.to_symbol(key), value)
    };
    set("index", ruby.into_value(index))?;
    set("name", ruby.str_from_slice(entry.name_raw()).as_value())?;
    set("size", ruby.into_value(entry.size()))?;
    set("compressed_size", ruby.into_value(entry.compressed_size()))?;
    set("crc", ruby.into_value(entry.crc32()))?;
    set(
        "compression_method",
        ruby.into_value(compression_code(entry.compression())),
    )?;
    set("directory", ruby.into_value(entry.is_dir()))?;
    set("encrypted", ruby.into_value(entry.encrypted()))?;
    set("unix_mode", ruby.into_value(entry.unix_mode()))?;
    let (date, time) = entry
        .last_modified()
        .map(|dt| (dt.datepart(), dt.timepart()))
        .unwrap_or((0, 0));
    set("dos_date", ruby.into_value(date))?;
    set("dos_time", ruby.into_value(time))?;
    set(
        "comment",
        ruby.str_from_slice(entry.comment().as_bytes()).as_value(),
    )?;
    let extra = entry.extra_data().unwrap_or_default();
    set("extra", ruby.str_from_slice(&extra).as_value())?;
    set("header_offset", ruby.into_value(entry.header_start()))?;
    set("data_offset", ruby.into_value(entry.data_start()))?;
    set(
        "central_offset",
        ruby.into_value(entry.central_header_start()),
    )?;
    Ok(h)
}

/// The on-disk compression method code, as rubyzip exposes it.
///
/// `to_u16` is deprecated in favour of matching on constants, but it is the
/// only public way to recover the raw code, which is what we hand to Ruby.
#[allow(deprecated)]
fn compression_code(method: zip::CompressionMethod) -> u16 {
    method.to_u16()
}
