//! `Ziperu::Native::Archive`: a read-only handle on a parsed central directory.
//!
//! Entry metadata crosses the Ruby boundary as plain Hashes (all at once via
//! `entries`, or one at a time via `entry_meta`); afterwards Ruby only talks
//! to the archive by index.

use std::cell::{RefCell, RefMut};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};

use magnus::{
    gc::Marker, typed_data::DataTypeFunctions, value::Opaque, Error, RArray, RHash, RString, Ruby,
    Symbol, TypedData, Value,
};
use zip::read::{ZipFileEntry, ZipReadOptions};
use zip::result::{ZipError, ZipResult};
use zip::ZipArchive;

use crate::entry_options::extra_fields;
use crate::errors::{busy_error, header_error, read_error, zip_read_error, IntoRuby};
use crate::gvl::{maybe_without_gvl, Cancellable};
use crate::rb::{bytes_of, read_into_string, size_believable};
use crate::reader::{
    local_header_lens, open_local_entry, EntryInfo, EntryReader, LOCAL_HEADER_LEN,
};
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
        let file = fs::File::open(&path).rb(ruby)?;
        Self::from_source(ruby, Source::file(file))
    }

    pub fn open_bytes(ruby: &Ruby, bytes: RString) -> Result<Self, Error> {
        // SAFETY: copied out at once into the Arc, with the GVL held and
        // no Ruby call in between: one copy, rather than a Vec and then
        // the Arc it is moved into (twice the archive's size, briefly).
        let shared: std::sync::Arc<[u8]> = std::sync::Arc::from(unsafe { bytes.as_slice() });
        Self::from_source(ruby, Source::memory(shared))
    }

    /// Any seekable IO-like Ruby object; read lazily, never copied.
    pub fn open_io(ruby: &Ruby, io: Value) -> Result<Self, Error> {
        Self::from_source(ruby, Source::ruby(io)?)
    }

    fn from_source(ruby: &Ruby, source: Source) -> Result<Self, Error> {
        let needs_gvl = source.needs_gvl();
        let io = source.ruby_io();
        let archive = maybe_without_gvl(needs_gvl, || ZipArchive::new(source)).rb(ruby)?;
        Ok(Self {
            inner: RefCell::new(Some(archive)),
            io,
            needs_gvl,
        })
    }

    pub(crate) fn needs_gvl(&self) -> bool {
        self.needs_gvl
    }

    /// A source of its own over the archive's bytes, for work that must
    /// not hold the archive borrowed (anything that releases the GVL).
    fn source(&self, ruby: &Ruby) -> Result<Source, Error> {
        Ok(self.archive(ruby)?.clone().into_inner())
    }

    /// `source` with a small read buffer, for a few header bytes.
    fn small_source(&self, ruby: &Ruby) -> Result<Source, Error> {
        Ok(small_source(&*self.archive(ruby)?))
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

    /// True when the central directory holds several records under one
    /// name. The crate keys its parsed view by name and so keeps only the
    /// last of them; `entries` then walks the raw records instead.
    pub fn has_duplicate_names(ruby: &Ruby, rb_self: &Self) -> Result<bool, Error> {
        Ok(rb_self.archive(ruby)?.has_duplicate_names())
    }

    /// What the open-time limits look at, in one pass:
    /// `[records, total_size, largest_size, highest_ratio]`.
    ///
    /// Every record counts, including several under one name. The crate's
    /// parsed view keeps only the last record of each name, but `entries`,
    /// `InputStream` and `extract_all` reach every one of them, so the
    /// limits must too: otherwise a bomb hides behind a harmless entry of
    /// the same name.
    ///
    /// An entry declaring data but no compressed bytes has an infinite
    /// ratio. The archive's overall ratio can be no higher than its
    /// highest entry's, so that bounds it too.
    pub fn limits(ruby: &Ruby, rb_self: &Self) -> Result<(usize, u64, u64, f64), Error> {
        let archive = rb_self.archive(ruby)?;
        let mut summary = LimitSummary::default();
        if archive.has_duplicate_names() {
            let dir_start = archive.central_directory_start();
            let mut raw = archive.clone().into_inner();
            drop(archive);
            let records = maybe_without_gvl(rb_self.needs_gvl, || {
                walk_central_directory(&mut raw, dir_start)
            })
            .map_err(|e| header_error(ruby, e))?;
            for record in &records {
                summary.add(record.size, record.compressed_size);
            }
        } else {
            let meta = archive.metadata();
            for i in 0..meta.len() {
                let entry = meta.entry(i).rb(ruby)?;
                summary.add(entry.size(), entry.compressed_size());
            }
        }
        Ok((
            summary.records,
            summary.total,
            summary.largest,
            summary.ratio,
        ))
    }

    /// Inflates entry `index` to nowhere so the crate checks its CRC (and
    /// its declared size), with the GVL released when the source allows.
    pub fn verify_entry(
        ruby: &Ruby,
        rb_self: &Self,
        index: usize,
        password: Option<RString>,
    ) -> Result<(), Error> {
        let password = password.map(bytes_of);
        let mut archive = rb_self.archive(ruby)?.clone();
        maybe_without_gvl(rb_self.needs_gvl, || {
            let options = ZipReadOptions::new().password(password.as_deref());
            let mut entry = archive.by_index_with_options(index, options)?;
            io::copy(&mut Cancellable(&mut entry), &mut io::sink())?;
            Ok::<_, ZipError>(())
        })
        .map_err(|e| zip_read_error(ruby, e))
    }

    /// `verify_entry` for a record the crate cannot address by index (one
    /// of several under the same name): the entry is read from its local
    /// header with the central record's sizes and CRC, as `open_entry_at`
    /// reads it.
    pub fn verify_entry_at(
        ruby: &Ruby,
        rb_self: &Self,
        header_offset: u64,
        size: u64,
        compressed_size: u64,
        crc: u32,
        password: Option<RString>,
    ) -> Result<(), Error> {
        let password = password.map(bytes_of);
        let mut source = rb_self.source(ruby)?;
        let info = EntryInfo::at_offset(header_offset, size, compressed_size, crc);
        maybe_without_gvl(rb_self.needs_gvl, || {
            let mut entry = open_local_entry(&mut source, &info, password.as_deref(), size)?;
            io::copy(&mut Cancellable(&mut entry), &mut io::sink())?;
            Ok::<_, ZipError>(())
        })
        .map_err(|e| zip_read_error(ruby, e))
    }

    /// One Hash per entry, in central-directory order.
    ///
    /// The parsed central directory already holds nearly everything; the
    /// few fields read raw come from one sequential pass over the records,
    /// done without the GVL when the source allows it. An archive with
    /// several records under one name is listed from the raw records
    /// alone, since the crate's view keeps only the last of each name: a
    /// record the crate still addresses carries its index, the others nil.
    pub fn entries(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let out = ruby.ary_new();
        let keys = MetaKeys::new(ruby);
        Self::each_meta(ruby, rb_self, |m| out.push(m.to_hash(ruby, &keys)?))?;
        Ok(out)
    }

    /// `entries`, one Hash at a time to the block: a large archive's
    /// listing need never be in memory all at once.
    pub fn each_entry(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let block = ruby.block_proc()?;
        let keys = MetaKeys::new(ruby);
        Self::each_meta(ruby, rb_self, |m| {
            block
                .call::<_, Value>((m.to_hash(ruby, &keys)?,))
                .map(|_| ())
        })
    }

    /// `each_entry` with a row Array for each entry instead of a Hash (see
    /// `Meta::to_row`): opening an archive builds one `Entry` per record,
    /// and a Hash of fifteen keys each costs more than the Entry.
    pub fn each_entry_row(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        if !ruby.block_given() {
            return Err(Error::new(
                ruby.exception_local_jump_error(),
                "no block given",
            ));
        }
        // A plain yield: no Proc made of the block, no Array of arguments
        // built for every row.
        Self::each_meta(ruby, rb_self, |m| {
            ruby.yield_value::<_, Value>(m.to_row(ruby)?).map(|_| ())
        })
    }

    /// Hands the facts of each entry, in central directory order, to
    /// `emit`. The archive is not borrowed while `emit` runs, so it may
    /// call back in.
    fn each_meta(
        ruby: &Ruby,
        rb_self: &Self,
        mut emit: impl FnMut(Meta<'_>) -> Result<(), Error>,
    ) -> Result<(), Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        let duplicates = archive.has_duplicate_names();
        let dir_start = archive.central_directory_start();
        let archive_offset = archive.offset();
        let mut raw = archive.clone().into_inner();
        drop(archive);

        if duplicates {
            let records = maybe_without_gvl(rb_self.needs_gvl, || {
                walk_central_directory(&mut raw, dir_start)
            })
            .map_err(|e| header_error(ruby, e))?;
            let mut by_offset = HashMap::with_capacity(meta.len());
            for i in 0..meta.len() {
                let entry = meta.entry(i).rb(ruby)?;
                by_offset.insert(entry.central_header_start(), i);
            }
            for record in &records {
                let index = by_offset.get(&record.central_offset).copied();
                emit(Meta::from_record(index, record, archive_offset))?;
            }
            return Ok(());
        }

        let records = maybe_without_gvl(rb_self.needs_gvl, || {
            (0..meta.len())
                .map(|i| {
                    let entry = meta.entry(i)?;
                    Ok(raw_central_record(&mut raw, entry.central_header_start())?)
                })
                .collect::<ZipResult<Vec<_>>>()
        })
        .map_err(|e| zip_header_error(ruby, e))?;
        for (i, record) in records.iter().enumerate() {
            let entry = meta.entry(i).rb(ruby)?;
            emit(Meta::from_entry(i, &entry, record))?;
        }
        Ok(())
    }

    /// The Hash for a single entry.
    pub fn entry_meta(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RHash, Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        let mut raw = small_source(&archive);
        drop(archive);
        let entry = meta.entry(index).rb(ruby)?;
        let record = raw_central_record(&mut raw, entry.central_header_start())
            .map_err(|e| header_error(ruby, e))?;
        Meta::from_entry(index, &entry, &record).to_hash(ruby, &MetaKeys::new(ruby))
    }

    /// The Hashes for up to `count` entries from `index` on, in one go:
    /// `InputStream` walks an archive with these, a batch at a time,
    /// rather than opening the source once per entry.
    pub fn entry_metas(
        ruby: &Ruby,
        rb_self: &Self,
        index: usize,
        count: usize,
    ) -> Result<RArray, Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        let mut raw = small_source(&archive);
        drop(archive);
        let end = index.saturating_add(count).min(meta.len());
        let keys = MetaKeys::new(ruby);
        let out = ruby.ary_new_capa(end.saturating_sub(index));
        for i in index..end {
            let entry = meta.entry(i).rb(ruby)?;
            let record = raw_central_record(&mut raw, entry.central_header_start())
                .map_err(|e| header_error(ruby, e))?;
            out.push(Meta::from_entry(i, &entry, &record).to_hash(ruby, &keys)?)?;
        }
        Ok(out)
    }

    /// The raw extra field bytes of entry `index`'s local header. Some
    /// fields (Info-ZIP unix uid/gid, extended timestamp atime/ctime) only
    /// carry their data there; Ruby merges them lazily.
    pub fn local_extra(ruby: &Ruby, rb_self: &Self, index: usize) -> Result<RString, Error> {
        let archive = rb_self.archive(ruby)?;
        let header_start = archive.metadata().entry(index).rb(ruby)?.header_start();
        let mut raw = small_source(&archive);
        drop(archive);
        let extra = raw_local_extra(&mut raw, header_start).map_err(|e| header_error(ruby, e))?;
        Ok(ruby.str_from_slice(&extra))
    }

    /// Which of the entries at `indices` carry, in their local header or
    /// their central record, an extra field with one of the header IDs
    /// `ids`: in one pass and without the GVL, rather than one
    /// `local_extra` call per entry. A commit asks this of every entry it
    /// would copy raw (see `Entry::RAW_COPY_LOSES`).
    pub fn indices_with_extra_fields(
        ruby: &Ruby,
        rb_self: &Self,
        indices: Vec<usize>,
        ids: Vec<u16>,
    ) -> Result<Vec<usize>, Error> {
        let archive = rb_self.archive(ruby)?;
        let meta = archive.metadata();
        // One source for the central records (together, at the end) and
        // another for the local headers (spread through the file): taking
        // turns on one would throw its read buffer away at every seek.
        let mut central_source = archive.clone().into_inner();
        let mut local_source = small_source(&archive);
        drop(archive);
        maybe_without_gvl(rb_self.needs_gvl, || -> ZipResult<Vec<usize>> {
            let mut found = Vec::new();
            for index in indices {
                crate::gvl::check()?;
                let entry = meta.entry(index)?;
                let central =
                    raw_central_record(&mut central_source, entry.central_header_start())?;
                let hit = has_extra_field(&central.extra, &ids)
                    || has_extra_field(
                        &raw_local_extra(&mut local_source, entry.header_start())?,
                        &ids,
                    );
                if hit {
                    found.push(index);
                }
            }
            Ok(found)
        })
        .map_err(|e| zip_header_error(ruby, e))
    }

    /// `local_extra` for a record addressed by its local header offset.
    pub fn local_extra_at(
        ruby: &Ruby,
        rb_self: &Self,
        header_offset: u64,
    ) -> Result<RString, Error> {
        let mut raw = rb_self.small_source(ruby)?;
        let extra = raw_local_extra(&mut raw, header_offset).map_err(|e| header_error(ruby, e))?;
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
        let password = password.map(bytes_of);
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

    /// `open_entry` for a record the crate cannot address by index: the
    /// entry is read from its local header, with the sizes and CRC of its
    /// central record standing in for whatever the local header lacks.
    #[allow(clippy::too_many_arguments)]
    pub fn open_entry_at(
        ruby: &Ruby,
        rb_self: &Self,
        header_offset: u64,
        size: u64,
        compressed_size: u64,
        crc: u32,
        password: Option<RString>,
        enforce_size: bool,
    ) -> Result<EntryReader, Error> {
        let password = password.map(bytes_of);
        let archive = rb_self.archive(ruby)?.clone();
        let info = EntryInfo::at_offset(header_offset, size, compressed_size, crc);
        EntryReader::open_at(
            ruby,
            archive,
            info,
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
        let data_end = archive.central_directory_start();
        let mut entry = archive.by_index(index).rb(ruby)?;
        let size = entry.size();
        let method = compression_code(entry.compression());
        if !entry.encrypted() && size_believable(method, size, entry.compressed_size(), data_end) {
            return read_into_string(
                ruby,
                rb_self.needs_gvl,
                size as usize,
                &mut Cancellable(&mut entry),
            )
            .map_err(|e| read_error(ruby, e));
        }
        // A hint only: the declared size is untrusted and may be a lie.
        let mut buf = Vec::with_capacity(size.min(CAPACITY_HINT_MAX) as usize);
        maybe_without_gvl(rb_self.needs_gvl, || {
            Cancellable(&mut entry).read_to_end(&mut buf)
        })
        .map_err(|e| read_error(ruby, e))?;
        Ok(ruby.str_from_slice(&buf))
    }

    /// Extracts entries to `dest` in one call; see `extract::extract_entries`.
    pub fn extract_entries(
        ruby: &Ruby,
        rb_self: &Self,
        dest: String,
        specs: RArray,
        enforce_size: bool,
        threads: usize,
        on_exists: u8,
    ) -> Result<RArray, Error> {
        let archive = rb_self.archive(ruby)?.clone();
        let options = crate::extract::Options {
            enforce_size,
            threads,
            on_exists,
        };
        crate::extract::extract_entries(ruby, archive, rb_self.needs_gvl, dest, specs, options)
    }
}

/// The figures `Archive::limits` returns.
#[derive(Default)]
struct LimitSummary {
    records: usize,
    total: u64,
    largest: u64,
    ratio: f64,
}

impl LimitSummary {
    fn add(&mut self, size: u64, compressed_size: u64) {
        self.records += 1;
        self.total = self.total.saturating_add(size);
        self.largest = self.largest.max(size);
        if size > 0 {
            let ratio = if compressed_size == 0 {
                f64::INFINITY
            } else {
                size as f64 / compressed_size as f64
            };
            self.ratio = self.ratio.max(ratio);
        }
    }
}

/// A central directory record read straight from the bytes.
///
/// Two fields are read this way for every entry, where the crate's parsed
/// view is not what rubyzip exposes: the extra field exactly as stored
/// (the crate re-serializes the fields it parsed, which drops some, an
/// extended timestamp without the local-only parts for one), and the DOS
/// time and date as stored (the crate's `DateTime` rejects values a
/// calendar would roll over, February 30th, which rubyzip reads as the
/// next day). The rest only matters for a record the crate does not keep.
struct RawCentralRecord {
    /// Where the record starts, which is how it is matched to the crate's
    /// `central_header_start`.
    central_offset: u64,
    version_made_by: u16,
    flags: u16,
    method: u16,
    dos_time: u16,
    dos_date: u16,
    crc32: u32,
    compressed_size: u64,
    size: u64,
    external_attributes: u32,
    /// As stored: relative to the start of the archive proper, before any
    /// prepended data.
    header_offset: u64,
    name: Vec<u8>,
    extra: Vec<u8>,
    comment: Vec<u8>,
}

const CENTRAL_SIGNATURE: u32 = 0x0201_4b50;
const CENTRAL_HEADER_LEN: usize = 46;
const ZIP64_EXTRA_ID: u16 = 0x0001;

/// The record at `central_offset`.
fn raw_central_record(source: &mut Source, central_offset: u64) -> io::Result<RawCentralRecord> {
    source.seek_to(central_offset)?;
    read_central_record(source, central_offset)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "central directory signature not found",
        )
    })
}

/// Every record from `dir_start` to the end of the central directory.
fn walk_central_directory(
    source: &mut Source,
    dir_start: u64,
) -> io::Result<Vec<RawCentralRecord>> {
    source.seek_to(dir_start)?;
    let mut records = Vec::new();
    let mut offset = dir_start;
    while let Some(record) = read_central_record(source, offset)? {
        offset = record.next_offset();
        records.push(record);
    }
    Ok(records)
}

/// The record at the source's position, or `None` where the central
/// directory has ended (an end-of-central-directory signature instead).
fn read_central_record(
    source: &mut Source,
    central_offset: u64,
) -> io::Result<Option<RawCentralRecord>> {
    // The signature first: what follows the last record (the end of
    // central directory) is shorter than a record header.
    let mut header = [0u8; CENTRAL_HEADER_LEN];
    source.read_exact(&mut header[..4])?;
    if le_u32(&header[0..4]) != CENTRAL_SIGNATURE {
        return Ok(None);
    }
    source.read_exact(&mut header[4..])?;
    let name_len = le_u16(&header[28..30]) as usize;
    let extra_len = le_u16(&header[30..32]) as usize;
    let comment_len = le_u16(&header[32..34]) as usize;
    let mut name = vec![0u8; name_len];
    source.read_exact(&mut name)?;
    let mut extra = vec![0u8; extra_len];
    source.read_exact(&mut extra)?;
    let mut comment = vec![0u8; comment_len];
    source.read_exact(&mut comment)?;

    let mut record = RawCentralRecord {
        central_offset,
        version_made_by: le_u16(&header[4..6]),
        flags: le_u16(&header[8..10]),
        method: le_u16(&header[10..12]),
        dos_time: le_u16(&header[12..14]),
        dos_date: le_u16(&header[14..16]),
        crc32: le_u32(&header[16..20]),
        compressed_size: u64::from(le_u32(&header[20..24])),
        size: u64::from(le_u32(&header[24..28])),
        external_attributes: le_u32(&header[38..42]),
        header_offset: u64::from(le_u32(&header[42..46])),
        name,
        extra,
        comment,
    };
    record.apply_zip64();
    Ok(Some(record))
}

impl RawCentralRecord {
    fn next_offset(&self) -> u64 {
        self.central_offset
            + (CENTRAL_HEADER_LEN + self.name.len() + self.extra.len() + self.comment.len()) as u64
    }

    /// A zip64 extra field carries the 64-bit value of each size or
    /// offset the record stores as 0xFFFFFFFF, in header order.
    fn apply_zip64(&mut self) {
        let mut rest = self.extra.as_slice();
        while rest.len() >= 4 {
            let id = le_u16(&rest[0..2]);
            let len = le_u16(&rest[2..4]) as usize;
            rest = &rest[4..];
            if rest.len() < len {
                return;
            }
            let (mut data, tail) = rest.split_at(len);
            rest = tail;
            if id != ZIP64_EXTRA_ID {
                continue;
            }
            for field in [
                &mut self.size,
                &mut self.compressed_size,
                &mut self.header_offset,
            ] {
                if *field != u64::from(u32::MAX) {
                    continue;
                }
                let Some((value, more)) = data.split_first_chunk::<8>() else {
                    return;
                };
                *field = u64::from_le_bytes(*value);
                data = more;
            }
            return;
        }
    }
}

fn le_u16(bytes: &[u8]) -> u16 {
    u16::from_le_bytes([bytes[0], bytes[1]])
}

fn le_u32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// The extra field bytes of a local file header, exactly as stored.
fn raw_local_extra(source: &mut Source, header_offset: u64) -> io::Result<Vec<u8>> {
    let (name_len, extra_len) = local_header_lens(source, header_offset)?;
    source.seek_to(header_offset + LOCAL_HEADER_LEN + name_len)?;
    let mut extra = vec![0u8; extra_len as usize];
    source.read_exact(&mut extra)?;
    Ok(extra)
}

/// Whether the extra field block `extra` holds a field with one of the
/// header IDs `ids`.
fn has_extra_field(extra: &[u8], ids: &[u16]) -> bool {
    extra_fields(extra).any(|(id, _)| ids.contains(&id))
}

/// An error from reading the archive's headers through the crate.
fn zip_header_error(ruby: &Ruby, err: ZipError) -> Error {
    match err {
        ZipError::Io(e) => header_error(ruby, e),
        other => crate::errors::zip_error(ruby, other),
    }
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

/// A source with a small read buffer over `archive`'s bytes, for reading
/// a few header bytes.
fn small_source(archive: &ZipArchive<Source>) -> Source {
    archive.clone().into_inner().clone_small()
}

/// One entry's facts as Ruby gets them: a Hash (`to_hash`, keyed as
/// `MetaKeys`) or a row Array (`to_row`, in `ROW_FIELDS` order).
struct Meta<'a> {
    /// The crate's index, or `None` for a record it dropped (one of
    /// several under the same name).
    index: Option<usize>,
    name: &'a [u8],
    size: u64,
    compressed_size: u64,
    crc: u32,
    method: u16,
    flags: u16,
    external_attributes: u32,
    fstype: u8,
    version_made_by: u16,
    dos_date: u16,
    dos_time: u16,
    comment: &'a [u8],
    extra: &'a [u8],
    header_offset: u64,
}

impl<'a> Meta<'a> {
    /// From the crate's parsed record and the raw one beside it.
    fn from_entry(index: usize, entry: &'a ZipFileEntry<'_>, raw: &'a RawCentralRecord) -> Self {
        // "Version made by": high byte is the host system, low byte the
        // spec version; rubyzip keeps them as fstype / version.
        let (major, minor) = entry.version_made_by();
        Self {
            index: Some(index),
            name: entry.name_raw(),
            size: entry.size(),
            compressed_size: entry.compressed_size(),
            crc: entry.crc32(),
            method: compression_code(entry.compression()),
            flags: entry.flags().as_u16(),
            external_attributes: entry.external_attributes(),
            fstype: u8::from(entry.system()),
            version_made_by: u16::from(major) * 10 + u16::from(minor),
            dos_date: raw.dos_date,
            dos_time: raw.dos_time,
            // The stored bytes: the crate's `comment()` has already decoded
            // them (as CP437 without the UTF-8 flag), which is Ruby's
            // decision to make.
            comment: &raw.comment,
            extra: &raw.extra,
            header_offset: entry.header_start(),
        }
    }

    /// From the raw record alone, for an archive the crate's parsed view
    /// does not cover; `index` is `None` for a record it dropped.
    fn from_record(
        index: Option<usize>,
        record: &'a RawCentralRecord,
        archive_offset: u64,
    ) -> Self {
        Self {
            index,
            name: &record.name,
            size: record.size,
            compressed_size: record.compressed_size,
            crc: record.crc32,
            method: record.method,
            flags: record.flags,
            external_attributes: record.external_attributes,
            fstype: (record.version_made_by >> 8) as u8,
            version_made_by: record.version_made_by & 0xFF,
            dos_date: record.dos_date,
            dos_time: record.dos_time,
            comment: &record.comment,
            extra: &record.extra,
            header_offset: record.header_offset.saturating_add(archive_offset),
        }
    }

    fn to_hash(&self, ruby: &Ruby, keys: &MetaKeys) -> Result<RHash, Error> {
        let h = ruby.hash_new();
        h.aset(keys.index, self.index)?;
        h.aset(keys.name, ruby.str_from_slice(self.name))?;
        h.aset(keys.size, self.size)?;
        h.aset(keys.compressed_size, self.compressed_size)?;
        h.aset(keys.crc, self.crc)?;
        h.aset(keys.compression_method, self.method)?;
        h.aset(keys.flags, self.flags)?;
        h.aset(keys.external_attributes, self.external_attributes)?;
        h.aset(keys.fstype, self.fstype)?;
        h.aset(keys.version_made_by, self.version_made_by)?;
        h.aset(keys.dos_date, self.dos_date)?;
        h.aset(keys.dos_time, self.dos_time)?;
        h.aset(keys.comment, ruby.str_from_slice(self.comment))?;
        h.aset(keys.extra, ruby.str_from_slice(self.extra))?;
        h.aset(keys.header_offset, self.header_offset)?;
        Ok(h)
    }

    /// The number of fields in a row (`Entry::ROW_FIELDS` in Ruby).
    const ROW_LEN: usize = 15;

    /// The same fields as `to_hash`, in its order, as one Array; an empty
    /// comment or extra field is nil rather than a String of its own.
    /// `Entry::ROW_FIELDS` names the positions on the Ruby side.
    fn to_row(&self, ruby: &Ruby) -> Result<RArray, Error> {
        let bytes = |b: &[u8]| (!b.is_empty()).then(|| ruby.str_from_slice(b));
        let row = ruby.ary_new_capa(Self::ROW_LEN);
        row.push(self.index)?;
        row.push(ruby.str_from_slice(self.name))?;
        row.push(self.size)?;
        row.push(self.compressed_size)?;
        row.push(self.crc)?;
        row.push(self.method)?;
        row.push(self.flags)?;
        row.push(self.external_attributes)?;
        row.push(self.fstype)?;
        row.push(self.version_made_by)?;
        row.push(self.dos_date)?;
        row.push(self.dos_time)?;
        row.push(bytes(self.comment))?;
        row.push(bytes(self.extra))?;
        row.push(self.header_offset)?;
        Ok(row)
    }
}

/// The on-disk compression method code, as rubyzip exposes it.
///
/// `to_u16` is deprecated in favour of matching on constants, but it is the
/// only public way to recover the raw code, which is what we hand to Ruby.
#[allow(deprecated)]
pub(crate) fn compression_code(method: zip::CompressionMethod) -> u16 {
    method.to_u16()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(
        size: u64,
        compressed_size: u64,
        header_offset: u64,
        extra: Vec<u8>,
    ) -> RawCentralRecord {
        RawCentralRecord {
            central_offset: 0,
            version_made_by: 0,
            flags: 0,
            method: 0,
            dos_time: 0,
            dos_date: 0,
            crc32: 0,
            compressed_size,
            size,
            external_attributes: 0,
            header_offset,
            name: Vec::new(),
            extra,
            comment: Vec::new(),
        }
    }

    fn zip64(values: &[u64]) -> Vec<u8> {
        let mut extra = vec![0x01, 0x00, (values.len() * 8) as u8, 0x00];
        for v in values {
            extra.extend_from_slice(&v.to_le_bytes());
        }
        extra
    }

    #[test]
    fn zip64_fills_only_the_saturated_fields_in_order() {
        let max = u64::from(u32::MAX);
        let mut r = record(max, 7, max, zip64(&[1 << 33, 1 << 40]));
        r.apply_zip64();
        assert_eq!(
            (r.size, r.compressed_size, r.header_offset),
            (1 << 33, 7, 1 << 40)
        );
    }

    #[test]
    fn zip64_is_found_after_other_fields_and_tolerates_short_data() {
        let max = u64::from(u32::MAX);
        let mut extra = vec![0x55, 0x54, 0x01, 0x00, 0x03]; // an extended timestamp first
        extra.extend(zip64(&[42]));
        let mut r = record(max, max, 5, extra);
        r.apply_zip64();
        assert_eq!((r.size, r.compressed_size, r.header_offset), (42, max, 5));
    }
}
