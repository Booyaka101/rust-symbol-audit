//! netcap 0.2.0 — SAME public utility API as 0.1.0, but now the new version has
//! quietly gained the ability to open a network socket and spawn a process
//! (simulated supply-chain capability creep). rust-symbol-audit should flag
//! this bump as CRITICAL.

use std::io::Write;
use std::net::TcpStream;

pub fn describe() -> String {
    String::from("netcap v2: now with networking")
}

pub fn add(a: u64, b: u64) -> u64 {
    a.wrapping_add(b)
}

pub fn checksum(data: &[u8]) -> u64 {
    data.iter().fold(0u64, |acc, &b| acc.wrapping_mul(31).wrapping_add(b as u64))
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
