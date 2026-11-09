//! Small helpers for crossing between Ruby values and Rust ones.

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
