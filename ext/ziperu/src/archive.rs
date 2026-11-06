//! `Ziperu::Native::Archive`: a read-only handle on a parsed central directory.
//!
//! Entry metadata crosses the Ruby boundary as plain Hashes (all at once via
//! `entries`, or one at a time via `entry_meta`); afterwards Ruby only talks
//! to the archive by index.

use std::cell::{RefCell, RefMut};
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};

use magnus::{
    gc::Marker, typed_data::DataTypeFunctions, value::Opaque, Error, RArray, RHash, RString, Ruby,
    Symbol, TypedData, Value,
};
use zip::read::ZipFileEntry;
use zip::result::ZipResult;
use zip::ZipArchive;

use crate::errors::{busy_error, io_error, read_error, zip_error};
use crate::gvl::maybe_without_gvl;
use crate::reader::EntryReader;
use crate::source::Source;

/// Never pre-allocate more than this on the strength of a header field.
const CAPACITY_HINT_MAX: u64 = 1 << 20;

#[derive(TypedData)]
#[magnus(class = "Ziperu::Native::Archive", free_immediately, mark)]
pub struct Archive {
    // Borrowed only while holding the GVL and never across a release of it
    // (work that releases the GVL runs on a clone), so a failed borrow
    // means another thread is inside a method right now. `None` once
    // closed, which releases the file handle at once rather than when the
    // GC gets round to it (commit renames over the file).
    inner: RefCell<Option<ZipArchive<Source>>>,
    /// The Ruby IO behind a `Source::Ruby`, kept alive by `mark`.
    io: Option<Opaque<Value>>,
    /// True for a Ruby IO source, whose reads must hold the GVL.
    needs_gvl: bool,
}

impl DataTypeFunctions for Archive {
    fn mark(&self, marker: &Marker) {
        if let Some(io) = self.io {
            marker.mark(io);
        }
    }
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

    /// Any seekable IO-like Ruby object; read lazily, never copied.
    pub fn open_io(ruby: &Ruby, io: Value) -> Result<Self, Error> {
        Self::from_source(ruby, Source::ruby(io)?)
    }

    fn from_source(ruby: &Ruby, source: Source) -> Result<Self, Error> {
        let needs_gvl = source.needs_gvl();
        let io = source.ruby_io();
        let archive = maybe_without_gvl(needs_gvl, || ZipArchive::new(source))
            .map_err(|e| zip_error(ruby, e))?;
        Ok(Self {
            inner: RefCell::new(Some(archive)),
            io,
            needs_gvl,
        })
    }

    pub(crate) fn needs_gvl(&self) -> bool {
        self.needs_gvl
    }

    /// The open archive, or an IOError once closed.
    pub(crate) fn archive(&self, ruby: &Ruby) -> Result<RefMut<'_, ZipArchive<Source>>, Error> {
        let guard = self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "archive"))?;
        RefMut::filter_map(guard, Option::as_mut)
            .map_err(|_| Error::new(ruby.exception_io_error(), "closed archive"))
    }

    /// Releases the underlying file. Readers already opened keep their own
    /// handle and continue to work.
    pub fn close(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self
            .inner
            .try_borrow_mut()
            .map_err(|_| busy_error(ruby, "archive"))?
            .take();
        Ok(())
    }

    pub fn is_closed(&self) -> bool {
        self.inner.try_borrow().is_ok_and(|a| a.is_none())
    }

    pub fn entry_count(ruby: &Ruby, rb_self: &Self) -> Result<usize, Error> {
        Ok(rb_self.archive(ruby)?.len())
    }

    pub fn comment(ruby: &Ruby, rb_self: &Self) -> Result<RString, Error> {
        Ok(ruby.str_from_slice(rb_self.archive(ruby)?.comment()))
    }

    /// One Hash per entry, in central-directory order.
    ///
    /// The parsed central directory already holds nearly everything; the
    /// few fields read raw come from one sequential pass over the records,
    /// done without the GVL when the source allows it.
    pub fn entries(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        let mut raw = archive.clone().into_inner();
        drop(archive);
        let fields = maybe_without_gvl(rb_self.needs_gvl, || {
            (0..meta.len())
                .map(|i| {
                    let entry = meta.entry(i)?;
                    Ok(raw_central_fields(&mut raw, entry.central_header_start())?)
                })
                .collect::<ZipResult<Vec<_>>>()
        })
        .map_err(|e| zip_error(ruby, e))?;
        let keys = MetaKeys::new(ruby);
        let out = ruby.ary_new_capa(meta.len());
        for (i, fields) in fields.iter().enumerate() {
            let entry = meta.entry(i).map_err(|e| zip_error(ruby, e))?;
            out.push(entry_hash(ruby, &keys, i, &entry, fields)?)?;
        }
        Ok(out)
    }

    /// The Hash for a single entry.
    pub fn entry_meta(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RHash, Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        let mut raw = archive.clone().into_inner();
        drop(archive);
        let entry = meta.entry(index).map_err(|e| zip_error(ruby, e))?;
        let fields = raw_central_fields(&mut raw, entry.central_header_start())
            .map_err(|e| io_error(ruby, e))?;
        entry_hash(ruby, &MetaKeys::new(ruby), index, &entry, &fields)
    }

    /// The raw extra field bytes of entry `index`'s local header. Some
    /// fields (Info-ZIP unix uid/gid, extended timestamp atime/ctime) only
    /// carry their data there; Ruby merges them lazily.
    pub fn local_extra(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        let archive = rb_self.archive(ruby)?;
        let header_start = archive
            .metadata()
            .entry(index)
            .map_err(|e| zip_error(ruby, e))?
            .header_start();
        let mut raw = archive.clone().into_inner();
        drop(archive);
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
        EntryReader::open(
            ruby,
            archive,
            index,
            password,
            enforce_size,
            rb_self.needs_gvl,
            rb_self.io,
        )
    }

    /// Whole decompressed entry as a binary String.
    pub fn read_entry(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        // A clone (the central directory is shared behind an Arc) so the
        // borrow is released before the GVL is.
        let mut archive = rb_self.archive(ruby)?.clone();
        let mut entry = archive.by_index(index).map_err(|e| zip_error(ruby, e))?;
        // A hint only: the declared size is untrusted and may be a lie.
        let mut buf = Vec::with_capacity(entry.size().min(CAPACITY_HINT_MAX) as usize);
        maybe_without_gvl(rb_self.needs_gvl, || entry.read_to_end(&mut buf))
            .map_err(|e| read_error(ruby, e))?;
        Ok(ruby.str_from_slice(&buf))
    }
}

/// Fields of a central directory record read straight from the bytes,
/// where the crate's parsed view is not what rubyzip exposes.
struct RawCentralFields {
    /// The extra field exactly as stored. The crate re-serializes the
    /// fields it parsed, which drops some (an extended timestamp without
    /// the local-only parts, for one); rubyzip hands out the raw bytes.
    extra: Vec<u8>,
    /// The DOS time and date as stored. The crate's `DateTime` rejects
    /// values a calendar would roll over (February 30th), which rubyzip
    /// reads as the next day.
    dos_time: u16,
    dos_date: u16,
}

fn raw_central_fields(source: &mut Source, central_offset: u64) -> io::Result<RawCentralFields> {
    const SIGNATURE: u32 = 0x0201_4b50;
    const HEADER_LEN: usize = 46;

    source.seek_to(central_offset)?;
    let mut header = [0u8; HEADER_LEN];
    source.read_exact(&mut header)?;
    if u32::from_le_bytes([header[0], header[1], header[2], header[3]]) != SIGNATURE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "central directory signature not found",
        ));
    }
    let dos_time = u16::from_le_bytes([header[12], header[13]]);
    let dos_date = u16::from_le_bytes([header[14], header[15]]);
    let name_len = u16::from_le_bytes([header[28], header[29]]) as i64;
    let extra_len = u16::from_le_bytes([header[30], header[31]]) as usize;
    source.seek(SeekFrom::Current(name_len))?;
    let mut extra = vec![0u8; extra_len];
    source.read_exact(&mut extra)?;
    Ok(RawCentralFields {
        extra,
        dos_time,
        dos_date,
    })
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

/// The Hash keys, interned once per listing rather than once per entry.
struct MetaKeys {
    index: Symbol,
    name: Symbol,
    size: Symbol,
    compressed_size: Symbol,
    crc: Symbol,
    compression_method: Symbol,
    flags: Symbol,
    external_attributes: Symbol,
    fstype: Symbol,
    version_made_by: Symbol,
    dos_date: Symbol,
    dos_time: Symbol,
    comment: Symbol,
    extra: Symbol,
    header_offset: Symbol,
}

impl MetaKeys {
    fn new(ruby: &Ruby) -> Self {
        Self {
            index: ruby.to_symbol("index"),
            name: ruby.to_symbol("name"),
            size: ruby.to_symbol("size"),
            compressed_size: ruby.to_symbol("compressed_size"),
            crc: ruby.to_symbol("crc"),
            compression_method: ruby.to_symbol("compression_method"),
            flags: ruby.to_symbol("flags"),
            external_attributes: ruby.to_symbol("external_attributes"),
            fstype: ruby.to_symbol("fstype"),
            version_made_by: ruby.to_symbol("version_made_by"),
            dos_date: ruby.to_symbol("dos_date"),
            dos_time: ruby.to_symbol("dos_time"),
            comment: ruby.to_symbol("comment"),
            extra: ruby.to_symbol("extra"),
            header_offset: ruby.to_symbol("header_offset"),
        }
    }
}

fn entry_hash(
    ruby: &Ruby,
    keys: &MetaKeys,
    index: usize,
    entry: &ZipFileEntry<'_>,
    raw: &RawCentralFields,
) -> Result<RHash, Error> {
    let h = ruby.hash_new_capa(15);
    h.aset(keys.index, index)?;
    h.aset(keys.name, ruby.str_from_slice(entry.name_raw()))?;
    h.aset(keys.size, entry.size())?;
    h.aset(keys.compressed_size, entry.compressed_size())?;
    h.aset(keys.crc, entry.crc32())?;
    h.aset(
        keys.compression_method,
        compression_code(entry.compression()),
    )?;
    h.aset(keys.flags, entry.flags().as_u16())?;
    h.aset(keys.external_attributes, entry.external_attributes())?;
    // "Version made by": high byte is the host system, low byte the spec
    // version; rubyzip keeps them as fstype / version.
    h.aset(keys.fstype, u8::from(entry.system()))?;
    let (major, minor) = entry.version_made_by();
    h.aset(keys.version_made_by, major * 10 + minor)?;
    h.aset(keys.dos_date, raw.dos_date)?;
    h.aset(keys.dos_time, raw.dos_time)?;
    h.aset(
        keys.comment,
        ruby.str_from_slice(entry.comment().as_bytes()),
    )?;
    h.aset(keys.extra, ruby.str_from_slice(&raw.extra))?;
    h.aset(keys.header_offset, entry.header_start())?;
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
