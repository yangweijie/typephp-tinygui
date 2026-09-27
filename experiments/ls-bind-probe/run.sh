#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 26a discriminator for bug #21 ("LaunchServices-launched app hangs in bind()
# on the repo volume").
#
# Builds probe.c into a minimal .app twice — once on the boot volume (/tmp),
# once on the external HFS+ repo volume — and runs each copy two ways:
#
#   direct   exec the binary from the shell
#   ls       `open` it, i.e. let LaunchServices spawn it
#
# Every step the probe takes is appended to /tmp/ls-bind-probe.log with a
# "> [n] begin" line BEFORE the syscall, so a missing "ok" line names the step
# that never returned. The probe also logs its own realpath, which is how App
# Translocation gets detected (a translocated launch shows an
# /…/AppTranslocation/… path instead of the bundle we opened).
#
# When a step does hang, the driver grabs `sample <pid>` (user-space stack, no
# root) and dumps the system log lines TCC / sandbox wrote about that process.
#
#   usage: bash experiments/ls-bind-probe/run.sh [wait_seconds]
#
# Nothing here touches shim/ or the demo bundle: if the probe hangs, the fault
# is in the launch context, not in our code.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WAIT="${1:-12}"
LOG=/tmp/ls-bind-probe.log
OUT="$HERE/out"
BOOT_DIR="/tmp/ls-bind-probe-boot"
VOL_DIR="$OUT/vol"

APP="ProbeLsBind.app"
BIN="Contents/MacOS/ProbeLsBind"
EXENAME="ProbeLsBind"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

build_at() {
  local base="$1"
  rm -rf "$base/$APP"
  mkdir -p "$base/$APP/Contents/MacOS" || return 1
  cc -O0 -Wall -Wextra -o "$base/$APP/$BIN" "$HERE/probe.c" || return 1
  cat > "$base/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ProbeLsBind</string>
  <key>CFBundleIdentifier</key><string>cn.think.bot.probe.lsbind</string>
  <key>CFBundleName</key><string>ProbeLsBind</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  # Ad-hoc signature only — this machine has no Developer ID identity (0
  # valid identities), and the earlier lesson was that re-signing a bundle
  # pollutes later comparisons, so both copies get the same treatment.
  codesign --force --sign - "$base/$APP" >/dev/null 2>&1
  [ -x "$base/$APP/$BIN" ]
}

pidof_probe() { pgrep -x "$EXENAME" 2>/dev/null | head -1; }

# Run `open`, give it WAIT seconds. rc=0 finished, rc=2 hung (sampled+ killed).
run_ls() {
  local base="$1" tag="$2"
  rm -f "$OUT/sample-$tag.txt" "$OUT/ps-$tag.txt"
  open -n "$base/$APP" --args "$tag" || { echo "  open rc=$?"; return 1; }
  local waited=0 pid=""
  while [ "$waited" -lt "$((WAIT * 10))" ]; do
    pid=$(pidof_probe)
    [ -z "$pid" ] && { sleep 0.1; waited=$((waited + 1)); continue; }
    if ! ps -p "$pid" >/dev/null 2>&1; then break; fi
    # If the process already logged "== <tag> done", it is finishing; stop early.
    if grep -q "^\> .*== $tag done" "$LOG" 2>/dev/null; then break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 0.3
  pid=$(pidof_probe)
  if [ -z "$pid" ]; then
    grep -q "^\> .*== $tag done" "$LOG" 2>/dev/null && { echo "  finished"; return 0; }
    echo "  NO PROCESS AND NO '== $tag done' LINE — check for a launch failure"
    return 3
  fi
  echo "  HANG: pid=$pid still alive after ${WAIT}s"
  ps -o pid,ppid,stat,etime,command -p "$pid" > "$OUT/ps-$tag.txt" 2>&1
  sed 's/^/     /' "$OUT/ps-$tag.txt"
  sample "$pid" 1 -f "$OUT/sample-$tag.txt" >/dev/null 2>&1 || echo "     sample rc=$?"
  grep -A3 -m1 -E '__bind|bind' "$OUT/sample-$tag.txt" 2>/dev/null | sed 's/^/     /'
  kill -9 "$pid" 2>/dev/null
  return 2
}

mkdir -p "$OUT" || die "cannot mkdir $OUT"
: > "$LOG"

printf '== volumes\n'
mount | grep -E ' on / \(| on /Volumes/data ' | sed 's/^/   /'

printf '\n== building the probe\n'
mkdir -p "$BOOT_DIR" "$VOL_DIR" || die "cannot stage build dirs"
build_at "$BOOT_DIR" || die "build on boot volume ($BOOT_DIR) failed"
build_at "$VOL_DIR"  || die "build on external volume ($VOL_DIR) failed"
[ -d /Volumes/data ] || die "/Volumes/data is not mounted"
printf '   boot  : %s/%s\n' "$BOOT_DIR" "$APP"
printf '   volume: %s/%s\n\n' "$VOL_DIR" "$APP"

printf '== C1 direct exec, bundle on the volume\n'
"$VOL_DIR/$APP/$BIN" direct-on-volume; echo "  rc=$?"

printf '\n== C2 direct exec, bundle on the boot volume\n'
"$BOOT_DIR/$APP/$BIN" direct-on-boot; echo "  rc=$?"

printf '\n== A `open` on the boot volume (known-good LaunchServices control)\n'
run_ls "$BOOT_DIR" ls-on-boot; echo "  rc=$?"

printf '\n== B `open` on the volume (the #21 repro)\n'
run_ls "$VOL_DIR" ls-on-volume; echo "  rc=$?"

printf '\n== probe log (%s)\n' "$LOG"
[ -s "$LOG" ] && sed 's/^/   /' "$LOG" || echo '   (empty)'

printf '\n== what the security layer said about ProbeLsBind\n'
log show --style compact --last 3m \
    --predicate 'process == "ProbeLsBind" OR (subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c] "ProbeLsBind") OR (eventMessage CONTAINS[c] "ProbeLsBind")' \
    2>/dev/null | grep -vE '^Timestamp|^$' | tail -25 | sed 's/^/   /'
printf '   (empty above = the unified log holds nothing about the probe)\n'

printf '\n== verdict\n'
printf '   steps: [1] regular file in exe_dir   [2] AF_UNIX bind in exe_dir   [3] AF_UNIX bind in /tmp\n'
for t in direct-on-volume direct-on-boot ls-on-boot ls-on-volume; do
  block=$(grep -F " $t " "$LOG" 2>/dev/null || true)
  b=$(printf '%s\n' "$block" | grep -cE '\[[123]\] begin' || true)
  o=$(printf '%s\n' "$block" | grep -cE '\[[123]\] (ok|not ok|failed errno)' || true)
  st=$(printf '%s\n' "$block" | grep -oE '\[[123]\] (ok|not ok|failed errno[^ ]*)' | tr '\n' ' ')
  verdict=INCOMPLETE
  if [ "$b" = 3 ] && [ "$o" = 3 ] && printf '%s\n' "$block" | grep -q "done"; then verdict=COMPLETE; fi
  printf '   %-16s begin=%s settled=%s %-9s %s\n' "$t" "$b" "$o" "$verdict" "${st:-<no step settled>}"
  [ "$verdict" = COMPLETE ] || \
    printf '%s\n' "$block" | grep -E '\[[123]\] begin' | tail -1 | \
      sed 's/^/                    stuck at: /'
done
