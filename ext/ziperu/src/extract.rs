//! The native fast path behind `Ziperu::File#extract_all`.
//!
//! Ruby decides which entries qualify (no overwrite decision to make, no
//! encryption, no symlinks, no ownership to restore) and hands over one
//! spec per entry; this side creates each parent directory once, writes
//! every file through a single handle and stamps times and permissions on
//! that handle, all with the GVL released when the source allows it.
//!
//! The path check is the one `Entry#extract` makes, re-done here on the
//! same terms: the entry name is joined onto the absolute destination and
//! normalised lexically (as `File.absolute_path` does), and the result must
//! start with the destination plus a separator. Nothing is created for an
//! entry that fails it; Ruby prints the same warning it would have.
//!
//! Below the destination nothing is followed through a link already on
//! disk (a symlink, or on Windows a junction): every directory on the way
//! to an entry, and the entry's own path, must be a real directory or
//! file, or the entry is skipped with a warning. The destination itself is
//! taken as given, link or not. This is checked before each path is used,
//! so it does not hold against someone swapping a directory for a link
//! while the extraction runs.

use std::collections::HashSet;
use std::fs::{self, FileTimes, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use magnus::{
    prelude::*, value::Lazy, Error, ExceptionClass, RArray, RString, Ruby, Symbol, Value,
};
use zip::result::ZipError;
use zip::ZipArchive;

use crate::errors::{io_error, read_error, zip_error, DESTINATION_EXISTS_ERROR, ENTRY_SIZE_ERROR};
use crate::gvl::maybe_without_gvl;
use crate::reader::{open_local_entry, EntryInfo};
use crate::source::Source;

const CHUNK: usize = 64 * 1024;

/// One entry to extract, as Ruby describes it:
/// `[entry, index, name, mtime_sec, mtime_nsec, mode, directory?]`.
struct Spec {
    index: usize,
    name: String,
    /// `None` when times are not restored.
    mtime: Option<SystemTime>,
    /// Unix mode to apply, already masked by Ruby; `None` to leave alone.
    mode: Option<u32>,
    directory: bool,
}

/// Why an entry could not be extracted; turned into a Ruby exception once
/// the GVL is held again.
enum Failure {
    Exists(String),
    SizeLimit,
    Zip(ZipError),
    /// Reading the entry failed.
    Io(io::Error),
    /// Creating or writing `path` failed: raised as the matching `Errno`
    /// with the path in the message, as Ruby's own File calls do.
    IoAt(String, io::Error),
}

/// Attaches `path` to an IO error from a filesystem call on it.
fn at(path: &Path) -> impl Fn(io::Error) -> Failure + '_ {
    move |e| Failure::IoAt(path_string(path), e)
}

impl From<ZipError> for Failure {
    fn from(e: ZipError) -> Self {
        match e {
            ZipError::DecompressedSizeLimitExceeded { .. } => Failure::SizeLimit,
            other => Failure::Zip(other),
        }
    }
}

impl From<io::Error> for Failure {
    fn from(e: io::Error) -> Self {
        // The crate reports a header that understates the size either as
        // its own error behind an io::Error, or (crc32.rs) as plain
        // InvalidData with a message.
        let limit = e
            .get_ref()
            .and_then(|inner| inner.downcast_ref::<ZipError>())
            .is_some_and(|z| matches!(z, ZipError::DecompressedSizeLimitExceeded { .. }))
            || crate::errors::is_size_limit(&e);
        if limit {
            Failure::SizeLimit
        } else {
            Failure::Io(e)
        }
    }
}

/// Something Ruby should warn about afterwards.
enum Notice {
    /// The entry resolved outside the destination; nothing was written.
    Unsafe(String),
    /// A link on disk stands at this path on the way to the entry, or at
    /// the entry's own path; nothing was written.
    Link(String),
    /// Without size enforcement, more bytes came out than declared.
    Oversize,
}

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
    let outcome = extract_files(&mut extractor, dest, &files, threads);
    // A directory's times go on once nothing more is written into it:
    // creating a file inside would move its mtime again.
    let stamped = extractor.stamp_directories();
    let mut notices = outcome?;
    stamped?;
    notices.append(&mut extractor.notices);
    Ok(notices)
}

/// The files of `extract_all`: in order on this thread, or shared out
/// among `threads`.
fn extract_files(
    extractor: &mut Extractor<'_>,
    dest: &str,
    files: &[(usize, &Spec)],
    threads: usize,
) -> Outcome {
    let (enforce_size, on_exists) = (extractor.enforce_size, extractor.on_exists);
    if threads <= 1 || files.len() <= 1 {
        extractor.extract_each(files)?;
        return Ok(std::mem::take(&mut extractor.notices));
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
                let mut worker =
                    Extractor::new(extractor.archive.clone(), dest, enforce_size, on_exists);
                worker.made.clone_from(&extractor.made);
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
                        Ok(worker.notices)
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
    let mut notices = std::mem::take(&mut extractor.notices);
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

fn system_time(sec: i64, nsec: u32) -> Option<SystemTime> {
    let nanos = Duration::from_nanos(u64::from(nsec));
    let base = match u64::try_from(sec) {
        Ok(s) => SystemTime::UNIX_EPOCH.checked_add(Duration::from_secs(s)),
        Err(_) => SystemTime::UNIX_EPOCH.checked_sub(Duration::from_secs(sec.unsigned_abs())),
    };
    base?.checked_add(nanos)
}

fn raise(ruby: &Ruby, entry: Value, failure: Failure) -> Error {
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

/// What to do about a file or directory already at an entry's path.
#[derive(Clone, Copy)]
enum OnExists {
    Raise,
    Overwrite,
    Skip,
}

/// What stands at a path, looked at without following a link there.
enum OnDisk {
    Missing,
    Directory,
    /// A symlink, or on Windows a junction or other name-surrogate
    /// reparse point (what `FileType::is_symlink` counts).
    Link,
    /// A file, or anything else that is neither a directory nor a link.
    Other,
}

fn on_disk(path: &Path) -> io::Result<OnDisk> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => Ok(OnDisk::Link),
        Ok(meta) if meta.is_dir() => Ok(OnDisk::Directory),
        Ok(_) => Ok(OnDisk::Other),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(OnDisk::Missing),
        Err(e) => Err(e),
    }
}

/// Opens without following a link at the path itself, where the OS can:
/// a link put there after `on_disk` looked fails the open instead of
/// being written through.
#[cfg(unix)]
fn no_follow(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_NOFOLLOW);
}

#[cfg(not(unix))]
fn no_follow(_options: &mut OpenOptions) {}

struct Extractor<'a> {
    archive: ZipArchive<Source>,
    dest: &'a str,
    /// `dest` as `resolve` has it, with one trailing separator: what every
    /// entry path starts with.
    prefix: String,
    /// `dest` as `resolve` has it.
    root: String,
    enforce_size: bool,
    on_exists: OnExists,
    /// Directories known to exist, so each parent is created once.
    made: HashSet<PathBuf>,
    /// Directories made for an entry, with the times and mode to give
    /// them once their files are in.
    stamp: Vec<(usize, PathBuf, Option<SystemTime>, Option<u32>)>,
    /// The place in the batch of the spec being extracted.
    at: usize,
    buf: Vec<u8>,
    notices: Vec<(usize, Notice)>,
}

impl<'a> Extractor<'a> {
    fn new(
        archive: ZipArchive<Source>,
        dest: &'a str,
        enforce_size: bool,
        on_exists: OnExists,
    ) -> Self {
        let root = resolve(dest, "");
        let prefix = if root.ends_with('/') {
            root.clone()
        } else {
            format!("{root}/")
        };
        Self {
            archive,
            dest,
            prefix,
            root,
            enforce_size,
            on_exists,
            made: HashSet::new(),
            stamp: Vec::new(),
            at: 0,
            buf: vec![0; CHUNK],
            notices: Vec::new(),
        }
    }

    /// Extracts `specs`, each with its place in the whole batch, in
    /// order; a failure names the place.
    fn extract_each(&mut self, specs: &[(usize, &Spec)]) -> Result<(), (usize, Failure)> {
        for &(i, spec) in specs {
            self.at = i;
            self.extract(spec).map_err(|f| (i, f))?;
        }
        Ok(())
    }

    fn extract(&mut self, spec: &Spec) -> Result<(), Failure> {
        let Some(path) = safe_path(self.dest, &spec.name) else {
            let shown = resolve(self.dest, &spec.name);
            self.notices.push((spec.index, Notice::Unsafe(shown)));
            return Ok(());
        };
        if spec.directory {
            self.create_directory(&path, spec)
        } else {
            self.create_file(&path, spec)
        }
    }

    /// Makes sure every directory between the destination and `path` (not
    /// `path` itself) is a real directory, creating the missing ones.
    /// Returns false, having noted why if it is a link, when the entry is
    /// to be left out.
    fn prepare_parents(&mut self, path: &str, spec: &Spec) -> Result<bool, Failure> {
        let Some((parent, _)) = path.rsplit_once('/') else {
            return Ok(true);
        };
        if self.made.contains(Path::new(parent)) {
            return Ok(true);
        }
        // The destination is taken as given, a link or not, and made if
        // it is not there yet.
        if !self.made.contains(Path::new(&self.root)) {
            let root = PathBuf::from(&self.root);
            fs::create_dir_all(&root).map_err(at(&root))?;
            self.made.insert(root);
        }
        let Some(below) = format!("{parent}/")
            .strip_prefix(&self.prefix)
            .map(str::to_string)
        else {
            return Ok(true);
        };
        let mut walked = self.prefix.clone();
        for component in below.split('/').filter(|c| !c.is_empty()) {
            if !walked.ends_with('/') {
                walked.push('/');
            }
            walked.push_str(component);
            let step = PathBuf::from(&walked);
            if self.made.contains(&step) {
                continue;
            }
            match on_disk(&step).map_err(at(&step))? {
                OnDisk::Directory => {}
                OnDisk::Missing => match fs::create_dir(&step) {
                    Ok(()) => {}
                    // Another thread made it meanwhile.
                    Err(e)
                        if e.kind() == io::ErrorKind::AlreadyExists
                            && matches!(on_disk(&step), Ok(OnDisk::Directory)) => {}
                    Err(e) => return Err(at(&step)(e)),
                },
                OnDisk::Link => {
                    self.notices.push((spec.index, Notice::Link(walked)));
                    return Ok(false);
                }
                // A file where a directory should be: the entry cannot go
                // there. Skipped under `:skip`, an error otherwise (a
                // directory entry, when there is one, has already had its
                // say under `:overwrite`).
                OnDisk::Other => {
                    return match self.on_exists {
                        OnExists::Skip => Ok(false),
                        _ => Err(Failure::Exists(walked)),
                    };
                }
            }
            self.made.insert(step);
        }
        Ok(true)
    }

    fn create_directory(&mut self, path: &str, spec: &Spec) -> Result<(), Failure> {
        let dir = PathBuf::from(path);
        if self.made.contains(&dir) || !self.prepare_parents(path, spec)? {
            return Ok(());
        }
        match on_disk(&dir).map_err(at(&dir))? {
            OnDisk::Directory => {
                self.made.insert(dir);
                return Ok(());
            }
            OnDisk::Link => {
                self.notices
                    .push((spec.index, Notice::Link(path.to_string())));
                return Ok(());
            }
            OnDisk::Other => match self.on_exists {
                OnExists::Raise => return Err(Failure::Exists(path_string(&dir))),
                OnExists::Skip => return Ok(()),
                OnExists::Overwrite => fs::remove_file(&dir).map_err(at(&dir))?,
            },
            OnDisk::Missing => {}
        }
        fs::create_dir(&dir).map_err(at(&dir))?;
        let path = dir.as_path();
        self.made.insert(path.to_path_buf());
        if spec.mtime.is_some() || spec.mode.is_some() {
            self.stamp
                .push((self.at, path.to_path_buf(), spec.mtime, spec.mode));
        }
        Ok(())
    }

    /// Gives the directories made their times and modes, deepest first,
    /// so that stamping a parent comes after everything inside it.
    fn stamp_directories(&mut self) -> Result<(), (usize, Failure)> {
        let mut stamp = std::mem::take(&mut self.stamp);
        stamp.sort_by_key(|(_, path, _, _)| std::cmp::Reverse(path.components().count()));
        for (i, path, mtime, mode) in stamp {
            let path = path.as_path();
            if let Some(mtime) = mtime {
                let times = FileTimes::new().set_accessed(mtime).set_modified(mtime);
                open_directory(path)
                    .and_then(|dir| dir.set_times(times))
                    .map_err(|e| (i, at(path)(e)))?;
            }
            if let Some(mode) = mode {
                set_mode(path, mode).map_err(|e| (i, at(path)(e)))?;
            }
        }
        Ok(())
    }

    fn create_file(&mut self, name: &str, spec: &Spec) -> Result<(), Failure> {
        if !self.prepare_parents(name, spec)? {
            return Ok(());
        }
        let path = Path::new(name);
        let replace = match (on_disk(path).map_err(at(path))?, self.on_exists) {
            // Never written through, whatever the policy.
            (OnDisk::Link, _) => {
                self.notices
                    .push((spec.index, Notice::Link(name.to_string())));
                return Ok(());
            }
            (OnDisk::Missing, _) => false,
            (_, OnExists::Raise) => return Err(Failure::Exists(path_string(path))),
            (_, OnExists::Skip) => return Ok(()),
            // A directory in the way is not overwritten by a file.
            (OnDisk::Directory, OnExists::Overwrite) => {
                return Err(Failure::Exists(path_string(path)))
            }
            (OnDisk::Other, OnExists::Overwrite) => true,
        };
        // A file being replaced is written beside it and renamed over it
        // once complete, so a failure part-way leaves the original as it
        // was; a new one is written in place.
        let (target, mut file) = if replace {
            staging_file(path).map_err(at(path))?
        } else {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            no_follow(&mut options);
            match options.open(path) {
                Ok(f) => (path.to_path_buf(), f),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists || path.exists() => {
                    return Err(Failure::Exists(path_string(path)));
                }
                Err(e) => return Err(at(path)(e)),
            }
        };
        let outcome = self.copy_entry(spec.index, &mut file).and_then(|written| {
            if let Some(mtime) = spec.mtime {
                file.set_times(FileTimes::new().set_accessed(mtime).set_modified(mtime))
                    .map_err(at(path))?;
            }
            if let Some(mode) = spec.mode {
                set_file_mode(&file, mode).map_err(at(path))?;
            }
            Ok(written)
        });
        drop(file);
        let outcome = outcome.and_then(|written| {
            if replace {
                fs::rename(&target, path).map_err(at(path))?;
            }
            Ok(written)
        });
        let written = match outcome {
            Ok(n) => n,
            Err(failure) => {
                // Interrupted or failed part-way: a half-written file
                // would pass for the entry, and stand in the way of a
                // second run. What it replaces is still there.
                let _ = fs::remove_file(&target);
                return Err(match failure {
                    // Reading the entry is the entry's problem; writing is
                    // the path's.
                    Failure::Io(e)
                        if e.kind() == io::ErrorKind::WriteZero
                            || e.kind() == io::ErrorKind::StorageFull =>
                    {
                        at(path)(e)
                    }
                    other => other,
                });
            }
        };
        if !self.enforce_size {
            let declared = self.archive.metadata().entry(spec.index)?.size();
            if written > declared {
                self.notices.push((spec.index, Notice::Oversize));
            }
        }
        Ok(())
    }

    /// Decompresses entry `index` into `file`, returning the byte count.
    fn copy_entry(&mut self, index: usize, file: &mut fs::File) -> Result<u64, Failure> {
        let buf = &mut self.buf;
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
        if self.enforce_size {
            // An entry with no data at all is never read, as `EntryReader`
            // has it: the file is created and left empty. One declared
            // empty that has data goes through the crate's size check.
            let metadata = self.archive.metadata();
            let meta = metadata.entry(index)?;
            if meta.size() == 0 && meta.compressed_size() == 0 {
                return Ok(0);
            }
            drop(metadata);
            let mut entry = self.archive.by_index(index)?;
            copy(&mut entry)?;
        } else {
            // Past the declared size to the true end of the data, the way
            // `EntryReader` does without enforcement.
            let info = {
                let meta = self.archive.metadata();
                let raw = meta.entry(index)?;
                EntryInfo::from_entry(index, &raw)
            };
            let mut source = self.archive.clone().into_inner();
            let mut entry = open_local_entry(&mut source, &info, None, u64::MAX)?;
            copy(&mut entry)?;
        }
        Ok(written)
    }
}

/// A new file beside `path` to write its replacement into: a hidden name
/// in the same directory, so the rename that puts it in place stays on
/// one file system.
fn staging_file(path: &Path) -> io::Result<(PathBuf, fs::File)> {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let leaf = path
        .file_name()
        .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    loop {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let staged = path.with_file_name(format!(".{leaf}.ziperu-{}-{n}", std::process::id()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        no_follow(&mut options);
        match options.open(&staged) {
            Ok(file) => return Ok((staged, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// The absolute path `name` lands on under `dest`, as `File.absolute_path`
/// resolves `File.join(dest, name)`, or `None` when it is not strictly
/// inside `dest`. The one exception, as in Ruby, is a destination that is
/// the root directory itself.
fn safe_path(dest: &str, name: &str) -> Option<String> {
    let resolved = resolve(dest, name);
    if dest == "/" {
        return Some(resolved);
    }
    let dest = resolve(dest, "");
    let prefix = if dest.ends_with('/') {
        dest
    } else {
        format!("{dest}/")
    };
    resolved.starts_with(&prefix).then_some(resolved)
}

/// Lexical `File.absolute_path(File.join(dest, name))` for an absolute
/// `dest`: either separator, `.` and empty components dropped, `..`
/// popping the previous component but never the root (`/`, a drive or a
/// UNC share).
fn resolve(dest: &str, name: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    let mut components = dest.split(['/', '\\']).peekable();
    match components.peek().copied() {
        Some("") => {
            parts.push("");
            components.next();
            if components.peek() == Some(&"") && is_unc(dest) {
                // "//server/share/...": the share is the root.
                components.next();
                parts.push("");
                parts.extend(components.by_ref().take(2));
            }
        }
        Some(c) if is_drive(c) => {
            parts.push(c);
            components.next();
        }
        _ => {}
    }
    let root_len = parts.len();
    for c in components.chain(name.split(['/', '\\'])) {
        match c {
            "" | "." => {}
            ".." => {
                if parts.len() > root_len {
                    parts.pop();
                }
            }
            c => parts.push(c),
        }
    }
    let joined = parts.join("/");
    if parts.len() == root_len {
        // Only the root is left: "/" rather than "", "C:/" rather than "C:".
        if joined.is_empty() {
            "/".to_string()
        } else {
            format!("{joined}/")
        }
    } else {
        joined
    }
}

fn is_drive(c: &str) -> bool {
    let b = c.as_bytes();
    b.len() == 2 && b[0].is_ascii_alphabetic() && b[1] == b':'
}

/// "//server/..." (or with backslashes), as opposed to a bare "//".
fn is_unc(path: &str) -> bool {
    let b = path.as_bytes();
    b.len() > 2 && is_sep(b[0]) && is_sep(b[1]) && !is_sep(b[2])
}

fn is_sep(b: u8) -> bool {
    b == b'/' || b == b'\\'
}

/// A directory handle that `set_times` accepts: on Windows that means
/// backup semantics and write-attributes access, which a plain `open`
/// does not ask for.
#[cfg(windows)]
fn open_directory(path: &Path) -> io::Result<fs::File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x0100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    OpenOptions::new()
        .access_mode(FILE_WRITE_ATTRIBUTES)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

#[cfg(not(windows))]
fn open_directory(path: &Path) -> io::Result<fs::File> {
    fs::File::open(path)
}

#[cfg(unix)]
fn set_file_mode(file: &fs::File, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    file.set_permissions(fs::Permissions::from_mode(mode))
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

/// Ruby's `File.chmod` on Windows only knows the read-only attribute,
/// set when the owner-write bit is clear.
#[cfg(not(unix))]
fn set_file_mode(file: &fs::File, mode: u32) -> io::Result<()> {
    if mode & 0o200 == 0 {
        let mut perms = file.metadata()?.permissions();
        perms.set_readonly(true);
        file.set_permissions(perms)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    if mode & 0o200 == 0 {
        let mut perms = fs::metadata(path)?.permissions();
        perms.set_readonly(true);
        fs::set_permissions(path, perms)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_like_absolute_path() {
        assert_eq!(resolve("/p/dest", "a/b"), "/p/dest/a/b");
        assert_eq!(resolve("/p/dest", "/tmp/moo"), "/p/dest/tmp/moo");
        assert_eq!(resolve("/p/dest", "//tmp/moo"), "/p/dest/tmp/moo");
        assert_eq!(resolve("/p/dest", "../moo"), "/p/moo");
        assert_eq!(resolve("/p/dest", "tmp/../../moo"), "/p/moo");
        assert_eq!(resolve("/p/dest", "a/../b"), "/p/dest/b");
        assert_eq!(resolve("/p/dest", "../dest/y"), "/p/dest/y");
        assert_eq!(resolve("/p/dest", "dir/"), "/p/dest/dir");
        assert_eq!(resolve("/p/dest", "."), "/p/dest");
        assert_eq!(resolve("/p/dest", "../../../../x"), "/x");
        assert_eq!(resolve("/", "../x"), "/x");
        assert_eq!(resolve("/", ""), "/");
        assert_eq!(resolve("C:/dest", "a\\b"), "C:/dest/a/b");
        assert_eq!(resolve("C:/dest", "../../x"), "C:/x");
        assert_eq!(resolve("C:/", ".."), "C:/");
        assert_eq!(resolve("//srv/share/d", "../../../x"), "//srv/share/x");
        assert_eq!(resolve("//", "x"), "/x");
    }

    #[test]
    fn checks_prefix() {
        assert_eq!(safe_path("/p/dest", "a").as_deref(), Some("/p/dest/a"));
        assert_eq!(safe_path("/p/dest/", "a").as_deref(), Some("/p/dest/a"));
        assert!(safe_path("/p/dest", "../moo").is_none());
        assert!(safe_path("/p/dest", "tmp/../../moo").is_none());
        assert!(safe_path("/p/dest", ".").is_none());
        assert!(safe_path("/p/dest", "").is_none());
        assert!(safe_path("/p/dest", "../dest_evil/x").is_none());
        assert_eq!(safe_path("/", "../x").as_deref(), Some("/x"));
        assert_eq!(
            safe_path("C:/dest", "/tmp/moo").as_deref(),
            Some("C:/dest/tmp/moo")
        );
        assert_eq!(safe_path("C:/", "x").as_deref(), Some("C:/x"));
    }

    /// A name made of the pieces that matter to the check: separators of
    /// both kinds, `.`, `..`, empty components, drive letters and plain
    /// names.
    fn random_name(rng: &mut crate::test_rng::Rng) -> String {
        const PIECES: &[&str] = &[
            "a",
            "b",
            "dest",
            "dest_evil",
            "..",
            ".",
            "",
            "/",
            "\\",
            "C:",
            "x.txt",
        ];
        let len = rng.below(8);
        let mut name = String::new();
        for _ in 0..len {
            name.push_str(rng.pick(PIECES));
            name.push(*rng.pick(&['/', '\\', '/']));
        }
        name.push_str(rng.pick(PIECES));
        name
    }

    #[test]
    fn property_a_safe_path_is_strictly_inside_and_normal() {
        const DESTS: &[&str] = &["/p/dest", "/p/dest/", "C:/p/dest", "//srv/share/dest", "/"];
        let mut rng = crate::test_rng::Rng::new(1);
        for case in 0..crate::test_rng::CASES {
            let dest = *rng.pick(DESTS);
            let name = random_name(&mut rng);
            let resolved = resolve(dest, &name);
            // Normalised: nothing a second pass would change.
            assert_eq!(
                resolve(&resolved, ""),
                resolved,
                "case {case}: {dest:?} + {name:?}"
            );
            assert!(!resolved.contains('\\'), "case {case}: {resolved:?}");
            let Some(path) = safe_path(dest, &name) else {
                continue;
            };
            assert_eq!(path, resolved);
            if dest != "/" {
                let root = resolve(dest, "");
                let prefix = format!("{}/", root.trim_end_matches('/'));
                assert!(
                    path.starts_with(&prefix),
                    "case {case}: {path:?} not under {prefix:?}"
                );
                assert!(
                    path.len() > prefix.len(),
                    "case {case}: the destination itself"
                );
            }
            let below = &path[resolve(dest, "").len()..];
            assert!(
                below.split('/').all(|c| c != ".." && c != "."),
                "case {case}: {path:?}"
            );
        }
    }

    #[test]
    fn property_a_name_without_dot_dot_stays_inside() {
        let mut rng = crate::test_rng::Rng::new(2);
        for case in 0..crate::test_rng::CASES {
            let name = random_name(&mut rng);
            let climbs = name.split(['/', '\\']).any(|c| c == "..");
            let empty = name.split(['/', '\\']).all(|c| c.is_empty() || c == ".");
            if !climbs && !empty {
                assert!(
                    safe_path("/p/dest", &name).is_some(),
                    "case {case}: {name:?}"
                );
            }
        }
    }
}
