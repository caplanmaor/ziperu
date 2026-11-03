//! Native core for the `ziperu` gem.
//!
//! The Rust side exposes a small set of primitives under `Zip::Native`;
//! everything Ruby-shaped (kwargs, blocks, `Enumerable`, error messages)
//! lives in `lib/`.

mod archive;
mod errors;
mod reader;
mod source;

use magnus::{function, method, prelude::*, Error, Ruby};

#[magnus::init(name = "ziperu")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let zip = ruby.define_module("Zip")?;
    let native = zip.define_module("Native")?;

    let archive = native.define_class("Archive", ruby.class_object())?;
    archive.define_singleton_method("open_path", function!(archive::Archive::open_path, 1))?;
    archive.define_singleton_method("open_bytes", function!(archive::Archive::open_bytes, 1))?;
    archive.define_method("entry_count", method!(archive::Archive::entry_count, 0))?;
    archive.define_method("entries", method!(archive::Archive::entries, 0))?;
    archive.define_method("entry_meta", method!(archive::Archive::entry_meta, 1))?;
    archive.define_method("comment", method!(archive::Archive::comment, 0))?;
    archive.define_method("open_entry", method!(archive::Archive::open_entry, 2))?;
    archive.define_method("read_entry", method!(archive::Archive::read_entry, 1))?;

    let reader = native.define_class("EntryReader", ruby.class_object())?;
    reader.define_method("size", method!(reader::EntryReader::size, 0))?;
    reader.define_method("pos", method!(reader::EntryReader::pos, 0))?;
    reader.define_method("eof?", method!(reader::EntryReader::is_eof, 0))?;
    reader.define_method("read", method!(reader::EntryReader::read, 1))?;
    reader.define_method("rewind", method!(reader::EntryReader::rewind, 0))?;

    Ok(())
}
