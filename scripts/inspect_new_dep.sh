#!/usr/bin/env bash
# inspect_new_dep.sh — classify ONE dependency a bump newly pulled into the
# resolved tree.
#
# The 2026-08-20 arrayref attack is the shape this lane exists for: the bumped
# crate itself was byte-identical macro source plus ONE manifest line adding
# `proc-macro1 = "1.0.107"`, and the payload lived entirely in that new
# dependency's build script. The symbol lane sees no added symbols, the source
# lane sees no build script on the bumped crate, and until 3.4.0 the dependency
# lane printed `info proc-macro1` from a name grep. So: read the new
# dependency's actual source (cargo extracted it during the probe build), run
# the same compile-time inspection the audited crate gets (inspect_crate_dir in
# lib.sh), and weigh a fetch-and-execute build script against how established
# the crate is on crates.io.
#
# Tiers:
#   critical — build script matches SRC_FETCH and SRC_EXEC, and the crate is
#              young or barely downloaded (proc-macro1 was 0 days / 0 downloads)
#   medium   — same build script in an established, widely-downloaded crate
#   high     — proc-macro = true  (same tier inspect_source.sh assigns)
#   medium   — links = "..."      (same tier inspect_source.sh assigns)
#   none     — a build script with no fetch-and-execute tokens: a note carrying
#              the crate's age and downloads, never an alarm (proc-macro2, libc
#              and serde all invoke rustc from build.rs; that is normal)
#
# crates.io metadata (crate-level created_at + total downloads) goes through
# the provenance lane's path: fixture via RSA_CRATESIO_FIXTURE, else the API,
# cached per run in RSA_DEPMETA_CACHE and capped at RSA_DEPMETA_MAX network
# fetches, degrading to "unknown" offline. Missing metadata never invents a
# verdict: a fetch-and-execute script with unknown age degrades to medium.
#
# Usage: inspect_new_dep.sh <dep> <version> <out_dir>
#   Writes <out_dir>/newdep_findings.tsv  (<tier>\t<kind>\t<dep>\t<ver>\t<detail>)
#          <out_dir>/build_rs_excerpt.txt (when the build script tiers medium+)
# Env: RSA_CRATESIO_FIXTURE RSA_CHECK_PROVENANCE RSA_DEPMETA_CACHE
#      RSA_DEPMETA_MAX RSA_NEWDEP_YOUNG_DAYS RSA_NEWDEP_LOW_DOWNLOADS
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

export PYTHONUTF8=1

DEP="${1:?dependency name required}"
DEPV="${2:?dependency version required}"
OUTDIR="${3:?out dir required}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/newdep_findings.tsv"
: > "$TSV"
rm -f "$OUTDIR/build_rs_excerpt.txt"

YOUNG_DAYS="${RSA_NEWDEP_YOUNG_DAYS:-30}"
LOW_DOWNLOADS="${RSA_NEWDEP_LOW_DOWNLOADS:-10000}"
CACHE="${RSA_DEPMETA_CACHE:-$OUTDIR}"
mkdir -p "$CACHE"

add_finding() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$DEP" "$DEPV" "$3" >> "$TSV"; }

# --- source ----------------------------------------------------------------
SRC="$(crate_src_dir "$DEP" "$DEPV" || true)"
if [ -z "$SRC" ]; then
  # A probe that failed before extraction, or a path/git/workspace-member
  # dependency with no registry tarball. Skip with a visible reason, never a
  # silent pass.
  log "inspect_new_dep: no extracted source for $DEP@$DEPV — build script not inspected"
  add_finding none new-dep-not-inspected "no extracted source for \`$DEP\` $DEPV (path/git dependency, workspace member, or the probe failed before extraction) — its build script was not inspected"
  exit 0
fi

FACTS="$OUTDIR/facts.tsv"
inspect_crate_dir "$SRC" > "$FACTS"

# --- crates.io metadata (cached per run, capped, degrades offline) ---------
META="$CACHE/$DEP.json"
is_fixture_src=0
[ -n "${RSA_FIXTURES:-}" ] && case "$SRC" in "${RSA_FIXTURES}"/*) is_fixture_src=1;; esac
if [ ! -f "$META" ]; then
  if [ -n "${RSA_CRATESIO_FIXTURE:-}" ] && [ -f "${RSA_CRATESIO_FIXTURE}/${DEP}.json" ]; then
    cp "${RSA_CRATESIO_FIXTURE}/${DEP}.json" "$META"
  elif [ "$is_fixture_src" -eq 1 ]; then
    : # a fixture dep with no fixture metadata never hits the network
  elif [ "${RSA_CHECK_PROVENANCE:-1}" = "1" ] && command -v curl >/dev/null 2>&1; then
    fetched="$(find "$CACHE" -maxdepth 1 -name '*.json' 2>/dev/null | awk 'END{print NR+0}')"
    if [ "$fetched" -lt "${RSA_DEPMETA_MAX:-25}" ]; then
      curl -sS -m 20 -A "rust-symbol-audit (github action)" \
        "https://crates.io/api/v1/crates/${DEP}" -o "$META" 2>/dev/null || rm -f "$META"
      [ -s "$META" ] || rm -f "$META"
    else
      log "inspect_new_dep: crates.io fetch cap (${RSA_DEPMETA_MAX:-25}) reached — $DEP metadata not fetched"
    fi
  fi
fi

# AGE_SECS \t DOWNLOADS \t AGE_STR, any field "unknown" when unavailable.
read -r AGE_SECS DOWNLOADS HAS_REPO AGE_STR <<EOF2
$(PYTHONPATH="$HERE" python3 - "$META" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from agefmt import rel_age
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    data = {}
c = data.get("crate") or {}
secs = None
try:
    ts = datetime.fromisoformat(str(c.get("created_at")).replace("Z", "+00:00"))
    secs = (datetime.now(timezone.utc) - ts.astimezone(timezone.utc)).total_seconds()
except (TypeError, ValueError):
    pass
dl = c.get("downloads")
has_repo = "unknown" if not data else ("1" if c.get("repository") else "0")
print("%s\t%s\t%s\t%s" % (
    int(secs) if secs is not None else "unknown",
    dl if isinstance(dl, int) else "unknown",
    has_repo,
    rel_age(max(secs, 0)) if secs is not None else "unknown"))
PY
)
EOF2

young=0; low=0; meta_known=0
if [ "$AGE_SECS" != "unknown" ] && [ "$AGE_SECS" -lt $((YOUNG_DAYS * 86400)) ]; then young=1; fi
if [ "$DOWNLOADS" != "unknown" ] && [ "$DOWNLOADS" -lt "$LOW_DOWNLOADS" ]; then low=1; fi
[ "$AGE_SECS" != "unknown" ] && [ "$DOWNLOADS" != "unknown" ] && meta_known=1
if [ "$meta_known" -eq 1 ]; then
  CTX="(crate first published $AGE_STR, $DOWNLOADS total downloads)"
else
  CTX="(crate age and downloads unknown — crates.io metadata unavailable)"
fi

# --- classify --------------------------------------------------------------
BS="$(fact build_script "$FACTS")"
if [ -n "$BS" ]; then
  if [ "$(fact readable "$FACTS")" != "1" ]; then
    add_finding none new-dep-build-script-unreadable "\`$DEP\` $DEPV $CTX ships a build script that could not be read — not classified; treat as unreviewed compile-time code"
  elif [ "$(fact fetch_exec "$FACTS")" = "1" ]; then
    if [ "$young" -eq 1 ] || [ "$low" -eq 1 ]; then
      add_finding critical new-dep-build-script "new dependency \`$DEP\` $DEPV $CTX ships a build script that downloads and executes a remote payload — the shape of the 2026-08-20 arrayref/proc-macro1 attack"
    elif [ "$meta_known" -eq 1 ]; then
      add_finding medium new-dep-build-script "new dependency \`$DEP\` $DEPV ships a build script that references remote fetch and execution; \`$DEP\` is established $CTX, so this is more likely vendored build tooling than an implant — review the excerpt"
    else
      add_finding medium new-dep-build-script "new dependency \`$DEP\` $DEPV ships a build script that references remote fetch and execution; crates.io metadata is unavailable so its age and adoption could not be checked — review the excerpt"
    fi
    { printf '# build script of %s %s (%s), first 40 lines:\n' "$DEP" "$DEPV" "$(basename "$BS")"
      sed -n '1,40p' "$BS"; } > "$OUTDIR/build_rs_excerpt.txt" 2>/dev/null || true
  else
    add_finding none new-dep-build-script "\`$DEP\` $DEPV $CTX ships a build script with no remote-fetch-and-execute tokens — normal for -sys and version-probing crates"
  fi
fi

# --- no source repository --------------------------------------------------
# The provenance lane makes this a finding for the AUDITED crate but never saw
# a new dependency. Measured over a 120-crate random sample of real names, only
# one lacked a repository (serde_regex, 46M downloads), so it is a rare and
# useful tell, but it does happen to legitimate crates. Gated on the same
# asymmetry as everything else here: unattributable AND new/unadopted alarms,
# unattributable but established is a note.
if [ "$HAS_REPO" = "0" ]; then
  if [ "$young" -eq 1 ] || [ "$low" -eq 1 ]; then
    add_finding high new-dep-no-source-repo "new dependency \`$DEP\` $DEPV $CTX declares NO source repository on crates.io, so the published code cannot be traced back to a git source"
  else
    add_finding none new-dep-no-source-repo "\`$DEP\` $DEPV declares no source repository on crates.io, but it is established $CTX — not flagged"
  fi
fi

# --- typosquat -------------------------------------------------------------
# RustSec filed the 2026-08-20 incident as "via typosquatted proc-macro1", and
# proc-macro2 was already in the victim's tree. Name proximity ALONE is useless:
# measured across 1162 real crate names, every distance-1 pair was a legitimate
# one (sha1/sha2, libc/libm, mime/time, hyper/hypher). What separates a squat is
# the asymmetry -- the near-miss is brand new and barely downloaded while the
# crate it shadows is one you already depend on. So this only alarms when the
# youth/adoption gate also trips; otherwise it is a note.
if [ -n "${RSA_TREE_NAMES:-}" ] && [ -f "${RSA_TREE_NAMES}" ] && [ "${RSA_TYPOSQUAT_DISTANCE:-1}" != "0" ]; then
  if SQUAT="$(python3 "$HERE/typosquat.py" "$DEP" "$RSA_TREE_NAMES" "${RSA_TYPOSQUAT_DISTANCE:-1}")"; then
    SQ_DIST="${SQUAT%%	*}"; SQ_NEAR="${SQUAT#*	}"
    if [ "$young" -eq 1 ] || [ "$low" -eq 1 ]; then
      if [ "$(fact fetch_exec "$FACTS")" = "1" ]; then
        add_finding critical new-dep-typosquat "new dependency \`$DEP\` $DEPV $CTX is $SQ_DIST character from \`$SQ_NEAR\`, which your tree already depends on, AND ships a build script that downloads and executes a remote payload — this is the arrayref/proc-macro1 pattern exactly"
      else
        add_finding high new-dep-typosquat "new dependency \`$DEP\` $DEPV $CTX is $SQ_DIST character from \`$SQ_NEAR\`, which your tree already depends on — a brand-new near-miss of a crate you already use is how the 2026-08-20 proc-macro1 typosquat entered trees; confirm you meant to add this one"
      fi
    elif [ "$meta_known" -eq 1 ]; then
      add_finding none new-dep-typosquat "\`$DEP\` $DEPV is $SQ_DIST character from \`$SQ_NEAR\` in your tree, but it is established $CTX — not flagged (legitimate near-misses like sha1/sha2 and libc/libm are common)"
    else
      add_finding none new-dep-typosquat "\`$DEP\` $DEPV is $SQ_DIST character from \`$SQ_NEAR\` in your tree; crates.io metadata is unavailable so its age and adoption could not be checked"
    fi
  fi
fi

if [ "$(fact proc_macro "$FACTS")" = "1" ]; then
  add_finding high new-dep-proc-macro "new dependency \`$DEP\` $DEPV $CTX is a proc-macro — it executes code inside the compiler when your project builds"
fi

LINKS="$(fact links "$FACTS")"
if [ -n "$LINKS" ]; then
  add_finding medium new-dep-native-link "new dependency \`$DEP\` $DEPV links a native library ($LINKS) — pulls non-Rust code into the build"
fi

overall="$(max_tier "$TSV")"
log "inspect_new_dep: $DEP@$DEPV tier=$overall findings=$(count_lines "$TSV") age=${AGE_STR} downloads=${DOWNLOADS}"
