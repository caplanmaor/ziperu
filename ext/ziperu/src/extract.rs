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

use std::collections::HashSet;
use std::fs::{self, FileTimes, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
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
            || (e.kind() == io::ErrorKind::InvalidData
                && e.to_string()
                    .contains("larger than its declared uncompressed size"));
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
    /// Without size enforcement, more bytes came out than declared.
    Oversize,
}

/// Extracts `specs` under `dest` (an absolute path) and returns one
/// `[index, kind, path]` triple per entry that was skipped as unsafe
/// (`kind` `:unsafe`) or came out larger than declared (`:oversize`, path
/// nil). An existing file raises `Ziperu::DestinationExistsError`, a header
/// that understates the size `Ziperu::EntrySizeError`; either leaves the
/// entries before it extracted, as the Ruby loop would.
///
/// With `threads` above one (and a source that can be read without the
/// GVL), the directories are made first, in order, and the files are
/// then shared out among that many threads, each reading through its own
/// handle on the archive.
/// How an extraction is to be done, as Ruby asks for it.
pub struct Options {
    pub enforce_size: bool,
    pub threads: usize,
    /// 0 raise, 1 overwrite, 2 skip (see `OnExists`).
    pub on_exists: u8,
}

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
    let mut entries = Vec::with_capacity(specs.len());
    let mut parsed = Vec::with_capacity(specs.len());
    for spec in specs.into_iter() {
        let spec = RArray::try_convert(spec)?;
        let entry: Value = spec.entry(0)?;
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
        // Kept only to name the entry in an exception; `specs` keeps it
        // alive, and nothing touches it without the GVL.
        entries.push(entry);
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
        Err((i, failure)) => return Err(raise(ruby, entries[i], failure)),
    };
    notices.sort_by_key(|(index, _)| *index);
    let unsafe_kind = ruby.to_symbol("unsafe");
    let oversize_kind = ruby.to_symbol("oversize");
    let out = ruby.ary_new_capa(notices.len());
    for (index, notice) in notices {
        let triple: (usize, Symbol, Option<String>) = match notice {
            Notice::Unsafe(path) => (index, unsafe_kind, Some(path)),
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
    let files_from = specs
        .iter()
        .position(|s| !s.directory)
        .unwrap_or(specs.len());
    let (dirs, files) = specs.split_at(files_from);
    let mut extractor = Extractor::new(archive, dest, enforce_size, on_exists);
    extractor.extract_each(dirs, 0)?;
    if threads <= 1 || files.len() <= 1 {
        extractor.extract_each(files, files_from)?;
        return Ok(extractor.notices);
    }

    // Each thread takes every `threads`th file, so a run of large ones
    // is shared out, and reads through its own handle on the archive.
    let threads = threads.min(files.len());
    let results: Vec<Outcome> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|t| {
                let mut worker =
                    Extractor::new(extractor.archive.clone(), dest, enforce_size, on_exists);
                worker.made.clone_from(&extractor.made);
                scope.spawn(move || {
                    for (i, spec) in files.iter().enumerate().skip(t).step_by(threads) {
                        worker.extract(spec).map_err(|f| (files_from + i, f))?;
                    }
                    Ok(worker.notices)
                })
            })
            .collect();
        workers
            .into_iter()
            .map(|w| w.join().expect("extraction thread panicked"))
            .collect()
    });
    let mut notices = extractor.notices;
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

struct Extractor<'a> {
    archive: ZipArchive<Source>,
    dest: &'a str,
    enforce_size: bool,
    on_exists: OnExists,
    /// Directories known to exist, so each parent is created once.
    made: HashSet<PathBuf>,
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
        Self {
            archive,
            dest,
            enforce_size,
            on_exists,
            made: HashSet::new(),
            buf: vec![0; CHUNK],
            notices: Vec::new(),
        }
    }

    /// Extracts `specs` in order; `offset` is the index of the first in
    /// the whole batch, for naming the one that failed.
    fn extract_each(&mut self, specs: &[Spec], offset: usize) -> Result<(), (usize, Failure)> {
        for (i, spec) in specs.iter().enumerate() {
            self.extract(spec).map_err(|f| (offset + i, f))?;
        }
        Ok(())
    }

    fn extract(&mut self, spec: &Spec) -> Result<(), Failure> {
        let Some(path) = safe_path(self.dest, &spec.name) else {
            let shown = resolve(self.dest, &spec.name);
            self.notices.push((spec.index, Notice::Unsafe(shown)));
            return Ok(());
        };
        let path = PathBuf::from(path);
        if spec.directory {
            self.create_directory(&path, spec)
        } else {
            self.create_file(&path, spec)
        }
    }

    fn create_directory(&mut self, path: &Path, spec: &Spec) -> Result<(), Failure> {
        if self.made.contains(path) {
            return Ok(());
        }
        match fs::metadata(path) {
            Ok(meta) if meta.is_dir() => {
                self.made.insert(path.to_path_buf());
                return Ok(());
            }
            Ok(_) => match self.on_exists {
                OnExists::Raise => return Err(Failure::Exists(path_string(path))),
                OnExists::Skip => return Ok(()),
                OnExists::Overwrite => fs::remove_file(path).map_err(at(path))?,
            },
            Err(_) => {}
        }
        fs::create_dir_all(path).map_err(at(path))?;
        self.made.insert(path.to_path_buf());
        if let Some(mtime) = spec.mtime {
            let times = FileTimes::new().set_accessed(mtime).set_modified(mtime);
            open_directory(path)
                .and_then(|dir| dir.set_times(times))
                .map_err(at(path))?;
        }
        if let Some(mode) = spec.mode {
            set_mode(path, mode).map_err(at(path))?;
        }
        Ok(())
    }

    fn create_file(&mut self, path: &Path, spec: &Spec) -> Result<(), Failure> {
        if let Some(parent) = path.parent() {
            if !self.made.contains(parent) {
                // A file where the parent directory should be: the entry
                // cannot go there. Skipped under `:skip`, an error
                // otherwise (a directory entry, when there is one, has
                // already had its say under `:overwrite`).
                if fs::metadata(parent).is_ok_and(|m| !m.is_dir()) {
                    return match self.on_exists {
                        OnExists::Skip => Ok(()),
                        _ => Err(Failure::Exists(path_string(parent))),
                    };
                }
                fs::create_dir_all(parent).map_err(at(parent))?;
                self.made.insert(parent.to_path_buf());
            }
        }
        let mut options = OpenOptions::new();
        options.write(true);
        match self.on_exists {
            OnExists::Raise => options.create_new(true),
            OnExists::Skip if path.exists() => return Ok(()),
            OnExists::Skip => options.create_new(true),
            // A directory in the way is not overwritten by a file.
            OnExists::Overwrite if path.is_dir() => return Err(Failure::Exists(path_string(path))),
            OnExists::Overwrite => options.create(true).truncate(true),
        };
        let mut file = match options.open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists || path.exists() => {
                return Err(Failure::Exists(path_string(path)));
            }
            Err(e) => return Err(at(path)(e)),
        };
        let written = self
            .copy_entry(spec.index, &mut file)
            .map_err(|f| match f {
                // Reading the entry is the entry's problem; writing is the path's.
                Failure::Io(e)
                    if e.kind() == io::ErrorKind::WriteZero
                        || e.kind() == io::ErrorKind::StorageFull =>
                {
                    at(path)(e)
                }
                other => other,
            })?;
        if let Some(mtime) = spec.mtime {
            file.set_times(FileTimes::new().set_accessed(mtime).set_modified(mtime))
                .map_err(at(path))?;
        }
        if let Some(mode) = spec.mode {
            set_file_mode(&file, mode).map_err(at(path))?;
        }
        drop(file);
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
                EntryInfo {
                    index: Some(index),
                    header_start: raw.header_start(),
                    size: raw.size(),
                    compressed_size: raw.compressed_size(),
                    crc32: raw.crc32(),
                }
            };
            let mut source = self.archive.clone().into_inner();
            let mut entry = open_local_entry(&mut source, &info, None, u64::MAX)?;
            copy(&mut entry)?;
        }
        Ok(written)
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
}
