//! Where extracted entries go on disk, whatever they are read from.
//!
//! A `Placer` is given one spec per entry and, for a file, something that
//! writes its data into the handle it opens. It creates each parent
//! directory once, writes every file through a single handle and stamps
//! times and permissions on that handle.
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
//! taken as given, link or not. This is checked before each path is used;
//! on Linux, `place.rs` also opens each file's directory beneath the
//! destination so that the kernel refuses a link swapped in meanwhile.

use std::collections::HashSet;
use std::fs::{self, FileTimes};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use zip::result::ZipError;

use crate::place::{is_link_error, Beneath};

/// One entry to extract, as Ruby describes it:
/// `[entry, index, name, mtime_sec, mtime_nsec, mode, directory?]`.
pub(crate) struct Spec {
    /// What the entry is known by in notices.
    pub(crate) index: usize,
    pub(crate) name: String,
    /// `None` when times are not restored.
    pub(crate) mtime: Option<SystemTime>,
    /// Unix mode to apply, already masked by Ruby; `None` to leave alone.
    pub(crate) mode: Option<u32>,
    pub(crate) directory: bool,
}

/// Why an entry could not be extracted; turned into a Ruby exception once
/// the GVL is held again.
pub(crate) enum Failure {
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
pub(crate) enum Notice {
    /// The entry resolved outside the destination; nothing was written.
    Unsafe(String),
    /// A link on disk stands at this path on the way to the entry, or at
    /// the entry's own path; nothing was written.
    Link(String),
    /// Without size enforcement, more bytes came out than declared.
    Oversize,
}

/// What to do about a file or directory already at an entry's path.
#[derive(Clone, Copy)]
pub(crate) enum OnExists {
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

/// Puts entries under one destination. The data of a file comes from the
/// caller, so the same rules hold whatever the archive is.
pub(crate) struct Placer {
    dest: String,
    /// `dest` as `resolve` has it, with one trailing separator: what every
    /// entry path starts with.
    prefix: String,
    /// `dest` as `resolve` has it.
    root: String,
    on_exists: OnExists,
    /// Directories known to exist, so each parent is created once.
    made: HashSet<PathBuf>,
    /// Directories made for an entry, with the times and mode to give
    /// them once their files are in.
    stamp: Vec<(usize, PathBuf, Option<SystemTime>, Option<u32>)>,
    /// The destination opened for kernel-checked lookups beneath it;
    /// made once the destination exists.
    beneath: Option<Beneath>,
    /// The place in the batch of the spec being placed.
    at: usize,
    notices: Vec<(usize, Notice)>,
    /// The file about to be replaced is one this run wrote (see
    /// `set_own`).
    own: bool,
}

impl Placer {
    pub(crate) fn new(dest: &str, on_exists: OnExists) -> Self {
        let root = resolve(dest, "");
        let prefix = if root.ends_with('/') {
            root.clone()
        } else {
            format!("{root}/")
        };
        Self {
            dest: dest.to_string(),
            prefix,
            root,
            on_exists,
            made: HashSet::new(),
            stamp: Vec::new(),
            beneath: None,
            at: 0,
            notices: Vec::new(),
            own: false,
        }
    }

    /// Another placer for the same destination, for a worker thread: it
    /// starts out knowing the directories this one has made.
    pub(crate) fn fork(&self) -> Self {
        let mut other = Self::new(&self.dest, self.on_exists);
        other.made.clone_from(&self.made);
        other
    }

    /// Says where in the batch the next spec stands, which is how a
    /// failure to stamp a directory names its entry.
    pub(crate) fn set_at(&mut self, at: usize) {
        self.at = at;
    }

    /// Changes what is done about a path already taken, for the entries
    /// placed from here on.
    pub(crate) fn set_on_exists(&mut self, on_exists: OnExists) {
        self.on_exists = on_exists;
    }

    /// Says whether a file the next entry replaces is one this run wrote
    /// itself. It then gives way even if the archive marked it read-only,
    /// which on Windows would otherwise refuse the replacement.
    pub(crate) fn set_own(&mut self, own: bool) {
        self.own = own;
    }

    pub(crate) fn on_exists(&self) -> OnExists {
        self.on_exists
    }

    pub(crate) fn note(&mut self, index: usize, notice: Notice) {
        self.notices.push((index, notice));
    }

    /// The notices so far, which are then forgotten.
    pub(crate) fn take_notices(&mut self) -> Vec<(usize, Notice)> {
        std::mem::take(&mut self.notices)
    }

    /// Places the entry `spec` describes. A directory is created; for a
    /// file, `write` is called with the open handle and returns how many
    /// bytes it wrote, which is what comes back. `None` means nothing was
    /// written: a directory, or an entry left out (with a notice when a
    /// warning is due).
    pub(crate) fn place(
        &mut self,
        spec: &Spec,
        write: impl FnOnce(&mut fs::File) -> Result<u64, Failure>,
    ) -> Result<Option<u64>, Failure> {
        let Some(path) = safe_path(&self.dest, &spec.name) else {
            let shown = resolve(&self.dest, &spec.name);
            self.notices.push((spec.index, Notice::Unsafe(shown)));
            return Ok(None);
        };
        if spec.directory {
            self.create_directory(&path, spec)?;
            Ok(None)
        } else {
            self.create_file(&path, spec, write)
        }
    }

    /// `dir` relative to the destination, `/`-separated; empty for the
    /// destination itself.
    fn below<'p>(&self, dir: &'p str) -> &'p str {
        if dir == self.root || format!("{dir}/") == self.prefix {
            return "";
        }
        dir.strip_prefix(self.prefix.as_str()).unwrap_or(dir)
    }

    /// The destination, opened on first use (it exists by then).
    fn beneath(&mut self) -> &Beneath {
        let root = &self.root;
        self.beneath
            .get_or_insert_with(|| Beneath::new(Path::new(root)))
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
    pub(crate) fn stamp_directories(&mut self) -> Result<(), (usize, Failure)> {
        let mut stamp = std::mem::take(&mut self.stamp);
        stamp.sort_by_key(|(_, path, _, _)| std::cmp::Reverse(path.components().count()));
        for (i, path, mtime, mode) in stamp {
            let below = self.below(&path_string(&path)).to_string();
            let path = path.as_path();
            // Through a handle opened beneath the destination where the
            // OS can, so a link swapped in cannot redirect a chmod.
            let dir = self
                .beneath()
                .directory_handle(path, &below)
                .map_err(|e| (i, at(path)(e)))?;
            if let Some(mtime) = mtime {
                let times = FileTimes::new().set_accessed(mtime).set_modified(mtime);
                dir.set_times(times).map_err(|e| (i, at(path)(e)))?;
            }
            if let Some(mode) = mode {
                set_directory_mode(&dir, path, mode).map_err(|e| (i, at(path)(e)))?;
            }
        }
        Ok(())
    }

    fn create_file(
        &mut self,
        name: &str,
        spec: &Spec,
        write: impl FnOnce(&mut fs::File) -> Result<u64, Failure>,
    ) -> Result<Option<u64>, Failure> {
        if !self.prepare_parents(name, spec)? {
            return Ok(None);
        }
        let path = Path::new(name);
        let replace = match (on_disk(path).map_err(at(path))?, self.on_exists) {
            // Never written through, whatever the policy.
            (OnDisk::Link, _) => {
                self.notices
                    .push((spec.index, Notice::Link(name.to_string())));
                return Ok(None);
            }
            (OnDisk::Missing, _) => false,
            (_, OnExists::Raise) => return Err(Failure::Exists(path_string(path))),
            (_, OnExists::Skip) => return Ok(None),
            // A directory in the way is not overwritten by a file.
            (OnDisk::Directory, OnExists::Overwrite) => {
                return Err(Failure::Exists(path_string(path)))
            }
            (OnDisk::Other, OnExists::Overwrite) => true,
        };
        // The directory it goes in, opened beneath the destination where
        // the OS can: a link swapped in since the walk is refused here.
        let (parent, leaf) = name.rsplit_once('/').unwrap_or(("", name));
        let parent = if parent.is_empty() { "/" } else { parent };
        let own = self.own;
        let below = self.below(parent).to_string();
        let place = match self.beneath().place(Path::new(parent), &below) {
            Ok(place) => place,
            Err(e) if is_link_error(&e) => {
                self.notices
                    .push((spec.index, Notice::Link(parent.to_string())));
                return Ok(None);
            }
            Err(e) => return Err(at(Path::new(parent))(e)),
        };
        // A file being replaced is written beside it and renamed over it
        // once complete, so a failure part-way leaves the original as it
        // was; a new one is written in place.
        let (target, mut file) = if replace {
            place.staging(leaf).map_err(at(path))?
        } else {
            match place.create_new(leaf) {
                Ok(f) => (leaf.to_string(), f),
                Err(e) if is_link_error(&e) => {
                    self.notices
                        .push((spec.index, Notice::Link(name.to_string())));
                    return Ok(None);
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists || path.exists() => {
                    return Err(Failure::Exists(path_string(path)));
                }
                Err(e) => return Err(at(path)(e)),
            }
        };
        let outcome = write(&mut file).and_then(|written| {
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
                if own {
                    make_replaceable(path);
                }
                place.rename(&target, leaf).map_err(at(path))?;
            }
            Ok(written)
        });
        let written = match outcome {
            Ok(n) => n,
            Err(failure) => {
                // Interrupted or failed part-way: a half-written file
                // would pass for the entry, and stand in the way of a
                // second run. What it replaces is still there.
                let _ = place.remove(&target);
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
        Ok(Some(written))
    }
}

/// Windows does not rename over a read-only file: the attribute comes
/// off first. Elsewhere a rename asks nothing of the file it replaces.
#[cfg(windows)]
fn make_replaceable(path: &Path) {
    if let Ok(meta) = fs::symlink_metadata(path) {
        let mut perms = meta.permissions();
        if meta.is_file() && perms.readonly() {
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
        }
    }
}

#[cfg(not(windows))]
fn make_replaceable(_path: &Path) {}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// The absolute path `name` lands on under `dest`, as `File.absolute_path`
/// resolves `File.join(dest, name)`, or `None` when it is not strictly
/// inside `dest`. The one exception, as in Ruby, is a destination that is
/// the root directory itself.
///
/// On Windows a name with a colon is not inside either: it names a
/// stream of a file ("a.txt:x" writes into `a.txt`, there before or not,
/// without replacing it) or a drive.
fn safe_path(dest: &str, name: &str) -> Option<String> {
    if cfg!(windows) && has_colon(name) {
        return None;
    }
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

fn has_colon(name: &str) -> bool {
    name.contains(':')
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

#[cfg(unix)]
fn set_file_mode(file: &fs::File, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    file.set_permissions(fs::Permissions::from_mode(mode))
}

/// Sets a directory's mode through its handle (fchmod).
#[cfg(unix)]
fn set_directory_mode(dir: &fs::File, _path: &Path, mode: u32) -> io::Result<()> {
    set_file_mode(dir, mode)
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

/// On Windows by path: the handle opened for times cannot change the
/// read-only attribute.
#[cfg(not(unix))]
fn set_directory_mode(_dir: &fs::File, path: &Path, mode: u32) -> io::Result<()> {
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
        // Only Windows reads a colon as a stream or a drive.
        for name in ["a.txt:evil", "a.txt::$DATA", "C:x", "d/e:f/g"] {
            assert!(has_colon(name));
            assert_eq!(safe_path("/p/dest", name).is_none(), cfg!(windows));
        }
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
