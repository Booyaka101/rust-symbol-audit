// Feature-detection build script in the proc-macro2 / serde / libc mould:
// shell out to rustc to see what the compiler supports. This is process
// execution with NO network fetch, so it must never tier as an implant.
use std::process::Command;
use std::env;
fn main() {
    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let out = Command::new(&rustc).arg("--version").output();
    if let Ok(o) = out {
        if o.status.success() {
            println!("cargo:rustc-cfg=has_rustc");
        }
    }
    println!("cargo:rerun-if-changed=build.rs");
}
