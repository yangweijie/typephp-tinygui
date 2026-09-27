#!/usr/bin/env bash
# ===========================================================================
# Phase 21e evidence collector.
#
# `bash test/win/dev-bounce.sh` writes its run artifacts to $WORK (default
# /tmp/tpgui-21e) — on Git Bash that is %LOCALAPPDATA%\Temp, i.e. a directory
# that dies with the box. Every other platform acceptance in this repo has its
#现场 checked into `evidence/<os>/` (21b -> evidence/mac/dev-21b.log, 22c/22d ->
# evidence/linux/*), so README's Windows row currently has prose but no stored
# evidence. This script copies the driver's artifacts into evidence/win/ AND
# derives a self-describing manifest, so the evidence can be re-checked without
# re-running anything:
#
#   * per-cycle CALL/RET counts and the named pipe, split on the shim's
#     `[shell] transport=` headers (same log discipline as the driver);
#   * launcher/shim/app process counts from each tasklist dump;
#   * sha256 + byte size for every stored file, plus the host string and the
#     git commit the run was made against.
#
# usage (on the box that ran the driver):
#   bash test/win/collect-evidence.sh            # $WORK=/tmp/tpgui-21e -> evidence/win/
#   WORK=/some/other/dir bash test/win/collect-evidence.sh
#   OUT=/tmp/dryrun bash test/win/collect-evidence.sh   # dry run, touch nothing in the repo
# then:  git add evidence/win && git commit && git push
# ===========================================================================
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/tpgui-21e}"
# OUT is overridable so the collector itself can be exercised against a scratch
# directory — the real repo path is only for the run that files genuine evidence.
OUT="${OUT:-$ROOT/evidence/win}"

REGEN="${REGEN:-0}"

need() { [ -f "$WORK/$1" ] || { echo "!! $WORK/$1 missing — the driver did not finish, refusing to file partial evidence"; exit 2; }; }

if [ "$REGEN" = 1 ]; then
  # Re-derive the manifest from files ALREADY filed in $OUT. Used when the parser
  # itself is fixed after a run was filed: the provenance header (host, repo rev,
  # collection time) is kept verbatim, because it describes the machine where the
  # driver actually ran — a later machine must not overwrite it with its own.
  [ -f "$OUT/21e-shim.log" ] || { echo "!! REGEN=1 needs $OUT/21e-shim.log"; exit 2; }
  HDR="$OUT/.21e-header"
  awk '/^#/{print; next} {exit}' "$OUT/21e-MANIFEST.txt" > "$HDR" 2>/dev/null || : > "$HDR"
  COPIED=""
  for f in $(cd "$OUT" && ls 21e-* 2>/dev/null | grep -v 'MANIFEST'); do COPIED="$COPIED $f"; done
  [ -n "$COPIED" ] || { echo "!! REGEN=1 found no 21e-* files in $OUT"; exit 2; }
else
  [ -d "$WORK" ] || { echo "!! no evidence dir at $WORK — run test/win/dev-bounce.sh first (or pass WORK=...)"; exit 2; }
  need shim.log
  need tgui.out
  for f in tasklist.before.txt tasklist.after-cycle2.txt tasklist.teardown.txt; do need "$f"; done
  mkdir -p "$OUT"
  # --- copy: stable 21e- prefix so the files are unreadable without context ----
  # cli.pid / shot.ps1 stay behind: a stale pid is noise, and the ps1 is generated.
  COPIED=""
  for f in shim.log tgui.out tasklist.before.txt tasklist.after-cycle2.txt \
           tasklist.teardown.txt shot.png shim-build.log; do
    [ -f "$WORK/$f" ] || continue
    cp -f "$WORK/$f" "$OUT/21e-$f" && COPIED="$COPIED 21e-$f"
  done
  [ -n "$COPIED" ] || { echo "!! nothing copied"; exit 2; }
fi

# sha256 differs between Git Bash (sha256sum) and macOS (shasum -a 256).
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# --- derive: same cycle splitters the driver uses ---------------------------
# cycles / per-cycle CALL / RET / marker / pipe
cycle_counts() {
  awk '
    /^\[shell\] transport=/ { n++; pipe[n]=""; if (match($0, /pipe=[^ ]+/)) { pipe[n]=substr($0, RSTART+5, RLENGTH-5) }
                              next }
    n > 0 {
      if (index($0, "L->P: CALL")) c[n]++
      if (index($0, "P->L: RET"))  r[n]++
      if (index($0, "WINDOW-E2E OK ping=pong")) e[n]++
    }
    END { if (n == 0) { print "   !! no [shell] transport= header — this log has no dev cycle in it"; exit }
          for (i = 1; i <= n; i++) {
            printf "   cycle %d: pipe=%s  CALL=%d RET=%d WINDOW-E2E-lines=%d\n",
                   i, pipe[i], c[i] + 0, r[i] + 0, e[i] + 0
            printf "            (WINDOW-E2E counts 2 per cycle: the CALL frame + the backend stderr echo)\n"
          } }' "$OUT/21e-shim.log"
}
# rows_for <file> <image-name> -> matching row count. The driver's win_rows() emits
# `name pid` (it strips tasklist's CSV quotes with `tr -d '"'`), but a plain CSV dump
# `"name","pid",...` is matched too, so the parser cannot silently read 0 for a
# non-empty dump just because the quoting changed.
rows_for() {
  awk -v n="$2" '
    { line = $0; gsub(/"/, "", line); sub(/[,].*$/, "", line); split(line, a, /[ \t]+/);
      if (tolower(a[1]) == tolower(n)) c++ }
    END { printf "%d", c + 0 }' "$1"
}
proc_counts() {
  local file="$1" l s a tot
  l=$(rows_for "$file" launcher-win.exe); s=$(rows_for "$file" backend.exe); a=$(rows_for "$file" app.exe)
  tot=$(grep -c '[^[:space:]]' "$file" 2>/dev/null || true)
  # A non-empty dump whose rows match NONE of the three names is a format drift,
  # not zero processes. Saying 0/0/0 there would file a confident lie — which is
  # exactly what the first version of this parser did (it assumed CSV quoting while
  # win_rows() strips the quotes, so the real 1/1/1 leaked in as 0/0/0).
  if [ "${tot:-0}" -gt 0 ] && [ "$((l + s + a))" = 0 ]; then
    printf 'UNPARSED: %s non-empty line(s) matched none of the 3 names' "$tot"; return
  fi
  printf 'launcher=%s shim=%s app=%s' "$l" "$s" "$a"
}

MAN="$OUT/21e-MANIFEST.txt"
{
  if [ "$REGEN" = 1 ]; then
    # Keep the original provenance (the Windows box's host string, its repo rev,
    # the collection timestamp) and stamp on top of it what was recomputed where.
    cat "$HDR"
    echo "# re-derived: $(date -u '+%Y-%m-%dT%H:%M:%SZ') by test/win/collect-evidence.sh REGEN=1"
    echo "#             on $(uname -srm), repo rev $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown);"
    echo "#             the derived blocks below come from the stored 21e-* files, not from $WORK."
  else
    echo "# Phase 21e — Windows real-desktop dev-bounce evidence (no Xvfb involved)"
    echo "# collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ') by test/win/collect-evidence.sh"
    echo "# source:    $WORK (Git Bash %LOCALAPPDATA%\\Temp — transient, hence this copy)"
    echo "# host:      $(uname -a)"
    echo "# repo rev:  $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "# driver:    bash test/win/dev-bounce.sh  ->  expected final line:"
    echo "#              == 21e windows dev driver: PASS"
  fi
  echo
  echo "== frame cycles found in 21e-shim.log (split on '[shell] transport=')"
  cycle_counts
  echo
  echo
  echo "== WINDOW-E2E marker timings, in cycle order (README quotes these numbers)"
  grep -o 'WINDOW-E2E OK ping=pong in [0-9]*ms' "$OUT/21e-shim.log" | awk '
    !seen[$0]++ { printf "   %s\n", $0 }' 
  echo "   (each cycle logs the marker twice: the CALL frame and the backend stderr echo)"
  echo
  echo "== named pipes across cycles (each bounce must get a fresh one)"
  NP=$(grep -c '^\[shell\] transport=' "$OUT/21e-shim.log" 2>/dev/null)
  UP=$(grep -o 'pipe=[^ ]*' "$OUT/21e-shim.log" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  printf '   cycles=%s distinct-pipes=%s  %s\n' "${NP:-0}" "$UP" \
    "$([ "${NP:-0}" -gt 0 ] && [ "$NP" = "$UP" ] && echo 'OK: every cycle re-handshook on its own pipe' \
        || echo 'MISMATCH: a pipe was reused or none was logged — the bounce did not re-handshake')"
  echo
  echo "== process counts per tasklist dump (the 1/1/1 leak assertion)"
  for f in tasklist.before.txt tasklist.after-cycle2.txt tasklist.teardown.txt; do
    [ -f "$OUT/21e-$f" ] && printf '   %-28s %s\n' "$f" "$(proc_counts "$OUT/21e-$f")"
  done
  echo "   (before = cycle 1 up; after-cycle2 = two bounces in; teardown = window closed, all three 0)"
  echo
  echo "== CLI-side bounce evidence (21e-tgui.out)"
  grep -c 'sources changed' "$OUT/21e-tgui.out" 2>/dev/null | sed 's/^/   "sources changed" lines: /'
  echo
  echo "== stored files (sha256, bytes)"
  for f in $COPIED; do
    printf '   %s  %s  %sB\n' "$(digest "$OUT/$f")" "$f" "$(wc -c < "$OUT/$f" | tr -d ' ')"
  done
} > "$MAN"
[ "$REGEN" = 1 ] && rm -f "$HDR"

VERB=collected; [ "$REGEN" = 1 ] && VERB=re-derived
echo "== $VERB into $OUT"
for f in $COPIED; do printf '   %-32s %sB\n' "$f" "$(wc -c < "$OUT/$f" | tr -d ' ')"; done
printf '   %-32s %sB\n' "21e-MANIFEST.txt" "$(wc -c < "$MAN" | tr -d ' ')"
echo
echo "   read back with:  cat $MAN"
echo "   then file it:    git add \"$OUT\" && git commit -m 'evidence(win): Phase 21e dev-bounce 真机现场'"
