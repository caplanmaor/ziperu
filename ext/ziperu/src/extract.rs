//! The native fast path behind `Ziperu::File#extract_all`.
//!
//! Ruby decides which entries qualify (no overwrite decision to make, no
//! encryption, no symlinks, no ownership to restore) and hands over one
//! spec per entry; this side reads each entry out of the archive, with
//! the GVL released when the source allows it. Where an entry goes, and
//! what is refused on the way there, is `placer.rs`.

use std::fs;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use magnus::{
    prelude::*, value::Lazy, Error, ExceptionClass, RArray, RString, Ruby, Symbol, Value,
};
use zip::ZipArchive;

use crate::errors::{io_error, read_error, zip_error, DESTINATION_EXISTS_ERROR, ENTRY_SIZE_ERROR};
use crate::gvl::maybe_without_gvl;
use crate::placer::{Failure, Notice, OnExists, Placer, Spec};
use crate::reader::{open_local_entry, EntryInfo};
use crate::source::Source;

const CHUNK: usize = 64 * 1024;

/// How an extraction is to be done, as Ruby asks for it.
pub struct Options {
    pub enforce_size: bool,
    pub threads: usize,
    /// 0 raise, 1 overwrite, 2 skip (see `OnExists`).
    pub on_exists: u8,
}

/// Extracts `specs` under `dest` (an absolute path) and returns one
/// `[index, kind, path]` triple per entry that was skipped as unsafe
/// (`kind` `:unsafe`), skipped for a link in the way (`:link`, with the
/// link's path) or came out larger than declared (`:oversize`, path nil). An existing file raises `Ziperu::DestinationExistsError`, a header
/// that understates the size `Ziperu::EntrySizeError`; either leaves the
/// entries before it extracted, as the Ruby loop would.
///
/// With `threads` above one (and a source that can be read without the
/// GVL), the directories are made first, in order, and the files are
/// then shared out among that many threads, each reading through its own
/// handle on the archive.
pub fn extract_entries(
    ruby: &Ruby,
    archive: ZipArchive<Source>,
    needs_gvl: bool,
    dest: String,
    specs: RArray,
    options: Options,
) -> Result<RArray, Error> {
    let Options {
        enforce_size,
        threads,
        on_exists,
    } = options;
    let on_exists = match on_exists {
        0 => OnExists::Raise,
        1 => OnExists::Overwrite,
        2 => OnExists::Skip,
        other => {
            return Err(Error::new(
                ruby.exception_arg_error(),
                format!("on_exists code {other} is not 0, 1 or 2"),
            ))
        }
    };
    let mut parsed = Vec::with_capacity(specs.len());
    for spec in specs.into_iter() {
        let spec = RArray::try_convert(spec)?;
        let index: usize = spec.entry(1)?;
        let name: RString = spec.entry(2)?;
        let name = name
            .to_string()
            .map_err(|_| Error::new(ruby.exception_arg_error(), "entry name is not UTF-8"))?;
        let mtime = match spec.entry::<Option<i64>>(3)? {
            // A time the OS clock cannot represent is not restored.
            Some(sec) => system_time(sec, spec.entry(4)?),
            None => None,
        };
        let mode: Option<u32> = spec.entry(5)?;
        let directory: bool = spec.entry(6)?;
        parsed.push(Spec {
            index,
            name,
            mtime,
            mode,
            directory,
        });
    }

    let threads = if needs_gvl { 1 } else { threads.max(1) };
    let outcome = maybe_without_gvl(needs_gvl, || {
        extract_all(archive, &dest, enforce_size, on_exists, &parsed, threads)
    });

    let mut notices = match outcome {
        Ok(notices) => notices,
        Err((i, failure)) => {
            // The entry object, to name in the exception, is fetched now
            // the GVL is back: one held across the release could have
            // been moved by compaction meanwhile.
            let entry: Value = RArray::try_convert(specs.entry::<Value>(i as isize)?)?.entry(0)?;
            return Err(raise(ruby, entry, failure));
        }
    };
    notices.sort_by_key(|(index, _)| *index);
    let unsafe_kind = ruby.to_symbol("unsafe");
    let oversize_kind = ruby.to_symbol("oversize");
    let link_kind = ruby.to_symbol("link");
    let out = ruby.ary_new_capa(notices.len());
    for (index, notice) in notices {
        let triple: (usize, Symbol, Option<String>) = match notice {
            Notice::Unsafe(path) => (index, unsafe_kind, Some(path)),
            Notice::Link(path) => (index, link_kind, Some(path)),
            Notice::Oversize => (index, oversize_kind, None),
        };
        out.push(triple)?;
    }
    Ok(out)
}

/// What one extractor comes back with: its notices, or the first entry
/// (by index into the batch) that failed, and how.
type Outcome = Result<Vec<(usize, Notice)>, (usize, Failure)>;

/// Runs the specs: the directories first, in order, then the files, on
/// `threads` threads when there is more than one file. Fails with the
/// first failure in spec order.
fn extract_all(
    archive: ZipArchive<Source>,
    dest: &str,
    enforce_size: bool,
    on_exists: OnExists,
    specs: &[Spec],
    threads: usize,
) -> Outcome {
    // Every directory first, wherever it is listed, so that no file has
    // to wait for one and no worker thread meets one. Each spec keeps its
    // place in the batch, which is how a failure names its entry.
    let (dirs, files): (Vec<_>, Vec<_>) = specs.iter().enumerate().partition(|(_, s)| s.directory);
    let mut extractor = Extractor::new(archive, dest, enforce_size, on_exists);
    extractor.extract_each(&dirs)?;
    let outcome = extract_files(&mut extractor, &files, threads);
    // A directory's times go on once nothing more is written into it:
    // creating a file inside would move its mtime again.
    let stamped = extractor.placer.stamp_directories();
    let mut notices = outcome?;
    stamped?;
    notices.extend(extractor.placer.take_notices());
    Ok(notices)
}

/// The files of `extract_all`: in order on this thread, or shared out
/// among `threads`.
fn extract_files(extractor: &mut Extractor, files: &[(usize, &Spec)], threads: usize) -> Outcome {
    if threads <= 1 || files.len() <= 1 {
        extractor.extract_each(files)?;
        return Ok(extractor.placer.take_notices());
    }

    // Each thread takes every `threads`th file, so a run of large ones
    // is shared out, and reads through its own handle on the archive.
    // Once one fails the others stop before their next file, so that, as
    // with one thread, little is written after the entry that failed (a
    // file already in progress on another thread is finished). They also
    // share the call's cancellation flag.
    let threads = threads.min(files.len());
    let failed = AtomicBool::new(false);
    let token = crate::gvl::token();
    let results: Vec<Outcome> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|t| {
                let mut worker = extractor.worker();
                let failed = &failed;
                let token = token.clone();
                scope.spawn(move || {
                    crate::gvl::with_token(token, || {
                        for &(i, spec) in files.iter().skip(t).step_by(threads) {
                            if failed.load(Ordering::Acquire) {
                                break;
                            }
                            if let Err(f) = worker.extract(spec) {
                                failed.store(true, Ordering::Release);
                                return Err((i, f));
                            }
                        }
                        Ok(worker.placer.take_notices())
                    })
                })
            })
            .collect();
        workers
            .into_iter()
            .map(|w| {
                w.join()
                    .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
            })
            .collect()
    });
    let mut notices = extractor.placer.take_notices();
    let mut first_failure: Option<(usize, Failure)> = None;
    for result in results {
        match result {
            Ok(found) => notices.extend(found),
            Err((i, f)) if first_failure.as_ref().is_none_or(|(j, _)| i < *j) => {
                first_failure = Some((i, f));
            }
            Err(_) => {}
        }
    }
    match first_failure {
        Some(failure) => Err(failure),
        None => Ok(notices),
    }
}

pub(crate) fn system_time(sec: i64, nsec: u32) -> Option<SystemTime> {
    let nanos = Duration::from_nanos(u64::from(nsec));
    let base = match u64::try_from(sec) {
        Ok(s) => SystemTime::UNIX_EPOCH.checked_add(Duration::from_secs(s)),
        Err(_) => SystemTime::UNIX_EPOCH.checked_sub(Duration::from_secs(sec.unsigned_abs())),
    };
    base?.checked_add(nanos)
}

pub(crate) fn raise(ruby: &Ruby, entry: Value, failure: Failure) -> Error {
    match failure {
        Failure::Exists(path) => exception(ruby, &DESTINATION_EXISTS_ERROR, (path,)),
        Failure::SizeLimit => exception(ruby, &ENTRY_SIZE_ERROR, (entry,)),
        Failure::Zip(e) => zip_error(ruby, e),
        Failure::Io(e) => read_error(ruby, e),
        // A name the file system cannot take at all (a NUL in it) is
        // what Ruby's own File calls raise ArgumentError for.
        Failure::IoAt(path, e) if e.kind() == io::ErrorKind::InvalidInput => Error::new(
            ruby.exception_arg_error(),
            format!("{e} - {}", path.replace('\0', "\\0")),
        ),
        Failure::IoAt(path, e) => io_error(ruby, io::Error::new(e.kind(), format!("{e} - {path}"))),
    }
}

fn exception<A: magnus::ArgList>(ruby: &Ruby, class: &Lazy<ExceptionClass>, args: A) -> Error {
    match ruby.get_inner(class).new_instance(args) {
        Ok(exc) => Error::from(exc),
        Err(e) => e,
    }
}

/// Reads entries out of one handle on the archive and has a `Placer` put
/// them on disk.
struct Extractor {
    archive: ZipArchive<Source>,
    placer: Placer,
    enforce_size: bool,
    buf: Vec<u8>,
}

impl Extractor {
    fn new(
        archive: ZipArchive<Source>,
        dest: &str,
        enforce_size: bool,
        on_exists: OnExists,
    ) -> Self {
        Self {
            archive,
            placer: Placer::new(dest, on_exists),
            enforce_size,
            buf: vec![0; CHUNK],
        }
    }

    /// Another extractor for the same destination, for a worker thread,
    /// reading through its own handle on the archive.
    fn worker(&self) -> Self {
        Self {
            archive: self.archive.clone(),
            placer: self.placer.fork(),
            enforce_size: self.enforce_size,
            buf: vec![0; CHUNK],
        }
    }

    /// Extracts `specs`, each with its place in the whole batch, in
    /// order; a failure names the place.
    fn extract_each(&mut self, specs: &[(usize, &Spec)]) -> Result<(), (usize, Failure)> {
        for &(i, spec) in specs {
            self.placer.set_at(i);
            self.extract(spec).map_err(|f| (i, f))?;
        }
        Ok(())
    }

    fn extract(&mut self, spec: &Spec) -> Result<(), Failure> {
        let Self {
            archive,
            placer,
            enforce_size,
            buf,
        } = self;
        let enforce_size = *enforce_size;
        let written = placer.place(spec, |file| {
            copy_entry(archive, buf, enforce_size, spec.index, file)
        })?;
        if let (Some(written), false) = (written, enforce_size) {
            let declared = archive.metadata().entry(spec.index)?.size();
            if written > declared {
                placer.note(spec.index, Notice::Oversize);
            }
        }
        Ok(())
    }
}

/// Decompresses entry `index` into `file`, returning the byte count.
fn copy_entry(
    archive: &mut ZipArchive<Source>,
    buf: &mut [u8],
    enforce_size: bool,
    index: usize,
    file: &mut fs::File,
) -> Result<u64, Failure> {
    let mut written = 0u64;
    let mut copy = |reader: &mut dyn Read| -> Result<(), Failure> {
        loop {
            crate::gvl::check()?;
            let n = reader.read(buf)?;
            if n == 0 {
                return Ok(());
            }
            file.write_all(&buf[..n])?;
            written += n as u64;
        }
    };
    if enforce_size {
        // An entry with no data at all is never read, as `EntryReader`
        // has it: the file is created and left empty. One declared
        // empty that has data goes through the crate's size check.
        let metadata = archive.metadata();
        let meta = metadata.entry(index)?;
        if meta.size() == 0 && meta.compressed_size() == 0 {
            return Ok(0);
        }
        drop(metadata);
        let mut entry = archive.by_index(index)?;
        copy(&mut entry)?;
    } else {
        // Past the declared size to the true end of the data, the way
        // `EntryReader` does without enforcement.
        let info = {
            let meta = archive.metadata();
            let raw = meta.entry(index)?;
            EntryInfo::from_entry(index, &raw)
        };
        let mut source = archive.clone().into_inner();
        let mut entry = open_local_entry(&mut source, &info, None, u64::MAX)?;
        copy(&mut entry)?;
    }
    Ok(written)
}
