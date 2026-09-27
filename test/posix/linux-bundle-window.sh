#!/usr/bin/env bash
# Phase 22d driver — run INSIDE a Linux box/container with an X display (Xvfb OK;
# this script starts one if needed).
#
# Acceptance for the LINUX PACKAGED direction: the bundle `gui/bin/tgui build`
# produces, run the way a user would run it. The dev direction has the CLI
# supervising every spawn; here nobody does — the ENTRY (the renamed shim) reads
# its own .conf, spawns the pristine launcher and the bundled PHP backend, and
# must tear itself down when the window closes. So this asserts on exactly the
# parts `tgui` cannot help with:
#
#   1. the bundle is structurally valid  (verify-bundle-linux.sh — rerun AFTER
#      relocating it out of the repo tree, because a bundle that only works next
#      to the checkout is not a bundle)
#   2. it runs with every TYPEPHP_* env var cleared -> nothing but the conf
#      drives the wiring
#   3. real frames + the WINDOW-E2E marker -> the WebView actually rendered and
#      answered, not merely a process that started
#   4. closing the window unlinks <bundle>/app.sock and leaves no child behind
#      (packaged mode has no supervisor to clean up after it: this is load-bearing)
#
# Evidence: $WORK/build.log, $WORK/verify.log, $WORK/entry.log, $WORK/entry.out,
#           $WORK/shot.png.
#
# NOT covered, by construction: a real desktop session (Xvfb has no compositor,
# no window manager, no tray), and a target machine without GTK3/webkit2gtk-4.1
# (the launcher is dynamically linked — verify-bundle-linux.sh prints the .so
# list it needs).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="$ROOT/demo"
WORK="${WORK:-/tmp/tpgui-22d}"; mkdir -p "$WORK"
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
ENTRY_LOG="$WORK/entry.log"
fail=0
note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }

# Everything that could wire the app from outside the bundle. TYPEPHP_SHELL_LOG
# is the one exception and is set explicitly below: it only says WHERE the shim
# logs, never what it spawns.
BLOCKED_ENV=(TYPEPHP_APP TYPEPHP_CWD TYPEPHP_BACKEND TYPEPHP_APP_KIND
             TYPEPHP_PIPE_NAME TINYGUI_DEV_SOCK TINYGUI_DEV_LOG TINYGUI_LAUNCHER)
env_is_clean() {
  local e
  for e in "${BLOCKED_ENV[@]}"; do unset "$e" 2>/dev/null; done
  # true (0) == nothing wiring-related is left in the environment
  env | grep -qE '^(TYPEPHP_|TINYGUI_)' && return 1
  return 0
}

# Zombie entries from earlier runs survive pkill and still show up in pgrep, so
# every process query filters on state (learned in 22b).
live_pid() { ps -o pid=,stat=,comm= -e 2>/dev/null \
             | awk -v c="$1" '$2 !~ /^Z/ && $3 == c { print $1; exit }'; }
count() { local n; n=$(grep -c "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

XVFB_PID=""
ENTRY_PID=""
cleanup() {
  local p
  p="$(live_pid launcher-linux)"; [ -n "$p" ] && kill "$p" 2>/dev/null
  [ -n "$ENTRY_PID" ] && kill "$ENTRY_PID" 2>/dev/null
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

note "[1/6] toolchain (build/backend_shell + build/launcher-linux)"
if [ ! -x "$ROOT/build/backend_shell" ] || [ ! -x "$ROOT/build/launcher-linux" ]; then
  bash "$ROOT/tools/build-linux.sh" > "$WORK/build-linux.log" 2>&1 \
    || { bad "tools/build-linux.sh failed — see $WORK/build-linux.log"; exit 1; }
fi
[ -x "$ROOT/build/backend_shell" ]  && ok "shim present"     || bad "build/backend_shell missing"
[ -x "$ROOT/build/launcher-linux" ] && ok "launcher present" || bad "build/launcher-linux missing"
[ "$fail" = 0 ] || exit 1

note "[2/6] tgui build, then relocate the bundle out of the repo"
rm -rf "$DEMO/dist" "$WORK/dist" "$WORK/bundle"
( cd "$DEMO" && bash "$ROOT/gui/bin/tgui" build ) > "$WORK/build.log" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "tgui build RC=0 (its verify-bundle-linux.sh gate passed)" \
  || { bad "tgui build RC=$RC"; tail -25 "$WORK/build.log" | sed 's/^/     | /'; exit 1; }
SRC_BUNDLE="$(find "$DEMO/dist" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
[ -n "$SRC_BUNDLE" ] || { bad "no app dir produced under $DEMO/dist"; exit 1; }
# Repackage → unpack elsewhere, i.e. the same bytes `tgui publish` would ship.
( cd "$DEMO" && tar -cf "$WORK/bundle.tar" "dist/$(basename "$SRC_BUNDLE")" ) \
  && tar -C "$WORK" -xf "$WORK/bundle.tar" || { bad "could not relocate the bundle"; exit 1; }
rm -rf "$DEMO/dist"                       # the run must not be able to lean on it
BUNDLE="$WORK/dist/$(basename "$SRC_BUNDLE")"
ENTRY="$BUNDLE/$(basename "$SRC_BUNDLE")"
[ -x "$ENTRY" ] && ok "runs from outside the repo: $BUNDLE" \
  || { bad "relocated entry is missing or not executable: $ENTRY"; exit 1; }
bash "$ROOT/tools/verify-bundle-linux.sh" "$BUNDLE" > "$WORK/verify.log" 2>&1 \
  && ok "verify-bundle-linux.sh PASS on the relocated copy ($(count "$WORK/verify.log" '^   ok   ') checks)" \
  || { bad "verify-bundle-linux.sh FAILED after relocation"; tail -25 "$WORK/verify.log" | sed 's/^/     | /'; }

note "[3/6] X display $DISPLAY_NUM"
export DISPLAY="$DISPLAY_NUM"
x_probe() { import -window root /tmp/.22d-xprobe.png 2>/dev/null; }
if ! x_probe; then
  rm -f "/tmp/.X${DISPLAY_NUM#:}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM#:}" 2>/dev/null
  Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  for _ in $(seq 1 40); do x_probe && break; sleep 0.25; done
fi
x_probe && ok "an X client can connect (Xvfb${XVFB_PID:+ pid $XVFB_PID})" \
  || { bad "no working X display on $DISPLAY_NUM"; exit 1; }

note "[4/6] start the entry with every wiring env var cleared (pure conf)"
rm -f "$ENTRY_LOG" "$BUNDLE/app.sock"
env_is_clean && ok "no TYPEPHP_*/TINYGUI_* left in the environment" \
  || { bad "some TYPEPHP_*/TINYGUI_* survived the clear — the run would not be conf-only"; exit 1; }
# setsid must be the first program in the exec chain (it only forks when already
# a pgrp leader, and with job control off it is not one), stdbuf because a
# redirected bash/printf stream is block-buffered. `cd /` then exec: even the
# process cwd is deliberately NOT inside the bundle, so a bundle that resolves
# anything relative to cwd rather than to its own exe dir fails here.
setsid stdbuf -oL -eL env -u TYPEPHP_APP -u TYPEPHP_CWD -u TYPEPHP_BACKEND \
  -u TYPEPHP_APP_KIND -u TYPEPHP_PIPE_NAME \
  TYPEPHP_SHELL_LOG="$ENTRY_LOG" \
  sh -c 'cd / && exec "$1"' _ "$ENTRY" > "$WORK/entry.out" 2>&1 &
ENTRY_PID=$!
for _ in $(seq 1 60); do
  [ "$(count "$ENTRY_LOG" 'L->P: CALL')" -ge 13 ] \
    && [ "$(count "$ENTRY_LOG" 'P->L: RET')" -ge 13 ] && break
  kill -0 "$ENTRY_PID" 2>/dev/null || { note "the entry exited early — not waiting out the poll"; break; }
  sleep 0.5
done
kill -0 "$ENTRY_PID" 2>/dev/null && note "entry alive (pid $ENTRY_PID), it owns the app" \
  || note "entry already gone — see $ENTRY_LOG / $WORK/entry.out"

note "[5/6] assertions on the run"
head -6 "$ENTRY_LOG" 2>/dev/null | sed 's/^/     | /'
C=$(count "$ENTRY_LOG" 'L->P: CALL'); R=$(count "$ENTRY_LOG" 'P->L: RET')
M=$(count "$ENTRY_LOG" 'WINDOW-E2E OK ping=pong')
note "frames: CALL=$C RET=$R e2e-lines=$M (the marker is 2 lines per cycle: CALL frame + backend stderr echo, bug #14)"
[ "$C" -ge 13 ] && [ "$R" -ge 13 ] && ok ">=13/13 CALL/RET with no env wiring at all" \
  || bad "frame round-trip incomplete (CALL=$C RET=$R)"
[ "$M" -ge 1 ] && ok "WINDOW-E2E marker present — the page rendered and reached the backend" \
  || { bad "no WINDOW-E2E marker"; tail -10 "$WORK/entry.out" 2>/dev/null | sed 's/^/     | /'; }
# The lines that say the CONF drove everything.
grep -qF "launch mode conf=$BUNDLE/$(basename "$BUNDLE").conf" "$ENTRY_LOG" \
  && ok "launch mode read the bundle's own .conf" || bad "entry did not read its conf from the bundle dir"
grep -qF "app=$BUNDLE/app/bin/run-backend.php" "$ENTRY_LOG" \
  && ok "backend resolved from conf app=, inside the bundle" || bad "backend path is not the bundled one"
grep -qF "app_kind=stock" "$ENTRY_LOG" && ok "app_kind=stock (shebang script, execv'd with no argv)" \
  || bad "unexpected app_kind"
grep -qE "\[shell\] transport=unix-socket pipe=$BUNDLE/app\.sock" "$ENTRY_LOG" \
  && ok "endpoint = <bundle>/app.sock (created by the entry itself)" \
  || bad "endpoint is not the bundle-local app.sock"
grep -qE "cwd=$BUNDLE/?" "$ENTRY_LOG" \
  && ok "backend cwd = the bundle dir, not the process cwd ('/') and not TYPEPHP_CWD" \
  || bad "cwd did not come from the exe dir"
grep -qF "] launcher connected" "$ENTRY_LOG" && ok "the pristine launcher connected" \
  || bad "launcher never connected"
L="$(live_pid launcher-linux)"; [ -n "$L" ] && ok "launcher-linux alive (pid $L)" || bad "no live launcher-linux"
[ -S "$BUNDLE/app.sock" ] && ok "app.sock present while running" || bad "app.sock missing while the app is up"
if command -v import >/dev/null 2>&1; then
  import -window root "$WORK/shot.png" 2>/dev/null \
    && ok "shot.png ($(wc -c < "$WORK/shot.png" | tr -d ' ') B)" || note "screenshot failed (non-fatal)"
else
  note "no ImageMagick 'import' — skipping the screenshot"
fi

note "[6/6] teardown: close the window, expect the whole chain to unwind"
L="$(live_pid launcher-linux)"
[ -n "$L" ] && { kill "$L" 2>/dev/null; note "killed launcher pid $L (= the user closing the window)"; } \
  || note "no launcher to kill — checking whether the entry already unwound"
for _ in $(seq 1 40); do kill -0 "$ENTRY_PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$ENTRY_PID" 2>/dev/null && bad "the entry survived its own window" \
  || ok "entry exited on its own (endpoint EOF -> PHP child killed -> socket unlinked)"
[ -e "$BUNDLE/app.sock" ] && bad "app.sock left behind" || ok "app.sock unlinked"
LEFT="$(ps -o pid=,stat=,comm= -e 2>/dev/null \
        | awk '$2 !~ /^Z/ && ($3=="launcher-linux"||$3=="php"||$3=="TypePHP-Demo"){printf "%s ", $1}')"
[ -z "$LEFT" ] && ok "no residual processes from this run" || bad "processes left behind: $LEFT"

echo
[ "$fail" = 0 ] \
  && echo "== packaged linux bundle: PASS  (Xvfb headless — NOT a real desktop session)" \
  || echo "== packaged linux bundle: FAIL"
echo "   entry log:  $ENTRY_LOG"
echo "   build log:  $WORK/build.log"
echo "   verify log: $WORK/verify.log"
exit $fail
