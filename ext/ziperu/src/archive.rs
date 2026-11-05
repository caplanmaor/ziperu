//! `Zip::Native::Archive`: a read-only handle on a parsed central directory.
//!
//! Entry metadata crosses the Ruby boundary as plain Hashes (all at once via
//! `entries`, or one at a time via `entry_meta`); afterwards Ruby only talks
//! to the archive by index.

use std::cell::{RefCell, RefMut};
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};

use magnus::{prelude::*, Error, RArray, RHash, RString, Ruby};
use zip::read::ZipFile;
use zip::ZipArchive;

use crate::errors::{io_error, zip_error};
use crate::reader::EntryReader;
use crate::source::Source;

#[magnus::wrap(class = "Zip::Native::Archive", free_immediately)]
pub struct Archive {
    // Single-threaded under the GVL; RefCell gives us &mut for by_index.
    // `None` once closed, which releases the file handle at once rather
    // than when the GC gets round to it (commit renames over the file).
    inner: RefCell<Option<ZipArchive<Source>>>,
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
            inner: RefCell::new(Some(archive)),
        })
    }

    /// The open archive, or an IOError once closed.
    pub(crate) fn archive(&self, ruby: &Ruby) -> Result<RefMut<'_, ZipArchive<Source>>, Error> {
        RefMut::filter_map(self.inner.borrow_mut(), Option::as_mut)
            .map_err(|_| Error::new(ruby.exception_io_error(), "closed archive"))
    }

    /// Releases the underlying file. Readers already opened keep their own
    /// handle and continue to work.
    pub fn close(&self) {
        self.inner.borrow_mut().take();
    }

    pub fn is_closed(&self) -> bool {
        self.inner.borrow().is_none()
    }

    pub fn entry_count(ruby: &Ruby, rb_self: &Self) -> Result<usize, Error> {
        Ok(rb_self.archive(ruby)?.len())
    }

    pub fn comment(ruby: &Ruby, rb_self: &Self) -> Result<RString, Error> {
        Ok(ruby.str_from_slice(rb_self.archive(ruby)?.comment()))
    }

    /// One Hash per entry, in central-directory order.
    pub fn entries(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let mut archive = rb_self.archive(ruby)?;
        let mut raw = archive.clone().into_inner();
        let out = ruby.ary_new_capa(archive.len());
        for i in 0..archive.len() {
            let entry = archive.by_index_raw(i).map_err(|e| zip_error(ruby, e))?;
            let extra = raw_central_extra(&mut raw, entry.central_header_start())
                .map_err(|e| io_error(ruby, e))?;
            out.push(entry_hash(ruby, i, &entry, &extra)?)?;
        }
        Ok(out)
    }

    /// The Hash for a single entry.
    pub fn entry_meta(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RHash, Error> {
        let mut archive = rb_self.archive(ruby)?;
        let mut raw = archive.clone().into_inner();
        let entry = archive
            .by_index_raw(index)
            .map_err(|e| zip_error(ruby, e))?;
        let extra = raw_central_extra(&mut raw, entry.central_header_start())
            .map_err(|e| io_error(ruby, e))?;
        entry_hash(ruby, index, &entry, &extra)
    }

    /// The raw extra field bytes of entry `index`'s local header. Some
    /// fields (Info-ZIP unix uid/gid, extended timestamp atime/ctime) only
    /// carry their data there; Ruby merges them lazily.
    pub fn local_extra(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        let mut archive = rb_self.archive(ruby)?;
        let header_start = archive
            .by_index_raw(index)
            .map_err(|e| zip_error(ruby, e))?
            .header_start();
        let mut raw = archive.clone().into_inner();
        let extra = raw_local_extra(&mut raw, header_start).map_err(|e| io_error(ruby, e))?;
        Ok(ruby.str_from_slice(&extra))
    }

    /// A chunked reader over entry `index`, with its own cursor. With
    /// `enforce_size` false it reads past the declared size to the true end
    /// of the data.
    pub fn open_entry(
        ruby: &Ruby,
        rb_self: &Self,
        index: usize,
        password: Option<RString>,
        enforce_size: bool,
    ) -> Result<EntryReader, Error> {
        let password = password.map(|p| unsafe { p.as_slice() }.to_vec());
        let archive = rb_self.archive(ruby)?.clone();
        EntryReader::open(ruby, archive, index, password, enforce_size)
    }

    /// Whole decompressed entry as a binary String.
    pub fn read_entry(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        let mut archive = rb_self.archive(ruby)?;
        let mut entry = archive.by_index(index).map_err(|e| zip_error(ruby, e))?;
        let mut buf = Vec::with_capacity(entry.size().min(u32::MAX as u64) as usize);
        entry.read_to_end(&mut buf).map_err(|e| io_error(ruby, e))?;
        Ok(ruby.str_from_slice(&buf))
    }
}

/// The extra field bytes of a central directory record, exactly as stored.
/// The crate re-serializes the fields it parsed, which drops some (an
/// extended timestamp without the local-only parts, for one); rubyzip hands
/// out the raw bytes, so we read them ourselves.
fn raw_central_extra(source: &mut Source, central_offset: u64) -> io::Result<Vec<u8>> {
    const SIGNATURE: u32 = 0x0201_4b50;
    const HEADER_LEN: usize = 46;

    source.seek(SeekFrom::Start(central_offset))?;
    let mut header = [0u8; HEADER_LEN];
    source.read_exact(&mut header)?;
    if u32::from_le_bytes([header[0], header[1], header[2], header[3]]) != SIGNATURE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "central directory signature not found",
        ));
    }
    let name_len = u16::from_le_bytes([header[28], header[29]]) as i64;
    let extra_len = u16::from_le_bytes([header[30], header[31]]) as usize;
    source.seek(SeekFrom::Current(name_len))?;
    let mut extra = vec![0u8; extra_len];
    source.read_exact(&mut extra)?;
    Ok(extra)
}

/// The extra field bytes of a local file header, exactly as stored.
fn raw_local_extra(source: &mut Source, header_offset: u64) -> io::Result<Vec<u8>> {
    const SIGNATURE: u32 = 0x0403_4b50;
    const HEADER_LEN: usize = 30;

    source.seek(SeekFrom::Start(header_offset))?;
    let mut header = [0u8; HEADER_LEN];
    source.read_exact(&mut header)?;
    if u32::from_le_bytes([header[0], header[1], header[2], header[3]]) != SIGNATURE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "local file header signature not found",
        ));
    }
    let name_len = u16::from_le_bytes([header[26], header[27]]) as i64;
    let extra_len = u16::from_le_bytes([header[28], header[29]]) as usize;
    source.seek(SeekFrom::Current(name_len))?;
    let mut extra = vec![0u8; extra_len];
    source.read_exact(&mut extra)?;
    Ok(extra)
}

fn entry_hash(
    ruby: &Ruby,
    index: usize,
    entry: &ZipFile<'_, Source>,
    extra: &[u8],
) -> Result<RHash, Error> {
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
    set("flags", ruby.into_value(entry.flags().as_u16()))?;
    set(
        "external_attributes",
        ruby.into_value(entry.external_attributes()),
    )?;
    // "Version made by": high byte is the host system, low byte the spec
    // version; rubyzip keeps them as fstype / version.
    set("fstype", ruby.into_value(u8::from(entry.system())))?;
    let (major, minor) = entry.version_made_by();
    set("version_made_by", ruby.into_value(major * 10 + minor))?;
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
    set("extra", ruby.str_from_slice(extra).as_value())?;
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
