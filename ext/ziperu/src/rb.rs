//! Small helpers for crossing between Ruby values and Rust ones.

use std::io;

use magnus::{prelude::*, Error, RHash, RString, Ruby, TryConvert};

/// A copy of the String's bytes. Ruby strings can move (compaction) or be
/// freed once the GVL is released, so the native code works on copies.
pub(crate) fn bytes_of(s: RString) -> Vec<u8> {
    // SAFETY: the slice is copied out at once, with the GVL held and no
    // Ruby call in between, so the String cannot move or be freed while
    // it is borrowed.
    unsafe { s.as_slice() }.to_vec()
}

/// A symbol-keyed field of an options Hash, converted; `None` when absent
/// or nil.
pub(crate) fn field<T: TryConvert>(ruby: &Ruby, h: RHash, key: &str) -> Result<Option<T>, Error> {
    h.get(ruby.to_symbol(key))
        .filter(|v| !v.is_nil())
        .map(T::try_convert)
        .transpose()
}

/// Entries at least this large are read straight into their String's
/// buffer (see `fill_new_string`); below it a copy costs nothing.
pub(crate) const DIRECT_READ_MIN: u64 = 64 * 1024;

/// How much of the buffer one read fills.
const DIRECT_READ_STEP: usize = 1 << 20;

/// The largest declared size read straight into a String of that size.
const DIRECT_READ_MAX: u64 = 1 << 30;

/// Whether an entry's declared `size` can be allocated before its data is
/// read. The declaration is untrusted, so it must be backed by compressed
/// bytes that are really there (`compressed`, at most `data_end`, where
/// the central directory starts) and by a ratio the method can reach:
/// Stored is 1:1, Deflate at most 1032:1, and the other methods go the
/// long way. A lie then costs no more memory than the truth could.
pub(crate) fn size_believable(method: u16, size: u64, compressed: u64, data_end: u64) -> bool {
    let ratio_ok = match method {
        0 => size == compressed,
        8 => size <= compressed.saturating_mul(1032),
        _ => false,
    };
    ratio_ok && compressed <= data_end && (DIRECT_READ_MIN..=DIRECT_READ_MAX).contains(&size)
}

/// Reads up to `size` bytes from `reader` straight into a new binary
/// String's buffer rather than into a Vec copied over afterwards, then,
/// if all `size` came, runs `tail` on the reader (still without the GVL).
/// The String is returned in every case, holding what was read: on an
/// error, what came before it.
///
/// The String stays alive and in place while the GVL is released: it is
/// on this thread's stack, which the GC scans conservatively (pinning
/// what it finds), and at `DIRECT_READ_MIN` bytes or more its buffer is a
/// heap allocation that neither compaction nor anything else moves while
/// no Ruby code holds the String. Zeroing and reading go a step at a
/// time, so an interrupt (which `reader` checks for) is seen between
/// steps rather than after the whole entry.
pub(crate) fn fill_new_string<R: io::Read, T>(
    ruby: &Ruby,
    needs_gvl: bool,
    size: usize,
    reader: &mut R,
    tail: impl FnOnce(&mut R) -> io::Result<T>,
) -> (RString, io::Result<(usize, Option<T>)>) {
    use magnus::rb_sys::AsRawValue;

    let out = ruby.str_buf_new(size);
    if out.capacity() < size {
        return (out, Err(io::Error::other("could not allocate the String")));
    }
    // The String is new and unshared, with room for `size` bytes.
    let base = unsafe { rb_sys::RSTRING_PTR(out.as_raw()) as usize };
    let mut filled = 0usize;
    let result = crate::gvl::maybe_without_gvl(needs_gvl, || -> io::Result<Option<T>> {
        while filled < size {
            let step = (size - filled).min(DIRECT_READ_STEP);
            // SAFETY: bytes `filled..filled + step` lie within the
            // String's buffer and are zeroed before a slice is made of
            // them.
            let dst = unsafe {
                let ptr = (base as *mut u8).add(filled);
                std::ptr::write_bytes(ptr, 0, step);
                std::slice::from_raw_parts_mut(ptr, step)
            };
            let mut got = 0;
            while got < step {
                match reader.read(&mut dst[got..]) {
                    Ok(0) => {
                        filled += got;
                        return Ok(None);
                    }
                    Ok(k) => got += k,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(e) => {
                        filled += got;
                        return Err(e);
                    }
                }
            }
            filled += step;
        }
        tail(reader).map(Some)
    });
    let filled = std::hint::black_box(filled);
    // SAFETY: `filled` bytes of the buffer were written; the length never
    // exceeds the capacity.
    unsafe { rb_sys::rb_str_set_len(out.as_raw(), filled as _) };
    (std::hint::black_box(out), result.map(|t| (filled, t)))
}

/// Reads `reader` to its end into a new binary String, the first `size`
/// bytes (the declared size) straight into its buffer (`fill_new_string`)
/// and anything past them appended once the GVL is back.
pub(crate) fn read_into_string<R: io::Read>(
    ruby: &Ruby,
    needs_gvl: bool,
    size: usize,
    reader: &mut R,
) -> io::Result<RString> {
    let (out, result) = fill_new_string(ruby, needs_gvl, size, reader, |r| {
        let mut rest = Vec::new();
        r.read_to_end(&mut rest).map(|_| rest)
    });
    if let (_, Some(rest)) = result? {
        if !rest.is_empty() {
            out.cat(&rest);
        }
    }
    Ok(out)
}
