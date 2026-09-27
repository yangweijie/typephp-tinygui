#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# macOS packaged-direction acceptance: does the shipped .app actually LAUNCH
# when LaunchServices spawns it from a volume that is not the boot volume?
#
# Why this file exists (bug #21)
# -----------------------------
# Phase 21c closed the mac bundle direction with a caveat: `open`-ing the .app
# from the repo volume hung forever, sample showed 787/787 stacks in `__bind`,
# and the note said "environment limitation, run acceptance two ways". It is an
# environment rule — but one the shim can obey. `experiments/ls-bind-probe`
# measured WHY: the first NEW FILE a LaunchServices-spawned process creates on a
# non-boot volume blocks in `open(O_CREAT)` until macOS answers
# kTCCServiceSystemPolicyRemovableVolumes, and that answer can stay pending
# forever (plain file, not socket — `__bind` was just where the shim wrote
# first). The shim now puts the packaged endpoint in the per-user temp dir when
# the app dir is off the boot volume (shim/backend_shell.cpp), so a .app on an
# external volume launches without asking the user for volume access.
#
# What it asserts
# --------------
#   A1 cold start: nothing of ours is already running, no stale endpoint
#   A2 the LaunchServices launch REACHES the frame channel (`launcher connected`)
#      — this single line is the #21 regression guard
#   A3 where the endpoint really is, and that the bundle dir stayed untouched
#   A4 frame balance (CALL == RET) + the demo's `WINDOW-E2E OK` marker
#   A4b optional pixel proof: `SHOT=<path.png>` photographs the live window
#       (tools/mac-winlist for the window number, then screencapture -l<id>,
#       falling back to that window's rect when -l refuses).
#       Reports SKIP, never FAIL — it needs the Screen Recording grant.
#   A5 closing the window (kill the launcher) tears the tree down and unlinks
#   A6 the direct-exec path still works (the fix must not break what worked)
#   B  optional NEGATIVE CONTROL: `CTL_SHIM=<pre-fix binary> bash this-script`
#      re-runs A2's launch with the old selection rule under its OWN bundle
#      identifier ($CTL_ID) and requires the hang (no `launcher connected`) plus
#      an `__bind`/`__open` sample. Two things make it honest:
#      - a fresh identifier, because the block is per-identifier TCC consent:
#        an identifier whose request has been answered stops blocking from then
#        on. Observed on this machine: the same pre-fix binary hung in an
#        earlier run today and connected at 19:40 under
#        com.typephp.TypePHPDemo, while a never-answered id still hung at 19:39.
#        The consent table itself is not readable from here (TCC.db needs Full
#        Disk Access), so the control gets its own id and, if it still connects,
#        reports SKIP with the `tccutil reset` recipe instead of pretending to
#        be a FAIL.
#      - a deterministic decision-shape assertion that holds either way: the
#        pre-fix log must name the in-bundle endpoint and must NOT contain the
#        relocation line the fixed shim writes.
#      Without CTL_SHIM the section says SKIP — it is only meaningful against a
#      binary from before the fix. The underlying mechanism is reproduced
#      independently, on demand, by experiments/ls-bind-probe/run.sh.
#
# usage:  bash test/posix/macos-bundle-launch.sh
#           BUNDLE=<path.app>      default demo/dist/TypePHP-Demo.app
#           CTL_SHIM=<path>        optional pre-fix shim for section B
#           CTL_ID=<bundle id>     identifier for the control bundle,
#                                  default com.typephp.macbundle.pre26fix
#           SHOT=<path.png>        optional window screenshot (section A4b)
#           WINLIST=<helper>       default tools/mac-winlist
#           WAIT=<seconds>         per-launch budget, default 20
#           WORK=<dir>             artifacts, default $TMPDIR/typephp-mac-launch
#                                  (must be on the boot volume — see below)
# Exit: 0 all assertions passed (SKIPs allowed, they are printed), 1 any FAIL.
# needs a real GUI session: this drives LaunchServices, so it is a Mac-desktop
# test, not a container/CI test.
#
# WORK MUST SIT ON THE BOOT VOLUME. The shim opens TYPEPHP_SHELL_LOG as its
# first file operation, and the driver writes report files there too; on a
# LaunchServices-launched process that is exactly the open(O_CREAT) that TCC
# holds forever on a non-boot volume (bug #21). The first version of this
# script defaulted WORK to <repo>/build and every section "failed" because the
# app never got as far as writing a log line.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="${BUNDLE:-$ROOT/demo/dist/TypePHP-Demo.app}"
CTL_SHIM="${CTL_SHIM:-}"
# The control bundle gets its own identifier: TCC consent is keyed by identifier,
# so reusing the demo's would silently inherit an answer given earlier.
CTL_ID="${CTL_ID:-com.typephp.macbundle.pre26fix}"
# Optional pixel proof (section A4b): a path to write the window screenshot to.
SHOT="${SHOT:-}"
WAIT="${WAIT:-20}"
WORK="${WORK:-${TMPDIR:-/tmp}/typephp-mac-launch}"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $*"; fail=$((fail + 1)); }
sk()   { echo "  skip $*"; skip=$((skip + 1)); }
sect() { echo; echo "== $*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "macOS only (this drives LaunchServices)"
[ -d "$BUNDLE/Contents/MacOS" ] || die "no bundle at $BUNDLE — run: (cd demo && bash ../gui/bin/tgui build)"
MACOS="$BUNDLE/Contents/MacOS"
ENTRY="$MACOS/App"
[ -x "$ENTRY" ] || die "bundle entry not executable: $ENTRY"
command -v sample >/dev/null 2>&1 || die "sample(1) missing"

mkdir -p "$WORK" || die "cannot create $WORK"
SHIM_LOG="$WORK/shim.log"
# Refuse to run with the log on the volume under test — see the header note.
if [ "$(stat -f '%d' "$WORK")" != "$(stat -f '%d' /)" ]; then
  die "WORK=$WORK is not on the boot volume: the shim's first open(O_CREAT) would hang there (bug #21). Use the \${TMPDIR} default."
fi

# --- helpers ---------------------------------------------------------------
# st_dev of a path, as a single number: "same device as /" is the whole rule.
devid() { stat -f '%d' "$1" 2>/dev/null || echo "?"; }
ROOT_DEV=$(devid /)
BUNDLE_DEV=$(devid "$MACOS")
CASE_BOOT=yes
[ "$ROOT_DEV" != "$BUNDLE_DEV" ] && CASE_BOOT=no

# Absolute paths only: `grep Contents/MacOS/App` also matches AppleSpell,
# AppleIDSettings and friends, which once reported three foreign processes as
# "our previous run still alive".
procs_of() { ps -eo pid,command | grep -F "$1" | grep -v grep | awk '{print $1}'; }

# Wait until the shim log contains $1 (a fixed string) or WAIT seconds pass.
wait_for() {
  local needle="$1" waited=0
  while [ "$waited" -lt "$((WAIT * 4))" ]; do
    grep -qF "$needle" "$SHIM_LOG" 2>/dev/null && return 0
    sleep 0.25; waited=$((waited + 1))
  done
  return 1
}

launch() {  # $1 = bundle to `open`
  rm -f "$SHIM_LOG"
  TYPEPHP_SHELL_LOG="$SHIM_LOG" open -n "$1" || return 1
}

teardown() {  # kill the launcher first (= the user closed the window)
  local b="$1" lp sp
  lp=$(procs_of "$b/Contents/MacOS/launcher-macos" | head -1)
  [ -n "$lp" ] && kill "$lp" 2>/dev/null
  sleep 1
  sp=$(procs_of "$b/Contents/MacOS/App" | head -1)
  [ -n "$sp" ] && kill -9 "$sp" 2>/dev/null
  sleep 1
}

sect "[A1] cold start"
LEFT=$(procs_of "$BUNDLE/Contents/MacOS/App")
if [ -n "$LEFT" ]; then
  bad "a previous run is still alive: $(printf '%s' "$LEFT" | tr '\n' ' ')"
else
  ok "no bundle entry running"
fi
STALE=$(ls "$TMPDIR" 2>/dev/null | grep -c '^tinyjs-typephp-[0-9]*\.sock$' || true)
printf '   note: %s endpoint file(s) already in %s from other processes\n' "$STALE" "${TMPDIR:-/tmp}"
printf '   note: bundle volume dev=%s, / dev=%s -> %s\n' \
  "$BUNDLE_DEV" "$ROOT_DEV" \
  "$([ "$CASE_BOOT" = no ] && echo 'NON-boot volume (the #21 case)' || echo 'boot volume (rule will not fire)')"
BEFORE_LIST=$(cd "$MACOS" && ls -1 | sort | tr '\n' ' ')
BEFORE_CNT=$(find "$BUNDLE" -type f | wc -l | tr -d ' ')

sect "[A2] LaunchServices launch reaches the frame channel"
launch "$BUNDLE" || bad "open failed"
if wait_for "launcher connected"; then
  ok "launcher connected (this is what #21 prevented)"
else
  bad "no 'launcher connected' within ${WAIT}s — the packaged launch is stuck again"
  stuck=$(procs_of "$BUNDLE/Contents/MacOS/App" | head -1)
  [ -n "$stuck" ] && { sample "$stuck" 1 -f "$WORK/stuck-sample.txt" >/dev/null 2>&1; \
    grep -E '__bind|__open' "$WORK/stuck-sample.txt" | head -3 | sed 's/^/        /'; }
fi

sect "[A3] endpoint placement"
EP=$(grep -a -o 'transport=unix-socket pipe=[^ ]*' "$SHIM_LOG" 2>/dev/null | head -1 | cut -d= -f3)
if [ -z "$EP" ]; then
  bad "shim logged no endpoint path"
else
  ok "endpoint = $EP"
  case "$EP" in
    "$MACOS"/*)
      if [ "$CASE_BOOT" = no ]; then
        bad "endpoint is inside the bundle although the bundle is off the boot volume"
      else
        ok "bundle-dir endpoint (correct for a boot-volume bundle)"
      fi ;;
    *)
      [ "$CASE_BOOT" = no ] && ok "endpoint moved off the bundle (the #21 fix)" \
                             || bad "boot-volume bundle should keep its endpoint in the app dir"
      grep -qF 'endpoint moved off the app dir' "$SHIM_LOG" \
        && ok "the shim says WHY: $(grep -a -o 'endpoint moved off the app dir ([^)]*)' "$SHIM_LOG" | head -1)" \
        || sk "no 'moved off the app dir' line (nothing had to move)" ;;
  esac
  [ -S "$EP" ] && ok "the socket file exists while running" || sk "socket file gone already (run finished fast)"
fi
AFTER_CNT=$(find "$BUNDLE" -type f | wc -l | tr -d ' ')
AFTER_LIST=$(cd "$MACOS" && ls -1 | sort | tr '\n' ' ')
if [ "$BEFORE_LIST" = "$AFTER_LIST" ] && [ "$BEFORE_CNT" = "$AFTER_CNT" ]; then
  ok "the bundle dir gained no file (nothing was created on the volume)"
else
  bad "the bundle changed during the launch: files $BEFORE_CNT -> $AFTER_CNT"
  printf '        before: %s\n        after : %s\n' "$BEFORE_LIST" "$AFTER_LIST"
fi

sect "[A4] frame balance and the end-to-end marker"
if wait_for "WINDOW-E2E OK"; then
  NC=$(grep -ac 'L->P: CALL' "$SHIM_LOG" || true)
  NR=$(grep -ac 'P->L: RET' "$SHIM_LOG" || true)
  MK=$(grep -ao 'WINDOW-E2E OK ping=pong in [0-9]*ms' "$SHIM_LOG" | head -1)
  ok "$MK"
  [ "$NC" -gt 0 ] && [ "$NC" = "$NR" ] && ok "CALL=$NC RET=$NR (balanced)" \
    || bad "unbalanced frames: CALL=$NC RET=$NR"
else
  bad "no WINDOW-E2E marker within ${WAIT}s"
fi

# Optional pixel proof, while the window from A2 is still on screen. Needs the
# Screen Recording grant for the terminal; without it screencapture yields a
# desktop-only image, so a missing/blank shot is a SKIP, never a FAIL.
if [ -n "$SHOT" ]; then
  sect "[A4b] screenshot of the LaunchServices window (SHOT=$SHOT)"
  WINLIST="${WINLIST:-$ROOT/build/mac-winlist}"
  if [ ! -x "$WINLIST" ] && [ -f "$ROOT/tools/mac-winlist.c" ]; then
    mkdir -p "$ROOT/build"
    cc -o "$WINLIST" "$ROOT/tools/mac-winlist.c" \
      -framework CoreGraphics -framework CoreFoundation 2>"$WORK/winlist-cc.txt" \
      || printf '   note: winlist helper did not build: %s\n' "$(head -1 "$WORK/winlist-cc.txt")"
  fi
  if [ ! -x "$WINLIST" ]; then
    sk "$WINLIST absent and could not be built from tools/mac-winlist.c — no window number to photograph with"
  else
    LPID=$(procs_of "$BUNDLE/Contents/MacOS/launcher-macos" | head -1)
    [ -n "$LPID" ] && ok "launcher pid $LPID" || bad "no launcher process to photograph"
    WINS=$("$WINLIST" 2>/dev/null | awk -F'\t' -v p="$LPID" '$2==p')
    LINE=$(printf '%s\n' "$WINS" | head -1)
    WIN=$(printf '%s' "$LINE" | cut -f1)
    GEOM=$(printf '%s' "$LINE" | cut -f5)          # <W>x<H>@<X>,<Y>
    if [ -n "$WIN" ]; then
      ok "window $WIN ($(printf '%s' "$LINE" | cut -f3,4,5 | tr '\t' ' '))"
      if screencapture -x -o -l"$WIN" "$SHOT" 2>"$WORK/screencapture.err" && [ -s "$SHOT" ]; then
        ok "captured $SHOT by window id ($(stat -f '%z' "$SHOT") B)"
      else
        # `-l<id>` can fail with `could not create image from window` while the
        # window is perfectly alive — off-screen frame or another Space. The
        # geometry CGWindowList gave us is still good, so grab that rect.
        RECT=$(printf '%s' "$GEOM" | sed -E 's/([0-9]+)x([0-9]+)@(-?[0-9]+),(-?[0-9]+)/\3,\4,\1,\2/')
        if screencapture -x -R"$RECT" "$SHOT" 2>>"$WORK/screencapture.err" && [ -s "$SHOT" ]; then
          ok "captured $SHOT by region $RECT (-l failed: $(head -1 "$WORK/screencapture.err"))"
        else
          sk "screencapture produced nothing — Screen Recording is not granted to this shell ($(head -1 "$WORK/screencapture.err"))"
        fi
      fi
    else
      sk "no on-screen window owned by the launcher (Screen Recording denied, or the window never mapped)"
    fi
  fi
fi

sect "[A5] closing the window tears everything down"
teardown "$BUNDLE"
LEFT=$(procs_of "$BUNDLE/Contents/MacOS/App")
[ -z "$LEFT" ] && ok "no shim left" || bad "shim survived: $(printf '%s' "$LEFT" | tr '\n' ' ')"
[ -z "$(procs_of "$BUNDLE/Contents/MacOS/launcher-macos")" ] && ok "no launcher left" || bad "launcher survived"
grep -qa 'launcher closed' "$SHIM_LOG" && grep -qa '\[shell\] done' "$SHIM_LOG" \
  && ok "shim logged the clean shutdown pair (launcher closed / done)" \
  || bad "shim log lacks 'launcher closed' + 'done'"
if [ -n "${EP:-}" ] && [ -e "$EP" ]; then bad "endpoint file not unlinked: $EP"; else ok "endpoint file unlinked"; fi
# Keep the LaunchServices-run log: every later section reuses $SHIM_LOG, and this
# is the one file that shows the CALL/RET balance and the relocation line
# together. Evidence collection and post-mortems both want it by name.
cp -f "$SHIM_LOG" "$WORK/launch-services-run.log" 2>/dev/null \
  && printf '   note: full LaunchServices-run log kept at %s\n' "$WORK/launch-services-run.log"

sect "[A6] direct exec still works (regression guard for the fix)"
rm -f "$SHIM_LOG"
TYPEPHP_SHELL_LOG="$SHIM_LOG" "$ENTRY" >/dev/null 2>&1 &
DIRECT=$!
if wait_for "launcher connected"; then ok "direct exec connected the launcher too"; else
  bad "direct exec did not reach the frame channel (regression)"
fi
kill -9 "$DIRECT" 2>/dev/null
wait "$DIRECT" 2>/dev/null   # reap here so the shell does not print 'Killed: 9'
teardown "$BUNDLE"
[ -z "$(procs_of "$BUNDLE/Contents/MacOS")" ] && ok "nothing left after the direct run" || bad "leftover processes from the direct run"

sect "[B] negative control with the pre-fix shim"
if [ -z "$CTL_SHIM" ]; then
  sk "CTL_SHIM unset — section B only means something against a binary from before the fix"
elif [ ! -x "$CTL_SHIM" ]; then
  bad "CTL_SHIM=$CTL_SHIM is not executable"
else
  # Stage it where the OLD rule would still fit sun_path, so the only variable
  # is the selection rule itself: 79 B < 104 B for a short dir on this volume.
  # It has to sit on the repo volume: the whole control is the non-boot-volume
  # case. Unique per run, because the hung control outlives its own directory —
  # a fixed name let a previous run's orphan be sampled as this run's result.
  CTLDIR="$ROOT/build/26c-ctl-$$.app"
  for p in $(procs_of "$ROOT/build/26c-ctl"); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$ROOT"/build/26c-ctl-*.app
  cp -R "$BUNDLE" "$CTLDIR" || bad "staging the control copy failed"
  cp -f "$CTL_SHIM" "$CTLDIR/Contents/MacOS/App" || bad "installing the control shim failed"
  # Under a fresh identifier, so an earlier consent answer for the demo app
  # cannot make this control pass without the #21 block being real.
  plutil -replace CFBundleIdentifier -string "$CTL_ID" \
    "$CTLDIR/Contents/Info.plist" 2>/dev/null || bad "setting $CTL_ID on the control failed"
  # No re-sign: `tgui build` leaves the bundle unsealed, and `codesign` cannot
  # seal this layout at all — Contents/MacOS/App.conf is read as nested code and
  # rejected ("code object is not signed at all"). Editing Info.plist of an
  # unsealed bundle therefore costs nothing; the conf-in-MacOS part is logged as
  # a Developer ID blocker (candidate ④), not a defect of this control.
  if codesign --verify --deep --strict "$CTLDIR" >"$WORK/ctl-verify.txt" 2>&1; then
    bad "the control bundle IS sealed — editing Info.plist without re-signing would break the launch; re-sign here"
  else
    printf '   note: not sealed, no re-sign needed — %s\n' "$(tail -1 "$WORK/ctl-verify.txt")"
  fi
  SOCKLEN=$(printf '%s' "$CTLDIR/Contents/MacOS/app.sock" | wc -c | tr -d ' ')
  if [ "$SOCKLEN" -ge 104 ]; then
    bad "control path is $SOCKLEN B — the old rule would bail on sun_path, not on the volume"
  else
    FIXED_LOG="$WORK/fixed-run-shim.log"
    cp -f "$SHIM_LOG" "$FIXED_LOG" 2>/dev/null || true   # A6's log: what the fixed shim decided
    rm -f "$SHIM_LOG"
    TYPEPHP_SHELL_LOG="$SHIM_LOG" open -n "$CTLDIR" || bad "control open failed"
    sleep "$WAIT"
    if grep -qF 'launcher connected' "$SHIM_LOG"; then
      # Not a FAIL: the block this control needs is per-identifier TCC consent,
      # and an answered identifier never blocks. Say what it means, clean up.
      teardown "$CTLDIR"
      sk "the pre-fix shim connected: $CTL_ID already has consent for this volume, so the #21 block is not reachable with this id — rearm with \`tccutil reset SystemPolicyRemovableVolumes $CTL_ID\` (revokes consent for this test id only)"
    else
      ok "pre-fix shim never connected (the #21 symptom)"
      CPS=$(procs_of "$CTLDIR/Contents/MacOS/App")
      if [ -n "$CPS" ]; then
        CP=$(printf '%s\n' "$CPS" | head -1)
        printf '   note: control pid %s state %s (S = parked in a syscall, not spinning)\n' \
          "$CP" "$(ps -o stat= -p "$CP" 2>/dev/null | tr -d ' ')"
        sample "$CP" 1 -f "$WORK/prefix-sample.txt" >/dev/null 2>&1
        grep -qE '__bind|__open' "$WORK/prefix-sample.txt" \
          && ok "stuck in $(grep -aoE '__bind|__open' "$WORK/prefix-sample.txt" | tail -1) — file creation on the volume, not our frames" \
          || bad "control process alive but not in __bind/__open: read $WORK/prefix-sample.txt"
      else
        sk "control process already exited; check $SHIM_LOG for why"
      fi
      for p in $(procs_of "$CTLDIR"); do kill -9 "$p" 2>/dev/null; done
    fi
    # Deterministic either way: the OLD rule kept the endpoint inside the bundle
    # and never mentioned a relocation. This is the part of the control that does
    # not depend on this machine's consent state.
    grep -qF "$CTLDIR/Contents/MacOS/app.sock" "$SHIM_LOG" \
      && ok "the pre-fix log names the in-bundle endpoint it tried" \
      || bad "the pre-fix log does not name $CTLDIR/Contents/MacOS/app.sock — is CTL_SHIM really pre-fix?"
    if grep -qF 'endpoint moved off the app dir' "$SHIM_LOG"; then
      bad "the pre-fix shim relocated the endpoint — CTL_SHIM is not a pre-fix binary"
    else
      ok "the pre-fix shim has no relocation branch (the fixed log does: $(grep -ao 'endpoint moved off the app dir ([^)]*)' "$FIXED_LOG" 2>/dev/null | head -1))"
    fi
  fi
  rm -rf "$CTLDIR"
fi

sect "result"
printf '== macos-bundle-launch: %d ok / %d fail / %d skip  (artifacts: %s)\n' "$pass" "$fail" "$skip" "$WORK"
[ "$fail" -eq 0 ] || exit 1
