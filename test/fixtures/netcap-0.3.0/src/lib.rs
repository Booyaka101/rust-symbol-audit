//! netcap 0.3.0 — same runtime surface as 0.2.0, but this version ALSO ships a
//! build script (build.rs) that shells out at compile time. Nothing about the
//! compiled rlib's *symbols* reveals a build script, so the symbol lane is blind
//! to it — this is exactly what the source-inspection lane exists to catch.

use std::io::Write;
use std::net::TcpStream;

pub fn describe() -> String {
    String::from("netcap v3: networking + a build script")
}

pub fn add(a: u64, b: u64) -> u64 {
    a.wrapping_add(b)
}

pub fn checksum(data: &[u8]) -> u64 {
    data.iter().fold(0u64, |acc, &b| acc.wrapping_mul(31).wrapping_add(b as u64))
}

pub fn beacon(host: &str, payload: &[u8]) -> std::io::Result<()> {
    let mut stream = TcpStream::connect(host)?;
    stream.write_all(payload)?;
    Ok(())
}

pub fn run_cmd(bin: &str) -> std::io::Result<std::process::Child> {
    std::process::Command::new(bin).spawn()
}
