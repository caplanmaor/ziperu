//! Where an archive's bytes come from.
//!
//! Chosen once at open time. `File` is the fast path (pure Rust I/O, can run
//! without the GVL later); `Memory` backs `open_buffer`-style use. A `Ruby`
//! variant wrapping an arbitrary IO object comes later.

use std::fs;
use std::io::{self, BufReader, Cursor, Read, Seek, SeekFrom};

pub enum Source {
    File(BufReader<fs::File>),
    Memory(Cursor<Vec<u8>>),
}

impl Read for Source {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Source::File(f) => f.read(buf),
            Source::Memory(c) => c.read(buf),
        }
    }
}

impl Seek for Source {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match self {
            Source::File(f) => f.seek(pos),
            Source::Memory(c) => c.seek(pos),
        }
    }
}
