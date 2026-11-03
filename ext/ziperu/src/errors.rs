//! Map `zip::result::ZipError` onto the `Zip::*` exception hierarchy that
//! `lib/zip/errors.rb` defines.
//!
//! rubyzip's exception constructors take domain objects (an entry, a Zlib
//! error) rather than messages, so where Rust lacks the object it raises a
//! `Zip::Native::*` subclass of `Zip::Error` and the Ruby layer re-raises
//! the rubyzip-shaped one.

use magnus::{prelude::*, value::Lazy, Error, ExceptionClass, Ruby};
use std::io;
use zip::result::ZipError;

macro_rules! exception {
    ($name:ident, $path:literal) => {
        static $name: Lazy<ExceptionClass> = Lazy::new(|ruby| {
            ruby.eval::<ExceptionClass>($path)
                .expect(concat!($path, " must be defined in lib/zip/errors.rb"))
        });
    };
}

exception!(ERROR, "Zip::Error");
exception!(DECOMPRESSION_ERROR, "Zip::DecompressionError");
exception!(NATIVE_SIZE_LIMIT_ERROR, "Zip::Native::SizeLimitError");
exception!(NATIVE_PASSWORD_ERROR, "Zip::Native::PasswordError");
exception!(NATIVE_UNSUPPORTED_ERROR, "Zip::Native::UnsupportedError");
exception!(ENOENT, "Errno::ENOENT");
exception!(EACCES, "Errno::EACCES");

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
        ZipError::InvalidArchive(msg) => Error::new(ruby.get_inner(&ERROR), msg.to_string()),
        other => Error::new(ruby.get_inner(&ERROR), other.to_string()),
    }
}

pub fn io_error(ruby: &Ruby, err: io::Error) -> Error {
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
        io::ErrorKind::InvalidData => decompression_error(ruby, &err.to_string()),
        _ => Error::new(ruby.exception_io_error(), err.to_string()),
    }
}

pub fn size_limit_error(ruby: &Ruby) -> Error {
    Error::new(
        ruby.get_inner(&NATIVE_SIZE_LIMIT_ERROR),
        "entry is larger than its declared size",
    )
}

/// `Zip::DecompressionError.new(zlib_error)` wants an error object; an
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
