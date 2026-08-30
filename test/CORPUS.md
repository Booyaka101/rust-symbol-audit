# Corpus measurement — new-dependency build-script gate

A rule written from a spec is a hypothesis. Before 3.4.0 shipped, the
new-dependency `build.rs` rule was measured against a real corpus so the
false-positive claim is reproducible, not asserted.

## Method

Resolve the transitive trees of 19 popular crates spanning the ecosystem
(network, macros, crypto, FFI, image/codec), then run the shipped gate over
every crate the resolution extracted:

```bash
mkdir /tmp/corpus && cd /tmp/corpus && cargo init --lib -q
cat >> Cargo.toml <<'TOML'
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = "0.12"
hyper = "1"
clap = { version = "4", features = ["derive"] }
regex = "1"
rand = "0.8"
syn = { version = "2", features = ["full"] }
quote = "1"
proc-macro2 = "1"
rayon = "1"
chrono = "0.4"
uuid = { version = "1", features = ["v4"] }
ring = "0.17"
rustls = "0.23"
git2 = "0.19"
rusqlite = { version = "0.32", features = ["bundled"] }
image = "0.25"
prost = "0.13"
TOML
cargo fetch
python3 <path-to-repo>/test/corpus_scan.py
```

`corpus_scan.py` applies the exact fetch-and-execute gate the tool ships
(`SRC_FETCH` and `SRC_EXEC` from `scripts/lib.sh`, comments stripped first with
URL schemes preserved) to every unique crate version in the local cargo cache.

## Result (2026-08-30)

```
unique crate versions : 1810
  with a build script : 224
fetch+execute hits    : 0
```

Measured false-positive rate: **0%** (0 of 1810), while the tool still flags the
curl-based payload in `test/fixtures/dlmacro-1.0.0`.

## Typosquat rule

The same corpus, measured for name proximity:

```
unique crate names    : 1155
distance-1 name pairs : 21
```

Every one of the 21 was hand-checked and every one is a pair of **legitimate**
crates:

```
adler2/adler32   aes/anes       ahash/ghash      bit-vec/bitvec   dtoa/itoa
gif/gix          hyper/hypher   jiff/tiff        libc/libm        mime/time
paste/pastey     pem/psm        rand/rend        serde_json/serde_json5
sha1/sha2        tap/tar        termina/termini  toml_write/toml_writer
wasi/wasmi       xml_writer/xmlwriter             xml_writer/xmp-writer
```

So a rule that alarms on name proximity alone is **100% false positives** on real
trees, and `sha1` beside `sha2` or `libc` beside `libm` would fire in almost
every Rust project in existence. Name distance is not the signal.

The signal is the **asymmetry**. In the real incident `proc-macro1` was brand new
with no downloads while `proc-macro2`, the crate it shadowed, had been in the
tree for years with billions. So the shipped rule alarms only when the newcomer
is also young or barely downloaded. Checking all 39 crates in those 21 pairs
against crates.io:

| | youngest | fewest downloads |
|---|---|---|
| across all 39 | `termina`, 509 days | `xml_writer`, 369,664 |
| gate thresholds | 30 days | 10,000 |

**None of the 39 trips the gate**, with more than an order of magnitude of
margin on both axes. Measured false positives: **0 of 21 pairs**. An established
near-miss still renders as a `none`-tier note naming the crate it resembles, so
the information is never silently dropped.

## The audited-crate alarm (3.5.0)

`SRC_ALARM` decides whether a newly-added or changed `build.rs` on the audited
crate is `high` or `critical`. It was a raw grep, so a comment counted. Over the
same 224 build scripts:

```
SRC_ALARM matched raw            : 122
SRC_ALARM after comment-stripping:  99
matched ONLY through a comment   :  23
```

Those 23 are the entire `icu_*_data` family, `portable-atomic` and `radium`,
every one of them matching on a URL in a comment such as a link to a rust-lang
issue. They were being escalated to `critical` for documentation. The alarm now
reads code with comments stripped, so they land at `high`, which is still
flagged, just not as an implant.

## No source repository (3.5.0)

Sampled 120 real crate names at random from the corpus and asked crates.io
whether each declares a repository:

```
sampled           : 120   (120 resolved, 0 errors)
no repository     :   1   (serde_regex, 46,372,639 downloads)
```

So a missing repository is a genuinely rare tell, roughly 1%, but it does happen
to legitimate crates and the one that has it is enormous. Same gate as
everything else here: unattributable *and* new or unadopted alarms,
unattributable but established is a note. On this sample that is 0 alarms.

## Why the first cut was wrong

A first version treated any `http[s]?://` in a build script as a fetch. On this
same corpus it fired on **61** crates, including the most-downloaded crates in
the ecosystem:

```
anyhow, camino, crc32fast, libc, paste, proc-macro-hack, proc-macro2, quote,
rustversion, semver, serde, serde_core, thiserror, zerocopy, ...
```

Every hit was a URL sitting in a comment (a blog post, a GitHub issue, a license
header) or an error string (`panic!("file an issue at https://...")`), never a
real download. `proc-macro2`, `libc` and `serde` all shell out to rustc from
`build.rs` for feature detection, so an "any URL + any Command" rule fires on a
large fraction of every real tree. That is the rule being wrong, not the corpus.

The gate was re-defined so a fetch means a network **client or download tool is
actually invoked** (`reqwest`/`ureq`/`isahc`/`attohttpc`/`minreq`/`hyper`/`curl`/
`wget`/raw sockets), and comments are stripped before matching (the `//` in
`http://` is preserved so a genuine in-code fetch still counts). Re-measured on
the identical corpus, that takes the false-positive count from 61 to 0.
