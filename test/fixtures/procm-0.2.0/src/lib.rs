//! procm 0.2.0 — now a proc-macro crate. (Body is illustrative; the audit flags
//! the proc-macro transition from the manifest, not from building this.)
use proc_macro::TokenStream;

#[proc_macro]
pub fn greet(_input: TokenStream) -> TokenStream {
    "\"hello\"".parse().unwrap()
}
