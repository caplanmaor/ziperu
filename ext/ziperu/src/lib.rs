//! Native core for the `ziperu` gem.
//!
//! The Rust side exposes a small set of primitives under `Zip::Native`;
//! everything Ruby-shaped (kwargs, blocks, `Enumerable`, error messages)
//! lives in `lib/`.

mod archive;
mod errors;
mod reader;
mod source;
mod writer;

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
    archive.define_method("open_entry", method!(archive::Archive::open_entry, 3))?;
    archive.define_method("read_entry", method!(archive::Archive::read_entry, 1))?;
    archive.define_method("close", method!(archive::Archive::close, 0))?;
    archive.define_method("closed?", method!(archive::Archive::is_closed, 0))?;

    let reader = native.define_class("EntryReader", ruby.class_object())?;
    reader.define_method("size", method!(reader::EntryReader::size, 0))?;
    reader.define_method("pos", method!(reader::EntryReader::pos, 0))?;
    reader.define_method("eof?", method!(reader::EntryReader::is_eof, 0))?;
    reader.define_method("read", method!(reader::EntryReader::read, 1))?;
    reader.define_method("rewind", method!(reader::EntryReader::rewind, 0))?;
    reader.define_method("close", method!(reader::EntryReader::close, 0))?;

    let writer = native.define_class("Writer", ruby.class_object())?;
    writer.define_singleton_method("open_path", function!(writer::Writer::open_path, 1))?;
    writer.define_singleton_method("open_memory", function!(writer::Writer::open_memory, 0))?;
    writer.define_method("start_entry", method!(writer::Writer::start_entry, 2))?;
    writer.define_method("add_directory", method!(writer::Writer::add_directory, 2))?;
    writer.define_method("write", method!(writer::Writer::write, 1))?;
    writer.define_method("raw_copy", method!(writer::Writer::raw_copy, 3))?;
    writer.define_method("comment=", method!(writer::Writer::set_comment, 1))?;
    writer.define_method("finish", method!(writer::Writer::finish, 0))?;
    writer.define_method("closed?", method!(writer::Writer::is_closed, 0))?;

    Ok(())
}
