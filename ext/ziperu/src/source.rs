//! Where an archive's bytes come from.
//!
//! Chosen once at open time. Every variant is cheaply `Clone`: an entry
//! reader takes its own clone of the `ZipArchive` (the parsed central
//! directory is behind an `Arc`, so only the reader is duplicated) and
//! therefore needs an independent cursor over the same bytes.
//!
//! `File` is the fast path (pure Rust I/O, can run without the GVL later);
//! `Memory` backs `open_buffer`-style use. A `Ruby` variant wrapping an
//! arbitrary IO object comes later.

use std::fs;
use std::io::{self, BufReader, Cursor, Read, Seek, SeekFrom};
use std::sync::Arc;

const BUF_SIZE: usize = 64 * 1024;

pub enum Source {
    File(BufReader<SharedFile>),
    Memory(Cursor<Arc<[u8]>>),
}

impl Source {
    pub fn file(file: fs::File) -> Self {
        Source::File(BufReader::with_capacity(BUF_SIZE, SharedFile::new(file)))
    }

    pub fn memory(bytes: Vec<u8>) -> Self {
        Source::Memory(Cursor::new(Arc::from(bytes)))
    }
}

impl Clone for Source {
    fn clone(&self) -> Self {
        match self {
            // Position the clone where the logical stream is, not where the
            // buffered reader has read ahead to.
            Source::File(r) => {
                let inner = r.get_ref();
                let pos = inner.pos - r.buffer().len() as u64;
                Source::File(BufReader::with_capacity(
                    BUF_SIZE,
                    SharedFile {
                        file: Arc::clone(&inner.file),
                        pos,
                    },
                ))
            }
            Source::Memory(c) => Source::Memory(c.clone()),
        }
    }
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

/// One OS file handle shared between cursors, each with its own position.
/// Reads are positional (`pread`/`ReadFile` with an offset), so clones never
/// disturb each other and no file is ever reopened by path.
#[derive(Clone)]
pub struct SharedFile {
    file: Arc<fs::File>,
    pos: u64,
}

impl SharedFile {
    fn new(file: fs::File) -> Self {
        Self {
            file: Arc::new(file),
            pos: 0,
        }
    }
}

impl Read for SharedFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = read_at(&self.file, buf, self.pos)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for SharedFile {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let base = match pos {
            SeekFrom::Start(p) => return Ok(set_pos(&mut self.pos, p)),
            SeekFrom::Current(_) => self.pos as i64,
            SeekFrom::End(_) => self.file.metadata()?.len() as i64,
        };
        let offset = match pos {
            SeekFrom::Current(o) | SeekFrom::End(o) => o,
            SeekFrom::Start(_) => unreachable!(),
        };
        let target = base
            .checked_add(offset)
            .filter(|t| *t >= 0)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid seek to a negative or overflowing position",
                )
            })?;
        Ok(set_pos(&mut self.pos, target as u64))
    }
}

fn set_pos(pos: &mut u64, target: u64) -> u64 {
    *pos = target;
    target
}

#[cfg(unix)]
fn read_at(file: &fs::File, buf: &mut [u8], pos: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    file.read_at(buf, pos)
}

#[cfg(windows)]
fn read_at(file: &fs::File, buf: &mut [u8], pos: u64) -> io::Result<usize> {
    use std::os::windows::fs::FileExt;
    file.seek_read(buf, pos)
}
