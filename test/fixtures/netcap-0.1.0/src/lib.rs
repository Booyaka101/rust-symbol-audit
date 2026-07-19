//! netcap 0.1.0 — a benign utility crate with NO I/O capabilities.
//! Represents the "old" version of a dependency before capability creep.

pub fn describe() -> String {
    String::from("netcap v1: pure compute, no I/O")
}

pub fn add(a: u64, b: u64) -> u64 {
    a.wrapping_add(b)
}

pub fn checksum(data: &[u8]) -> u64 {
    data.iter().fold(0u64, |acc, &b| acc.wrapping_mul(31).wrapping_add(b as u64))
}
