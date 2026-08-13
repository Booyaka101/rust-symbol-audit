//! facade 0.1.0 — a crate whose rlib carries NO v0 symbols at all: constants,
//! type aliases and a macro, with the real code living elsewhere. Widely-used
//! crates look like this (thiserror 1.0.61 has zero), and the symbol lane used
//! to abort on them, reporting the bump as clean.

pub const NAME: &str = "facade";

pub type Result<T> = core::result::Result<T, Error>;

#[derive(Debug)]
pub struct Error;

#[macro_export]
macro_rules! bail {
    () => {
        return Err($crate::Error)
    };
}
