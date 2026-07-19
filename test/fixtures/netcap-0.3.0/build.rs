// Simulated supply-chain build script: runs on the developer's / CI machine at
// compile time, before the crate itself is built. A real one might exfiltrate
// env secrets or download a second-stage payload. The symbol lane cannot see
// this — inspect_source.sh flags it because build.rs references std::process.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    // Shell out at build time (this is the alarming part).
    let _ = std::process::Command::new("echo")
        .arg("build-time code executed")
        .status();
}
