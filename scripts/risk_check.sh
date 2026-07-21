#!/usr/bin/env bash
# risk_check.sh — Step 4
#
# Read a list of added (demangled) symbols and assign each a risk tier by
# pattern-matching against known-sensitive capabilities. Writes a TSV
# (<tier>\t<symbol>) and a JSON summary {"tier": <overall>, "matches": [...]}.
#
# Tiers (checked in this precedence; first match wins):
#   critical — process spawn/exec, raw sockets, syscalls / FFI, mem-injection
#   high     — filesystem, env, secret-ish identifiers, clipboard / input-device
#              (keylogging) / screen-camera-mic capture
#   medium   — higher-level networking (http/tls/dns), socket addressing
#
# Usage: risk_check.sh <added_syms_file> [out_dir]
#   Prints the JSON summary on stdout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

IN="${1:-${WORK:-/tmp/rsa}/added_syms.txt}"
OUTDIR="${2:-${WORK:-/tmp/rsa}}"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/risk.tsv"
JSON="$OUTDIR/risk.json"
: > "$TSV"

# Concrete, portable tokens (type/function names survive across platforms; bare
# words like "sys"/"net" are avoided because std routes almost everything through
# std::sys internally and would flag every symbol).
CRIT='Command>|::exec|execv|execvp|thread::spawn|::spawn|process::exit|process::abort|TcpStream|TcpListener|UdpSocket|::syscall|libc::|::ptrace|CreateProcess|CreateRemoteThread|VirtualAllocEx|WriteProcessMemory|LoadLibrary|dlopen|mmap|mprotect'
HIGH='::fs::|std::fs|File>|OpenOptions|read_to_string|write_all|::remove_file|remove_dir|create_dir|::env::var|env::set_var|::set_var|remove_var|home_dir|temp_dir|::token|secret|password|passwd|credential|private_key|api[_-]?key|::ssh|keychain|arboard|copypasta|clipboard::|Clipboard>|rdev::|enigo::|device_query|GetAsyncKeyState|SetWindowsHookEx|scrap::|xcap::|nokhwa|screenshots::|::Capturer|cpal::'
MED='::net::|SocketAddr|to_socket_addrs|lookup_host|::http|https|::tls|rustls|reqwest|hyper|openssl|native_tls|webpki|ureq|::dns|resolve|Url>|url::Url'

overall="none"
if [ -f "$IN" ]; then
  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    tier=""
    if printf '%s' "$sym" | grep -qE "$CRIT"; then
      tier="critical"
    elif printf '%s' "$sym" | grep -qiE "$HIGH"; then
      tier="high"
    elif printf '%s' "$sym" | grep -qiE "$MED"; then
      tier="medium"
    else
      continue
    fi
    printf '%s\t%s\n' "$tier" "$sym" >> "$TSV"
    if [ "$(tier_rank "$tier")" -gt "$(tier_rank "$overall")" ]; then
      overall="$tier"
    fi
  done < "$IN"
fi

# Serialize to JSON safely (symbols contain <, >, &, spaces — never trust manual
# quoting). python3 is present on ubuntu-latest and on this dev box.
OVERALL="$overall" python3 - "$TSV" > "$JSON" <<'PY'
import json, os, sys
tsv = sys.argv[1]
matches = []
try:
    with open(tsv, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            tier, _, sym = line.partition("\t")
            matches.append({"tier": tier, "symbol": sym})
except FileNotFoundError:
    pass
print(json.dumps({"tier": os.environ.get("OVERALL", "none"), "matches": matches},
                 ensure_ascii=False))
PY

log "risk: overall=$overall matches=$(wc -l < "$TSV" | tr -d ' ')"
cat "$JSON"
