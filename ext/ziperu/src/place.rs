//! Where extraction creates things, without going through a link.
//!
//! `extract.rs` first walks each path with `lstat` and refuses links, which
//! is enough unless someone swaps a directory for a link in between. On
//! Linux 5.6 and later this module closes that gap: the destination is
//! opened once, and every directory a file goes into is opened from it with
//! `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`, so the kernel refuses a
//! link anywhere on the way (`ELOOP`) or a path that leaves the destination
//! (`EXDEV`). The file is then created, renamed and removed relative to
//! that directory handle, with `O_NOFOLLOW` at the leaf.
//!
//! Elsewhere (Windows, macOS, an older kernel, or a sandbox that refuses
//! the system call) the same operations go by path, and only the `lstat`
//! walk stands between a write and a link.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The destination, opened when the OS can resolve paths beneath it.
pub(crate) struct Beneath {
    #[cfg(target_os = "linux")]
    root: Option<std::os::fd::OwnedFd>,
}

/// A directory to create things in: `path` always, and on Linux a handle
/// on it opened beneath the destination.
#[derive(Debug)]
pub(crate) struct Place {
    path: PathBuf,
    #[cfg(target_os = "linux")]
    fd: Option<std::os::fd::OwnedFd>,
}

/// Whether `e` says a link stood in the way: what `openat2` and
/// `O_NOFOLLOW` fail with.
pub(crate) fn is_link_error(e: &io::Error) -> bool {
    #[cfg(target_os = "linux")]
    {
        matches!(e.raw_os_error(), Some(libc::ELOOP | libc::EXDEV))
    }
    #[cfg(all(unix, not(target_os = "linux")))]
    {
        e.raw_os_error() == Some(libc::ELOOP)
    }
    #[cfg(not(unix))]
    {
        let _ = e;
        false
    }
}

impl Beneath {
    /// Opens the destination `root` (an existing directory, taken as
    /// given even when it is itself a link).
    pub(crate) fn new(root: &Path) -> Self {
        #[cfg(target_os = "linux")]
        {
            Self {
                root: linux::open_root(root),
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = root;
            Self {}
        }
    }

    /// Whether paths are resolved by the kernel beneath the destination.
    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn is_race_free(&self) -> bool {
        self.root.is_some()
    }

    /// The directory `path`, which is `below` (relative, `/`-separated,
    /// empty for the destination itself) under the destination.
    pub(crate) fn place(&self, path: &Path, below: &str) -> io::Result<Place> {
        #[cfg(target_os = "linux")]
        {
            let fd = match &self.root {
                Some(root) => Some(linux::open_beneath(
                    root,
                    below,
                    libc::O_PATH | libc::O_DIRECTORY,
                )?),
                None => None,
            };
            Ok(Place {
                path: path.to_path_buf(),
                fd,
            })
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = below;
            Ok(Place {
                path: path.to_path_buf(),
            })
        }
    }

    /// A handle on the directory `path` (`below` under the destination)
    /// to set its times and mode through.
    pub(crate) fn directory_handle(&self, path: &Path, below: &str) -> io::Result<File> {
        #[cfg(target_os = "linux")]
        if let Some(root) = &self.root {
            return linux::open_beneath(root, below, libc::O_RDONLY | libc::O_DIRECTORY)
                .map(File::from);
        }
        let _ = below;
        open_directory(path)
    }
}

impl Place {
    /// Creates `leaf`, which must not exist yet.
    pub(crate) fn create_new(&self, leaf: &str) -> io::Result<File> {
        #[cfg(target_os = "linux")]
        if let Some(dir) = &self.fd {
            return linux::create_new(dir, leaf);
        }
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        no_follow(&mut options);
        options.open(self.path.join(leaf))
    }

    /// A new hidden file beside `leaf` to write its replacement into;
    /// returns its name and the file.
    pub(crate) fn staging(&self, leaf: &str) -> io::Result<(String, File)> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        loop {
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let staged = format!(".{leaf}.ziperu-{}-{n}", std::process::id());
            match self.create_new(&staged) {
                Ok(file) => return Ok((staged, file)),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
        }
    }

    /// Renames `from` over `to`, both in this directory.
    pub(crate) fn rename(&self, from: &str, to: &str) -> io::Result<()> {
        #[cfg(target_os = "linux")]
        if let Some(dir) = &self.fd {
            return linux::rename(dir, from, to);
        }
        fs::rename(self.path.join(from), self.path.join(to))
    }

    /// Removes the file `leaf` from this directory.
    pub(crate) fn remove(&self, leaf: &str) -> io::Result<()> {
        #[cfg(target_os = "linux")]
        if let Some(dir) = &self.fd {
            return linux::unlink(dir, leaf);
        }
        fs::remove_file(self.path.join(leaf))
    }
}

/// Opens without following a link at the path itself, where the OS can.
#[cfg(unix)]
pub(crate) fn no_follow(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_NOFOLLOW);
}

#[cfg(not(unix))]
pub(crate) fn no_follow(_options: &mut OpenOptions) {}

/// A directory handle that `set_times` accepts: on Windows that means
/// backup semantics and write-attributes access, which a plain `open`
/// does not ask for.
#[cfg(windows)]
pub(crate) fn open_directory(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x0100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    OpenOptions::new()
        .access_mode(FILE_WRITE_ATTRIBUTES)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

#[cfg(not(windows))]
pub(crate) fn open_directory(path: &Path) -> io::Result<File> {
    File::open(path)
}

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::CString;
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    const RESOLVE: u64 =
        libc::RESOLVE_BENEATH | libc::RESOLVE_NO_SYMLINKS | libc::RESOLVE_NO_MAGICLINKS;

    fn c_string(s: &[u8]) -> io::Result<CString> {
        CString::new(s).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }

    /// The destination as a handle, when `openat2` works here: None on a
    /// kernel without it (ENOSYS) or where a sandbox refuses it (EPERM),
    /// and then everything goes by path.
    pub(super) fn open_root(root: &Path) -> Option<OwnedFd> {
        let path = c_string(root.as_os_str().as_bytes()).ok()?;
        // SAFETY: `path` is a valid NUL-terminated string for the call.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return None;
        }
        // SAFETY: `fd` was just returned by open and is owned by no one else.
        let root = unsafe { OwnedFd::from_raw_fd(fd) };
        // A probe of the destination itself tells whether openat2 is
        // there at all.
        match open_beneath(&root, "", libc::O_PATH | libc::O_DIRECTORY) {
            Ok(_) => Some(root),
            Err(_) => None,
        }
    }

    /// `openat2(dir, below, flags, RESOLVE)`; `below` empty is `dir` itself.
    /// Retried on EAGAIN, which the kernel returns when a rename elsewhere
    /// raced the lookup.
    pub(super) fn open_beneath(dir: &OwnedFd, below: &str, flags: i32) -> io::Result<OwnedFd> {
        let below = if below.is_empty() { "." } else { below };
        let path = c_string(below.as_bytes())?;
        // SAFETY: open_how is plain integers, so all-zero is a valid value;
        // the fields the kernel reads are set below.
        let mut how: libc::open_how = unsafe { std::mem::zeroed() };
        how.flags = (flags | libc::O_CLOEXEC) as u64;
        how.resolve = RESOLVE;
        for _ in 0..16 {
            // SAFETY: `path` is NUL-terminated, `how` is a valid open_how
            // whose size is passed with it, and `dir` is an open handle.
            let fd = unsafe {
                libc::syscall(
                    libc::SYS_openat2,
                    dir.as_raw_fd(),
                    path.as_ptr(),
                    &how as *const libc::open_how,
                    std::mem::size_of::<libc::open_how>(),
                )
            };
            if fd >= 0 {
                // SAFETY: the kernel returned a new descriptor we now own.
                return Ok(unsafe { OwnedFd::from_raw_fd(fd as i32) });
            }
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EAGAIN) {
                return Err(err);
            }
        }
        Err(io::Error::from_raw_os_error(libc::EAGAIN))
    }

    pub(super) fn create_new(dir: &OwnedFd, leaf: &str) -> io::Result<File> {
        let name = c_string(leaf.as_bytes())?;
        // SAFETY: `name` is NUL-terminated and `dir` is an open handle.
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o666 as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the descriptor was just returned by openat and is ours.
        Ok(File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    pub(super) fn rename(dir: &OwnedFd, from: &str, to: &str) -> io::Result<()> {
        let (from, to) = (c_string(from.as_bytes())?, c_string(to.as_bytes())?);
        // SAFETY: both names are NUL-terminated and `dir` is an open handle.
        let r =
            unsafe { libc::renameat(dir.as_raw_fd(), from.as_ptr(), dir.as_raw_fd(), to.as_ptr()) };
        if r == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub(super) fn unlink(dir: &OwnedFd, leaf: &str) -> io::Result<()> {
        let name = c_string(leaf.as_bytes())?;
        // SAFETY: `name` is NUL-terminated and `dir` is an open handle.
        let r = unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) };
        if r == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::symlink;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ziperu-place-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("dest/a")).expect("scratch dirs");
        fs::create_dir_all(dir.join("outside")).expect("scratch dirs");
        dir
    }

    #[test]
    fn a_link_on_the_way_is_refused_by_the_kernel() {
        let dir = scratch("link");
        let dest = dir.join("dest");
        symlink(dir.join("outside"), dest.join("a/l")).expect("symlink");
        let beneath = Beneath::new(&dest);
        if !beneath.is_race_free() {
            eprintln!("openat2 unavailable here; skipping");
            return;
        }
        let err = beneath
            .place(&dest.join("a/l"), "a/l")
            .expect_err("refused");
        assert!(is_link_error(&err), "{err}");
        let err = beneath
            .directory_handle(&dest.join("a/l"), "a/l")
            .expect_err("refused");
        assert!(is_link_error(&err), "{err}");
        // `..` cannot climb out either.
        let err = beneath.place(&dir, "a/../..").expect_err("refused");
        assert!(is_link_error(&err), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_directory_swapped_for_a_link_after_the_check_is_not_followed() {
        let dir = scratch("swap");
        let dest = dir.join("dest");
        let beneath = Beneath::new(&dest);
        if !beneath.is_race_free() {
            eprintln!("openat2 unavailable here; skipping");
            return;
        }
        // The directory is checked and opened, then swapped for a link.
        let place = beneath
            .place(&dest.join("a"), "a")
            .expect("a real directory");
        fs::rename(dest.join("a"), dest.join("moved")).expect("move aside");
        symlink(dir.join("outside"), dest.join("a")).expect("symlink");
        let mut file = place.create_new("x.txt").expect("created");
        file.write_all(b"data").expect("written");
        let (staged, _) = place.staging("x.txt").expect("staged");
        place.rename(&staged, "x.txt").expect("renamed");
        // Everything landed in the directory that was checked.
        assert!(dest.join("moved/x.txt").exists());
        assert!(fs::read_dir(dir.join("outside"))
            .expect("outside")
            .next()
            .is_none());
        // A fresh lookup refuses the link.
        let err = beneath.place(&dest.join("a"), "a").expect_err("refused");
        assert!(is_link_error(&err), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }
}
