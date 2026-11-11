//! Map `zip::result::ZipError` onto the `Ziperu::*` exception hierarchy that
//! `lib/ziperu/errors.rb` defines.
//!
//! rubyzip's exception constructors take domain objects (an entry, a Zlib
//! error) rather than messages, so where Rust lacks the object it raises a
//! `Ziperu::Native::*` subclass of `Ziperu::Error` and the Ruby layer re-raises
//! the rubyzip-shaped one.

use magnus::{prelude::*, value::Lazy, Error, ExceptionClass, Ruby};
use std::io;
use zip::result::ZipError;

use crate::source::RubyError;

macro_rules! exception {
    ($vis:vis $name:ident, $path:literal) => {
        $vis static $name: Lazy<ExceptionClass> = Lazy::new(|ruby| {
            // Defined in lib/ziperu/errors.rb; without it (the extension
            // loaded on its own) errors are still raised, as StandardError.
            ruby.eval::<ExceptionClass>($path)
                .unwrap_or_else(|_| ruby.exception_standard_error())
        });
    };
}

exception!(pub ERROR, "Ziperu::Error");
exception!(DECOMPRESSION_ERROR, "Ziperu::DecompressionError");
exception!(NATIVE_SIZE_LIMIT_ERROR, "Ziperu::Native::SizeLimitError");
exception!(NATIVE_PASSWORD_ERROR, "Ziperu::Native::PasswordError");
exception!(pub NATIVE_UNSUPPORTED_ERROR, "Ziperu::Native::UnsupportedError");
exception!(pub DESTINATION_EXISTS_ERROR, "Ziperu::DestinationExistsError");
exception!(pub ENTRY_SIZE_ERROR, "Ziperu::EntrySizeError");
exception!(pub NATIVE_DUPLICATE_ENTRY_ERROR, "Ziperu::Native::DuplicateEntryError");
exception!(ENOENT, "Errno::ENOENT");
exception!(EACCES, "Errno::EACCES");
exception!(EEXIST, "Errno::EEXIST");
exception!(EISDIR, "Errno::EISDIR");
exception!(ENOTDIR, "Errno::ENOTDIR");

/// `.rb(ruby)?` on a crate or io result: the error as the Ruby exception
/// `zip_error` / `io_error` would raise for it.
pub(crate) trait IntoRuby<T> {
    fn rb(self, ruby: &Ruby) -> Result<T, Error>;
}

impl<T> IntoRuby<T> for Result<T, ZipError> {
    fn rb(self, ruby: &Ruby) -> Result<T, Error> {
        self.map_err(|e| zip_error(ruby, e))
    }
}

impl<T> IntoRuby<T> for io::Result<T> {
    fn rb(self, ruby: &Ruby) -> Result<T, Error> {
        self.map_err(|e| io_error(ruby, e))
    }
}

/// `zip_error`, except that an io error inside (how the crate reports a
/// failure while reading an entry's data) goes through `read_error`.
pub fn zip_read_error(ruby: &Ruby, err: ZipError) -> Error {
    match err {
        ZipError::Io(io) => read_error(ruby, io),
        other => zip_error(ruby, other),
    }
}

/// The crate's size check reports as plain InvalidData (crc32.rs); this
/// is how it is told apart.
pub fn is_size_limit(err: &io::Error) -> bool {
    err.kind() == io::ErrorKind::InvalidData
        && err
            .to_string()
            .contains("larger than its declared uncompressed size")
}

pub fn zip_error(ruby: &Ruby, err: ZipError) -> Error {
    match err {
        ZipError::Io(e) => io_error(ruby, e),
        ZipError::FileNotFound => Error::new(ruby.get_inner(&ERROR), "entry not found in archive"),
        ZipError::InvalidPassword => {
            Error::new(ruby.get_inner(&NATIVE_PASSWORD_ERROR), "invalid password")
        }
        ZipError::DecompressedSizeLimitExceeded { .. } => size_limit_error(ruby),
        ZipError::UnsupportedArchive(msg) => {
            Error::new(ruby.get_inner(&NATIVE_UNSUPPORTED_ERROR), msg)
        }
        ZipError::InvalidArchive(msg) => {
            Error::new(ruby.get_inner(&ERROR), invalid_archive_message(&msg))
        }
        other => Error::new(ruby.get_inner(&ERROR), other.to_string()),
    }
}

/// The crate's wording, except where rubyzip's is what callers match on.
fn invalid_archive_message(msg: &str) -> String {
    if msg.contains("EOCD") {
        "Zip end of central directory signature not found".to_string()
    } else {
        // Some of the crate's messages carry a placeholder it never fills.
        msg.replace(" of {properties_size}", "")
    }
}

/// `io_error` for a failure while reading an archive's own structure (a
/// central record, a local header): bytes that end early or make no
/// sense are a broken archive, `Ziperu::Error`, not an `IOError`.
pub fn header_error(ruby: &Ruby, err: io::Error) -> Error {
    if is_foreign(&err) || crate::gvl::is_cancelled(&err) {
        return io_error(ruby, err);
    }
    match err.kind() {
        io::ErrorKind::UnexpectedEof => Error::new(
            ruby.get_inner(&ERROR),
            "invalid Zip archive: a header runs past the end of the data",
        ),
        io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput => Error::new(
            ruby.get_inner(&ERROR),
            format!("invalid Zip archive: {err}"),
        ),
        _ => io_error(ruby, err),
    }
}

/// An error that carries a Ruby exception or one of the crate's own.
fn is_foreign(err: &io::Error) -> bool {
    err.get_ref()
        .is_some_and(|e| e.is::<RubyError>() || e.is::<ZipError>())
}

/// The kinds that are about the file system or the machine rather than
/// the bytes being decoded.
fn is_system(kind: io::ErrorKind) -> bool {
    use io::ErrorKind::*;
    matches!(
        kind,
        NotFound
            | PermissionDenied
            | AlreadyExists
            | IsADirectory
            | NotADirectory
            | StorageFull
            | WriteZero
            | Interrupted
            | OutOfMemory
            | BrokenPipe
            | ResourceBusy
            | ReadOnlyFilesystem
            | QuotaExceeded
            | FileTooLarge
            | TimedOut
    )
}

/// Raised when a thread calls into a native object another thread is
/// using with the GVL released (an inflate or deflate in progress).
pub fn busy_error(ruby: &Ruby, what: &str) -> Error {
    Error::new(
        ruby.exception_thread_error(),
        format!("{what} is in use by another thread"),
    )
}

pub fn io_error(ruby: &Ruby, err: io::Error) -> Error {
    if crate::gvl::is_cancelled(&err) {
        return interrupted(ruby);
    }
    // An exception from a Ruby IO source propagates unchanged.
    let err = match err.downcast::<RubyError>() {
        Ok(ruby_err) => return ruby_err.into_error(),
        Err(err) => err,
    };
    // The crate funnels its own errors through io::Error while reading.
    if let Some(inner) = err.get_ref().and_then(|e| e.downcast_ref::<ZipError>()) {
        return match inner {
            ZipError::DecompressedSizeLimitExceeded { .. } => size_limit_error(ruby),
            ZipError::InvalidPassword => {
                Error::new(ruby.get_inner(&NATIVE_PASSWORD_ERROR), "invalid password")
            }
            ZipError::UnsupportedArchive(msg) => {
                Error::new(ruby.get_inner(&NATIVE_UNSUPPORTED_ERROR), *msg)
            }
            other => Error::new(ruby.get_inner(&ERROR), other.to_string()),
        };
    }
    match err.kind() {
        io::ErrorKind::NotFound => Error::new(ruby.get_inner(&ENOENT), err.to_string()),
        io::ErrorKind::PermissionDenied => Error::new(ruby.get_inner(&EACCES), err.to_string()),
        io::ErrorKind::AlreadyExists => Error::new(ruby.get_inner(&EEXIST), err.to_string()),
        io::ErrorKind::IsADirectory => Error::new(ruby.get_inner(&EISDIR), err.to_string()),
        io::ErrorKind::NotADirectory => Error::new(ruby.get_inner(&ENOTDIR), err.to_string()),
        _ if is_size_limit(&err) => size_limit_error(ruby),
        io::ErrorKind::InvalidData => decompression_error(ruby, &err.to_string()),
        // An archive that ends early, or an offset no file can seek to
        // (a forged zip64 field): a broken archive.
        io::ErrorKind::UnexpectedEof => Error::new(
            ruby.get_inner(&ERROR),
            format!("invalid Zip archive: unexpected end of data ({err})"),
        ),
        io::ErrorKind::InvalidInput => Error::new(
            ruby.get_inner(&ERROR),
            format!("invalid Zip archive: {err}"),
        ),
        _ => Error::new(ruby.exception_io_error(), err.to_string()),
    }
}

/// `io_error` for a failure while reading an entry's data. The decoders
/// each report corrupt input their own way (zlib as `InvalidInput`, a
/// truncated stream as `UnexpectedEof`, zstd and lzma as `Other` with a
/// message): all of it is rubyzip's `DecompressionError`, which is what
/// callers rescue around a read. A file system error, an exception from a
/// Ruby IO, an interrupt and the crate's own errors keep their own class.
pub fn read_error(ruby: &Ruby, err: io::Error) -> Error {
    if is_foreign(&err)
        || crate::gvl::is_cancelled(&err)
        || is_size_limit(&err)
        || is_system(err.kind())
    {
        return io_error(ruby, err);
    }
    decompression_error(ruby, &err.to_string())
}

/// Work cut short because Ruby interrupted the thread (see `gvl`): the
/// interrupt is pending, and checking for it raises it (Timeout::Error,
/// Interrupt, the exception of a `Thread#raise`), which is what the
/// caller should see. Should there be none, a plain `Ziperu::Error`.
pub fn interrupted(ruby: &Ruby) -> Error {
    use magnus::rb_sys::AsRawValue;
    let nil = ruby.qnil().as_raw();
    // SAFETY: called with the GVL held; `protect` turns the exception that
    // `rb_thread_check_ints` raises into an `Err` rather than a longjmp
    // through Rust frames.
    let pending = magnus::rb_sys::protect(|| {
        unsafe { rb_sys::rb_thread_check_ints() };
        nil
    });
    match pending {
        Err(e) => e,
        Ok(_) => Error::new(ruby.get_inner(&ERROR), "interrupted"),
    }
}

pub fn size_limit_error(ruby: &Ruby) -> Error {
    Error::new(
        ruby.get_inner(&NATIVE_SIZE_LIMIT_ERROR),
        "entry is larger than its declared size",
    )
}

/// `Ziperu::DecompressionError.new(zlib_error)` wants an error object; an
/// `IOError` carrying the crate's message plays that role.
fn decompression_error(ruby: &Ruby, msg: &str) -> Error {
    let cause = match ruby.exception_io_error().new_instance((msg,)) {
        Ok(c) => c,
        Err(e) => return e,
    };
    match ruby.get_inner(&DECOMPRESSION_ERROR).new_instance((cause,)) {
        Ok(exc) => Error::from(exc),
        Err(e) => e,
    }
}
