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
            ruby.eval::<ExceptionClass>($path)
                .expect(concat!($path, " must be defined in lib/ziperu/errors.rb"))
        });
    };
}

exception!(pub ERROR, "Ziperu::Error");
exception!(DECOMPRESSION_ERROR, "Ziperu::DecompressionError");
exception!(NATIVE_SIZE_LIMIT_ERROR, "Ziperu::Native::SizeLimitError");
exception!(NATIVE_PASSWORD_ERROR, "Ziperu::Native::PasswordError");
exception!(NATIVE_UNSUPPORTED_ERROR, "Ziperu::Native::UnsupportedError");
exception!(ENOENT, "Errno::ENOENT");
exception!(EACCES, "Errno::EACCES");
exception!(EEXIST, "Errno::EEXIST");
exception!(EISDIR, "Errno::EISDIR");
exception!(ENOTDIR, "Errno::ENOTDIR");

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
        msg.to_string()
    }
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
    // An exception from a Ruby IO source propagates unchanged.
    let err = match err.downcast::<RubyError>() {
        Ok(ruby_err) => return ruby_err.0,
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
        // The crate's size check reports as plain InvalidData (crc32.rs).
        io::ErrorKind::InvalidData
            if err
                .to_string()
                .contains("larger than its declared uncompressed size") =>
        {
            size_limit_error(ruby)
        }
        io::ErrorKind::InvalidData => decompression_error(ruby, &err.to_string()),
        _ => Error::new(ruby.exception_io_error(), err.to_string()),
    }
}

/// `io_error` for a failure while reading an entry's data, where the
/// decoders report corrupt input as `InvalidInput` and a stream that ends
/// early as `UnexpectedEof`: both are rubyzip's `DecompressionError`, which
/// is what callers rescue around a read.
pub fn read_error(ruby: &Ruby, err: io::Error) -> Error {
    let foreign = err
        .get_ref()
        .is_some_and(|e| e.is::<RubyError>() || e.is::<ZipError>());
    match err.kind() {
        io::ErrorKind::InvalidInput | io::ErrorKind::UnexpectedEof if !foreign => {
            decompression_error(ruby, &err.to_string())
        }
        _ => io_error(ruby, err),
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
