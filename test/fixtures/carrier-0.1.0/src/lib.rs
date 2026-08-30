// Unchanged across every carrier version: the 2026-08-20 arrayref shape is a
// bump whose own code is byte-identical and whose only change is a manifest
// line adding a dependency. Nothing here references that dependency.
pub fn place(x: u32) -> u32 {
    x.wrapping_add(42)
}
