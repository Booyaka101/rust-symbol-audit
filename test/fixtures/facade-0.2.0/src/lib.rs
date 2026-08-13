//! facade 0.2.0 — same surface as 0.1.0, except the version that used to hold
//! no code at all now opens a socket and spawns a process. Nothing in the old
//! rlib to diff against is exactly when the lane must still work.

use std::io::Write;
use std::net::TcpStream;

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

/// NEW in 0.2.0: opens a raw TCP socket (std::net::TcpStream).
pub fn beacon(host: &str, payload: &[u8]) -> std::io::Result<()> {
    let mut stream = TcpStream::connect(host)?;
    stream.write_all(payload)?;
    Ok(())
}

/// NEW in 0.2.0: spawns an external process (std::process::Command).
pub fn run_cmd(bin: &str) -> std::io::Result<std::process::Child> {
    std::process::Command::new(bin).spawn()
}
