//! Per-entry facts for an archive written to a stream.
//!
//! A stream (a pipe, a socket, a response body) cannot be read back, so
//! what `Writer::finish` reports about each entry has to be gathered as
//! the entries go by. The crate finishes an entry only when the next one
//! starts (or at the end): it flushes the compressor and writes the data
//! descriptor. `Counting` sits under the crate's stream writer, counts
//! the bytes and catches those descriptors; `StreamStats` turns them into
//! each entry's offset, sizes and CRC.

use std::io::{self, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::sink::Sink;
use crate::zipcrypto::DATA_DESCRIPTOR_SIGNATURE;

/// What `finish` reports about one written entry.
#[derive(Clone, Copy, Default)]
pub(crate) struct EntryStat {
    pub header_start: u64,
    pub size: u64,
    pub csize: u64,
    pub crc: u32,
}

impl EntryStat {
    /// The `[header_offset, size, compressed_size, crc]` Ruby reads.
    pub(crate) fn to_vec(self) -> Vec<u64> {
        vec![
            self.header_start,
            self.size,
            self.csize,
            u64::from(self.crc),
        ]
    }
}

pub(crate) type EntryStats = Vec<EntryStat>;

/// The sink of a stream writer: counts the bytes that reach it and notes
/// the data descriptors among them.
pub struct Counting {
    pub(crate) sink: Sink,
    written: Arc<AtomicU64>,
    sniffer: Sniffer,
    /// The data descriptors written since the last `StreamStats::mark`.
    descriptors: Arc<Mutex<Vec<Descriptor>>>,
}

impl Counting {
    /// The sink, and the stats that will read from it.
    pub(crate) fn new(sink: Sink) -> (Self, StreamStats) {
        let written = Arc::new(AtomicU64::new(0));
        let descriptors = Arc::new(Mutex::new(Vec::new()));
        let counting = Self {
            sink,
            written: Arc::clone(&written),
            sniffer: Sniffer::default(),
            descriptors: Arc::clone(&descriptors),
        };
        let stats = StreamStats {
            written,
            descriptors,
            entries: Vec::new(),
            current: None,
        };
        (counting, stats)
    }
}

impl Write for Counting {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.sink.write(buf)?;
        let at = self.written.fetch_add(n as u64, Ordering::Relaxed);
        if n == buf.len() {
            if let Some(d) = self.sniffer.feed(at, buf) {
                self.descriptors.lock().unwrap().push(d);
            }
        } else {
            self.sniffer.reset();
        }
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.sink.flush()
    }
}

/// Catches data descriptors as the crate writes them: one write per field.
/// Entry data comes in larger chunks; one that happens to look like a
/// descriptor is told apart by its sizes, which `StreamStats::seal` checks
/// against what was written.
#[derive(Default)]
struct Sniffer {
    start: u64,
    buf: Vec<u8>,
}

/// The fields of a descriptor, in order, as the crate writes them: the
/// signature, the CRC, then the two sizes, 4 bytes each or 8 for a zip64
/// descriptor.
const SIGNATURE: usize = 4;
const CRC: usize = 4;

impl Sniffer {
    fn reset(&mut self) {
        self.buf.clear();
    }

    fn feed(&mut self, at: u64, buf: &[u8]) -> Option<Descriptor> {
        let have = self.buf.len();
        let fits = match have {
            0 => {
                if buf == DATA_DESCRIPTOR_SIGNATURE.to_le_bytes() {
                    self.start = at;
                    self.buf.extend_from_slice(buf);
                }
                return None;
            }
            // After the signature: the CRC.
            SIGNATURE => buf.len() == CRC,
            // After the CRC: the compressed size, 4 or 8 bytes.
            8 => buf.len() == 4 || buf.len() == 8,
            // After a 4-byte compressed size: a 4-byte uncompressed size.
            12 => buf.len() == 4,
            // After an 8-byte compressed size: an 8-byte uncompressed size.
            16 => buf.len() == 8,
            _ => false,
        };
        if !fits {
            self.reset();
            return self.feed(at, buf);
        }
        self.buf.extend_from_slice(buf);
        let whole = match self.buf.len() {
            16 => buf.len() == 4,
            24 => true,
            _ => false,
        };
        if !whole {
            return None;
        }
        let found = Descriptor::parse(self.start, &self.buf);
        self.reset();
        found
    }
}

/// A data descriptor as written: where it ends, and what it says.
#[derive(Clone, Copy)]
struct Descriptor {
    end: u64,
    crc: u32,
    csize: u64,
    size: u64,
}

impl Descriptor {
    /// Parses `buf` if it is a whole data descriptor, starting at `at`.
    fn parse(at: u64, buf: &[u8]) -> Option<Self> {
        if buf.len() != 16 && buf.len() != 24 || buf[..4] != DATA_DESCRIPTOR_SIGNATURE.to_le_bytes()
        {
            return None;
        }
        let u32_at = |i: usize| u32::from_le_bytes(buf[i..i + 4].try_into().unwrap());
        let u64_at = |i: usize| u64::from_le_bytes(buf[i..i + 8].try_into().unwrap());
        let (csize, size) = if buf.len() == 16 {
            (u64::from(u32_at(8)), u64::from(u32_at(12)))
        } else {
            (u64_at(8), u64_at(16))
        };
        Some(Self {
            end: at + buf.len() as u64,
            crc: u32_at(4),
            csize,
            size,
        })
    }
}

/// How an entry's facts are gathered: hashed as its data passes through
/// `feed` (and finished by a data descriptor), or known up front, as for a
/// directory, a symlink or a raw copy, whose header holds the sizes.
pub(crate) enum Begun {
    Hashed,
    Known { size: u64, csize: u64, crc: u32 },
}

pub(crate) struct StreamStats {
    written: Arc<AtomicU64>,
    descriptors: Arc<Mutex<Vec<Descriptor>>>,
    pub(crate) entries: EntryStats,
    current: Option<Current>,
}

struct Current {
    index: usize,
    header_start: u64,
    size: u64,
    csize: u64,
    crc: u32,
    /// Present while the data passes through `feed`; the entry then ends
    /// with a data descriptor.
    hasher: Option<crc32fast::Hasher>,
}

impl StreamStats {
    /// Bytes that have reached the sink so far.
    pub(crate) fn position(&self) -> u64 {
        self.written.load(Ordering::Relaxed)
    }

    /// Returns the position before an action of the crate's, and starts
    /// watching for the data descriptor it may write.
    pub(crate) fn mark(&mut self) -> u64 {
        self.descriptors.lock().unwrap().clear();
        self.position()
    }

    /// Closes the entry in progress, if any, once the crate's action is
    /// done. Returns where the next entry's header begins.
    pub(crate) fn seal(&mut self, mark: u64) -> u64 {
        let Some(c) = self.current.take() else {
            return mark;
        };
        let (end, stat) = match c.hasher {
            None => (
                mark,
                EntryStat {
                    header_start: c.header_start,
                    size: c.size,
                    csize: c.csize,
                    crc: c.crc,
                },
            ),
            Some(hasher) => {
                let found = self
                    .descriptors
                    .lock()
                    .unwrap()
                    .iter()
                    .copied()
                    .find(|d| d.size == c.size);
                match found {
                    // The descriptor is what the archive says; for AES
                    // entries that is a CRC of zero, as in the headers.
                    Some(d) => (
                        d.end,
                        EntryStat {
                            header_start: c.header_start,
                            size: d.size,
                            csize: d.csize,
                            crc: d.crc,
                        },
                    ),
                    None => {
                        debug_assert!(false, "no data descriptor followed a streamed entry");
                        (
                            mark,
                            EntryStat {
                                header_start: c.header_start,
                                size: c.size,
                                csize: 0,
                                crc: hasher.finalize(),
                            },
                        )
                    }
                }
            }
        };
        if self.entries.len() <= c.index {
            self.entries.resize(c.index + 1, EntryStat::default());
        }
        self.entries[c.index] = stat;
        end
    }

    /// Starts watching entry `index`, whose header begins at `header_start`.
    pub(crate) fn begin(&mut self, index: usize, header_start: u64, begun: Begun) {
        self.current = Some(match begun {
            Begun::Hashed => Current {
                index,
                header_start,
                size: 0,
                csize: 0,
                crc: 0,
                hasher: Some(crc32fast::Hasher::new()),
            },
            Begun::Known { size, csize, crc } => Current {
                index,
                header_start,
                size,
                csize,
                crc,
                hasher: None,
            },
        });
    }

    pub(crate) fn feed(&mut self, bytes: &[u8]) {
        if let Some(c) = &mut self.current {
            c.size += bytes.len() as u64;
            if let Some(h) = &mut c.hasher {
                h.update(bytes);
            }
        }
    }
}
