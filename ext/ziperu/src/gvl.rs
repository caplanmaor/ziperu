//! Running pure-Rust work with the GVL released.
//!
//! Inflating a chunk or deflating one takes real CPU time; letting other
//! Ruby threads run meanwhile is the point of a native core. Only work that
//! touches no Ruby object may run this way, which here means anything over a
//! `Source::File`, `Source::Memory` or the writer's file and memory sinks,
//! never a `Source::Ruby` or `Sink::Ruby` (their reads and writes call
//! back into the interpreter).
//!
//! The work can be interrupted. Ruby asks a thread without the GVL to stop
//! (`Thread#kill`, `Thread#raise`, `Timeout`, Ctrl-C) by calling an
//! "unblock function" from another thread; ours sets the call's
//! cancellation flag, the long loops (`check`, `Cancellable`) see it within
//! a chunk and return a `Cancelled` error, and once the GVL is back
//! `errors::io_error` raises the interrupt Ruby has pending.

use std::cell::RefCell;
use std::ffi::c_void;
use std::fmt;
use std::io::{self, Read};
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::Result as ThreadResult;

/// The cancellation flag of the call this OS thread is running without
/// the GVL, if any. Worker threads a call spawns are handed it with
/// `with_token`.
pub type Token = Option<Arc<AtomicBool>>;

// The initializers are already `const`; the lint misreads the macro.
#[allow(clippy::missing_const_for_thread_local)]
mod slots {
    use super::{RefCell, Token};
    thread_local! {
        pub(super) static TOKEN: RefCell<Token> = const { RefCell::new(None) };
        /// An exception that handling routine interrupts raised, for
        /// `errors::interrupted` to raise in its place. It is the thread's
        /// `$!` meanwhile, which keeps it alive.
        pub(super) static RAISED: RefCell<Option<magnus::Error>> = const { RefCell::new(None) };
    }
}
use slots::{RAISED, TOKEN};

/// How often Ruby may decline to release the GVL (see `without_gvl`)
/// before the work is run with it held.
const MAX_REFUSALS: u32 = 3;

/// The error a loop returns when its call has been asked to stop.
#[derive(Debug)]
pub struct Cancelled;

impl fmt::Display for Cancelled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("interrupted")
    }
}

impl std::error::Error for Cancelled {}

/// This thread's cancellation flag, to hand to threads it spawns.
pub fn token() -> Token {
    TOKEN.with(|t| t.borrow().clone())
}

/// Runs `f` with `token` as this thread's cancellation flag.
pub fn with_token<R>(token: Token, f: impl FnOnce() -> R) -> R {
    struct Restore(Token);
    impl Drop for Restore {
        fn drop(&mut self) {
            let previous = self.0.take();
            TOKEN.with(|t| *t.borrow_mut() = previous);
        }
    }
    let _restore = Restore(TOKEN.with(|t| t.replace(token)));
    f()
}

/// Whether the call this thread is running has been asked to stop.
pub fn cancelled() -> bool {
    TOKEN.with(|t| {
        t.borrow()
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::Acquire))
    })
}

/// `Err(Cancelled)` once the call has been asked to stop: for loops to
/// call between chunks.
pub fn check() -> io::Result<()> {
    if cancelled() {
        Err(io::Error::other(Cancelled))
    } else {
        Ok(())
    }
}

/// Whether `err` is a loop giving up because its call was asked to stop.
pub fn is_cancelled(err: &io::Error) -> bool {
    err.get_ref().is_some_and(|e| e.is::<Cancelled>())
}

/// A reader that stops with `Cancelled` once its call has been asked to.
pub struct Cancellable<R>(pub R);

impl<R: Read> Read for Cancellable<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        check()?;
        self.0.read(buf)
    }
}

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

/// The trampoline for `call`'s closure, whose type cannot be named.
fn trampoline_for<F: FnOnce() -> R, R>(
    _call: &Call<F, R>,
) -> unsafe extern "C" fn(*mut c_void) -> *mut c_void {
    trampoline::<F, R>
}

/// Called by Ruby, from whichever thread delivers the interrupt and
/// possibly without the GVL: it only raises the flag.
unsafe extern "C" fn unblock(data: *mut c_void) {
    // SAFETY: `data` points at the flag `without_gvl` keeps alive (in an
    // Arc it holds) for the whole blocking call.
    let flag = unsafe { &*(data as *const AtomicBool) };
    flag.store(true, Ordering::Release);
}

/// Runs `f` with the GVL released and returns its result. `f` must not
/// touch the Ruby heap (no `Value`, no `RString` slice, no `Ruby` handle).
/// A panic inside `f` is re-raised on this side of the FFI boundary. If
/// Ruby interrupts the thread meanwhile, `cancelled()` turns true inside
/// `f`, whose loops should then wind up with `Cancelled`.
pub fn without_gvl<F: FnOnce() -> R, R>(f: F) -> R {
    let flag = Arc::new(AtomicBool::new(false));
    let token = Some(Arc::clone(&flag));
    let run = move || with_token(token, f);
    let mut call = Call {
        f: Some(run),
        out: None,
    };
    // The `2` variant matters: plain `rb_thread_call_without_gvl` checks for pending interrupts on
    // the way out and raises them with a longjmp straight through these
    // Rust frames, skipping their destructors (a `RefCell` borrow left
    // held, a buffer leaked). This one leaves that to the caller, and the
    // `Cancelled` error our loops return gets the interrupt raised the
    // safe way (`errors::interrupted`), or Ruby raises it at its next
    // check once we are back in Ruby code.
    let mut refusals = 0;
    loop {
        // SAFETY: `call` and `flag` outlive the blocking call, and the
        // unblock function only stores to the flag.
        unsafe {
            rb_sys::rb_thread_call_without_gvl2(
                Some(trampoline_for(&call)),
                &mut call as *mut _ as *mut c_void,
                Some(unblock),
                Arc::as_ptr(&flag) as *mut c_void,
            );
        }
        let Some(run) = call.f.take() else { break };
        // Ruby returned without running `f`: an interrupt flag was set.
        // Often that is only its routine thread-scheduling timer; running
        // `f` with the GVL held then would make it impossible to
        // interrupt and keep every other thread waiting. So: with an
        // exception queued for this thread (`Thread#raise`, `Timeout`,
        // Ctrl-C), `f` runs already cancelled, stops at its first check,
        // and the exception is raised the usual way (`errors::interrupted`,
        // or Ruby's next check). Otherwise Ruby handles what is pending and
        // the GVL is released on another try.
        if exception_pending() {
            flag.store(true, Ordering::Release);
            return run();
        }
        refusals += 1;
        if refusals > MAX_REFUSALS {
            // Refused again and again: run it here, as it always could.
            return run();
        }
        if !handle_routine_interrupts() {
            flag.store(true, Ordering::Release);
            return run();
        }
        call.f = Some(run);
    }
    match call.out.take().expect("trampoline ran") {
        Ok(r) => r,
        Err(panic) => resume_unwind(panic),
    }
}

/// Whether an exception is queued for this thread, waiting for its next
/// interrupt check: `Thread#pending_interrupt?`, which leaves it queued.
///
/// Calling a method is itself an interrupt check, so the exception can be
/// raised by this very call. It is then no longer queued anywhere: it is
/// kept for `errors::interrupted` to raise, and this says it is pending.
/// Dropping it, as this once did, lost the exception for good: a
/// `Timeout` that fired at that moment never fired again, and the work it
/// guarded ran on.
fn exception_pending() -> bool {
    use magnus::prelude::*;
    let Ok(ruby) = magnus::Ruby::get() else {
        return false;
    };
    match ruby
        .thread_current()
        .funcall::<_, _, bool>("pending_interrupt?", ())
    {
        Ok(pending) => pending,
        Err(raised) => {
            RAISED.with(|r| *r.borrow_mut() = Some(raised));
            true
        }
    }
}

/// Lets Ruby handle the interrupts it has pending for this thread, none of
/// them an exception queued for it (`exception_pending` said so): thread
/// scheduling, finalizers, signal traps. False if one of those raised
/// after all (a trap handler, say); that exception is kept for
/// `errors::interrupted` to raise.
fn handle_routine_interrupts() -> bool {
    let Ok(ruby) = magnus::Ruby::get() else {
        return false;
    };
    match check_ints(&ruby) {
        Ok(()) => true,
        Err(e) => {
            RAISED.with(|r| *r.borrow_mut() = Some(e));
            false
        }
    }
}

/// Has Ruby handle this thread's pending interrupts now. An exception
/// among them comes back as the error instead of being raised.
pub fn check_ints(ruby: &magnus::Ruby) -> Result<(), magnus::Error> {
    use magnus::rb_sys::AsRawValue;
    let nil = ruby.qnil().as_raw();
    magnus::rb_sys::protect(|| {
        // SAFETY: the GVL is held, and `protect` turns what this raises
        // into an `Err` rather than a longjmp through Rust frames.
        unsafe { rb_sys::rb_thread_check_ints() };
        nil
    })
    .map(|_| ())
}

/// The exception `handle_routine_interrupts` caught, if any; taken.
pub fn take_raised() -> Option<magnus::Error> {
    RAISED.with(|r| r.borrow_mut().take())
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
