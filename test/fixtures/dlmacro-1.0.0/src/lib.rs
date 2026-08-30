// Ordinary proc-macro-flavoured source, like proc-macro1's disguise as a
// proc-macro2 fork. Nothing here is malicious; the payload is in build.rs.
pub fn helper() -> &'static str {
    "ok"
}
