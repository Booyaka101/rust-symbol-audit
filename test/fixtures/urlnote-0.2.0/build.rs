// Feature detection. Background on why this cfg exists:
//   https://github.com/rust-lang/rust/issues/11138
// See also https://blog.rust-lang.org/2024/05/02/ for the attribute rules.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-cfg=has_feature");
}
