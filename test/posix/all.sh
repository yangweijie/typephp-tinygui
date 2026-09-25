#!/usr/bin/env bash
# all.sh — run the entire POSIX verification kit and write one evidence log.
#
# The kit has grown to five entry points, and assembling them by hand (with the
# right env vars, in the right order, into one file) is exactly the sort of thing
# that silently drifts. This script is the single reproducible command:
#
#   [0] host_probe      — do the primitives this branch needs even exist here?
#   [1] run.sh          — tier 1: AF_UNIX endpoint, pump, teardown (mock backend)
#   [2] tier2.sh        — tier 2: same, with a REAL PHP backend (backend.php)
#   [3] launch-mode.sh  — the packaged entry: <exe_stem>.conf, launcher argv, orphans
#   [4] stderr-channel.sh — stdout/stderr isolation, with a positive control
#
# Tiers 3 and 4 need a real `launcher-linux` build (GTK/WebKit) — tier 3 here is
# the *packaged entry* path, not a GUI run. See README.md for the tier table.
#
# Usage:  ./all.sh          # -> posix-test/cygwin-all.log (or <host>-all.log)
#         LOG=... ./all.sh
# Exit:   0 = every tier green, 1 = at least one failure, 2 = missing toolchain.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/resolve-root.sh"
typephp_locate "$HERE"

case "$(uname -s)" in
  Linux | Darwin | CYGWIN*) ;;
  *)
    echo "The POSIX kit needs a POSIX host (Linux/macOS/Cygwin); this is $(uname -s)."
    exit 2 ;;
esac

# Evidence lands in the repo's evidence/kit/ when the kit runs in-tree, so the
# kit directory itself stays clean -- it is synced verbatim into a skill asset,
# and a stray host log there would be shipped by accident. Standalone runs (no
# composer.json above us) write next to the kit, as before.
LOG_DIR="$HERE"
if [ -n "$TP_ROOT" ]; then LOG_DIR="$TP_ROOT/evidence/kit"; mkdir -p "$LOG_DIR"; fi
case "$(uname -s)" in
  Linux)  DEFAULT_LOG="$LOG_DIR/linux-all.log" ;;
  Darwin) DEFAULT_LOG="$LOG_DIR/macos-all.log" ;;
  *)      DEFAULT_LOG="$LOG_DIR/cygwin-all.log" ;;
esac
LOG="${LOG:-$DEFAULT_LOG}"
WORK="${WORK:-$HERE/.work}"

log() { printf '%s\n' "$*"; }

{
  log "### POSIX-branch verification evidence — full kit"
  log "### generated $(date -u +%Y-%m-%dT%H:%M:%SZ)  host=$(uname -s) $(uname -r)"
  log "### backend_shell.cpp sha256: $(sha256sum "$TP_SHIM_SRC" | cut -d' ' -f1)"
  log "### g++: $(g++ --version 2>/dev/null | head -1)"
  log "### fixture oracle: $(command -v python3) $("$(command -v python3)" -V 2>&1)"
  log "### PHP: $(command -v php || echo '(none on PATH)')"
  log

  log "########## [0] host primitive probe ##########"
  if gcc -O2 -Wall -Wextra -o "$WORK/host_probe" "$HERE/host_probe.c" 2>&1 \
     && "$WORK/host_probe"; then :; fi
  echo "PROBE_RC=$?"

  log; log "########## [1] TIER 1: mock backend ##########"
  bash "$HERE/run.sh"; echo "TIER1_RC=$?"

  log; log "########## [2] TIER 2: real PHP backend ##########"
  bash "$HERE/tier2.sh"; echo "TIER2_RC=$?"

  log; log "########## [3] LAUNCH MODE: packaged entry ##########"
  bash "$HERE/launch-mode.sh"; echo "LAUNCH_RC=$?"

  log; log "########## [4] STDERR CHANNEL ISOLATION ##########"
  bash "$HERE/stderr-channel.sh"; echo "STDERR_RC=$?"
} >"$LOG" 2>&1

echo "wrote $LOG"
echo
grep -E "^(RESULT|TIER[0-9]_RC|LAUNCH_RC|STDERR_RC|PROBE_RC)|OK$|ALL PRIMITIVES" "$LOG" \
  | sed 's/^/  /'

# Exit 1 from a tier is a real failure; exit 2 means "missing toolchain" (a tier
# skipped itself, e.g. no PHP >= 8.0), which is worth shouting about but is not a
# verification failure. Exit 0 is green.
if grep -qE '^RESULT: .* [1-9][0-9]* failed' "$LOG" \
   || grep -qE '^(TIER[0-9]|LAUNCH|STDERR|PROBE)_RC=1' "$LOG"; then
  echo; echo "SOME TIERS FAILED — see $LOG"
  exit 1
fi
if grep -qE '^(TIER[0-9]|LAUNCH|STDERR|PROBE)_RC=2' "$LOG"; then
  echo; echo "ALL RUNNABLE TIERS OK, but at least one tier skipped itself"
  echo "(exit 2 = missing toolchain). Grep RC=2 in $LOG for the reason."
  exit 0
fi
echo; echo "ALL TIERS OK"
