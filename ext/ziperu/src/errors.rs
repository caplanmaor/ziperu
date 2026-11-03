//! Map `zip::result::ZipError` onto the `Zip::*` exception hierarchy that
//! `lib/zip/errors.rb` defines.

use magnus::{prelude::*, value::Lazy, Error, ExceptionClass, Ruby};
use std::io;
use zip::result::ZipError;

macro_rules! exception {
    ($name:ident, $module:literal, $const:literal) => {
        static $name: Lazy<ExceptionClass> = Lazy::new(|ruby| {
            ruby.define_module($module)
                .expect(concat!($module, " module"))
                .const_get($const)
                .expect(concat!($module, "::", $const, " must be defined"))
        });
    };
}

exception!(ERROR, "Zip", "Error");
exception!(COMPRESSION_METHOD_ERROR, "Zip", "CompressionMethodError");
exception!(DECOMPRESSION_ERROR, "Zip", "DecompressionError");
exception!(ENTRY_SIZE_ERROR, "Zip", "EntrySizeError");
exception!(ENOENT, "Errno", "ENOENT");
exception!(EACCES, "Errno", "EACCES");

pub fn zip_error(ruby: &Ruby, err: ZipError) -> Error {
    match err {
        ZipError::Io(e) => io_error(ruby, e),
        ZipError::FileNotFound => Error::new(ruby.get_inner(&ERROR), "entry not found in archive"),
        ZipError::InvalidPassword => Error::new(
            ruby.get_inner(&ERROR),
            "A password is required to decode this zip file.",
        ),
        ZipError::UnsupportedArchive(msg) if msg.contains("ompression") => {
            Error::new(ruby.get_inner(&COMPRESSION_METHOD_ERROR), msg)
        }
        ZipError::UnsupportedArchive(msg) => Error::new(ruby.get_inner(&ERROR), msg),
        ZipError::InvalidArchive(msg) => Error::new(ruby.get_inner(&ERROR), msg.to_string()),
        other => Error::new(ruby.get_inner(&ERROR), other.to_string()),
    }
}

pub fn io_error(ruby: &Ruby, err: io::Error) -> Error {
    match err.kind() {
        io::ErrorKind::NotFound => Error::new(ruby.get_inner(&ENOENT), err.to_string()),
        io::ErrorKind::PermissionDenied => Error::new(ruby.get_inner(&EACCES), err.to_string()),
        io::ErrorKind::InvalidData => {
            Error::new(ruby.get_inner(&DECOMPRESSION_ERROR), err.to_string())
        }
        _ => Error::new(ruby.exception_io_error(), err.to_string()),
    }
}

#[allow(dead_code)]
pub fn entry_size_error(ruby: &Ruby, msg: String) -> Error {
    Error::new(ruby.get_inner(&ENTRY_SIZE_ERROR), msg)
}
