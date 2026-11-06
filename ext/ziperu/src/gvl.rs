//! Running pure-Rust work with the GVL released.
//!
//! Inflating a chunk or deflating one takes real CPU time; letting other
//! Ruby threads run meanwhile is the point of a native core. Only work that
//! touches no Ruby object may run this way, which here means anything over a
//! `Source::File`, `Source::Memory` or the writer's sinks, never a
//! `Source::Ruby` (its reads call back into the interpreter).

use std::ffi::c_void;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::ptr::null_mut;
use std::thread::Result as ThreadResult;

struct Call<F, R> {
    f: Option<F>,
    out: Option<ThreadResult<R>>,
}

unsafe extern "C" fn trampoline<F: FnOnce() -> R, R>(data: *mut c_void) -> *mut c_void {
    // SAFETY: `data` is the `Call` that `without_gvl` built on its stack and
    // outlives this call.
    let call = unsafe { &mut *(data as *mut Call<F, R>) };
    let f = call.f.take().expect("trampoline runs once");
    // A panic must not unwind through the C frame of the Ruby VM.
    call.out = Some(catch_unwind(AssertUnwindSafe(f)));
    null_mut()
}

/// Runs `f` with the GVL released and returns its result. `f` must not
/// touch the Ruby heap (no `Value`, no `RString` slice, no `Ruby` handle).
/// A panic inside `f` is re-raised on this side of the FFI boundary.
pub fn without_gvl<F: FnOnce() -> R, R>(f: F) -> R {
    let mut call = Call {
        f: Some(f),
        out: None,
    };
    // SAFETY: `call` lives for the whole blocking call. No unblock function
    // is given, so `Thread#kill` or an interrupt waits for `f` to finish:
    // a chunked read returns within one 64 KiB chunk, but `read_entry`
    // and `write` of a large String run to the end of the data first.
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(trampoline::<F, R>),
            &mut call as *mut Call<F, R> as *mut c_void,
            None,
            null_mut(),
        );
    }
    match call.out.take().expect("trampoline ran") {
        Ok(r) => r,
        Err(panic) => resume_unwind(panic),
    }
}

/// `without_gvl` unless the work needs the interpreter (a Ruby-backed
/// source), in which case `f` simply runs inline.
pub fn maybe_without_gvl<F: FnOnce() -> R, R>(needs_gvl: bool, f: F) -> R {
    if needs_gvl {
        f()
    } else {
        without_gvl(f)
    }
}
