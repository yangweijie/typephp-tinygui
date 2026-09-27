#!/usr/bin/env bash
# Phase 22b/22d Linux driver — run INSIDE a Linux box/container that has an X
# display (a real desktop, or Xvfb, which this script starts if needed).
#
# Unlike test/posix/tier4-linux-window.sh — which hand-builds the spawn commands
# and so proves the PROTOCOL — this one drives the real CLI (`gui/bin/tgui
# status` / `dev`) and asserts on what the CLI produced. That is the difference
# between "the chain works" and "a user can run it".
#
# Log discipline (learned the hard way): the shim's frame log is APPEND-only and
# each dev cycle writes its own `[shell] transport=…` header, so cycles are
# counted by splitting on that header. Counting CALL/marker lines across the
# whole file is meaningless once a bounce has happened, and the WINDOW-E2E text
# appears TWICE per cycle (once as the CALL frame, once as the backend's stderr
# echo — bug #14 routes stderr to the log only), so it cannot be a cycle counter.
#
# Evidence: $WORK/tgui.out (CLI log), $WORK/shim.log (frame log),
#           $WORK/shot.png (Xvfb screenshot, best effort).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="$ROOT/demo"
WORK="${WORK:-/tmp/tpgui-linux-tgui}"; mkdir -p "$WORK"
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
SHIM_LOG="$WORK/shim.log"
SOCK="$WORK/dev.sock"
TGUI_PGID=""
XVFB_PID=""
fail=0
note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }

# cycles <file> -> number of dev cycles present in the frame log
cycles() { local n; n=$(grep -c '^\[shell\] transport=' "$1" 2>/dev/null); printf '%s' "${n:-0}"; }
# cycle_stat <file> <cycle#> <pattern> -> matches within one cycle segment
cycle_stat() {
  awk -v want="$2" -v pat="$3" '
    /^\[shell\] transport=/ { n++ }
    n == want { if (index($0, pat)) c++ }
    END { printf "%d", c + 0 }' "$1" 2>/dev/null
}
# Zombie entries from earlier runs survive every pkill and show up in pgrep, so
# all process queries here filter on state: an unreapable `[launcher-linux]
# <defunct>' must never be mistaken for the live chain (that exact confusion
# made a teardown assertion fail while the real chain was still up).
leftovers() {
  ps -o pid=,stat=,comm= -e 2>/dev/null \
    | awk '$2 !~ /^Z/ && ($3 == "backend_shell" || $3 == "launcher-linux") { printf "%s ", $1 }'
}
live_pid() { # live_pid <comm> -> first non-zombie pid
  ps -o pid=,stat=,comm= -e 2>/dev/null \
    | awk -v c="$1" '$2 !~ /^Z/ && $3 == c { print $1; exit }'
}
live_launcher() { live_pid launcher-linux; }
live_shim()     { live_pid backend_shell; }

cleanup() {
  [ -n "$TGUI_PGID" ] && kill -TERM -"$TGUI_PGID" 2>/dev/null
  # The [l] / shel[l] tricks keep pkill from matching THIS script's own command
  # line, which contains both paths (a self-match here once killed the whole run
  # before it printed anything).
  pkill -f 'build/backend_shel[l]' 2>/dev/null
  pkill -f 'build/launcher-linux[ ]' 2>/dev/null
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

[ -x "$ROOT/build/backend_shell" ] && [ -x "$ROOT/build/launcher-linux" ] \
  || { echo "build/backend_shell + build/launcher-linux missing — run tools/build-linux.sh"; exit 2; }
[ -f "$DEMO/tinyjs.json" ] || { echo "no $DEMO/tinyjs.json"; exit 2; }
[ -f "$DEMO/src/backend.php" ] || { echo "no $DEMO/src/backend.php (the touch target)"; exit 2; }
command -v stdbuf >/dev/null || echo "   note: no stdbuf — the CLI's log stays block-buffered until it exits, so live greps below can lag"

# --- X display ---------------------------------------------------------------
# Xvfb startup is not synchronous, and a killed server leaves /tmp/.X99-lock plus
# a dead socket node behind — the next client then fails with "could not open
# display" while the file is right there. So: probe with a real X client, and only
# when nothing answers, clear the stale files, start Xvfb and wait for the probe
# to succeed.
xdir_ready() { [ -e "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]; }
# The socket NODE existing does not mean a server is answering: a killed Xvfb
# leaves it behind (and defunct Xvfb entries keep showing up in pgrep), and GTK
# then fails with "could not open display". So ask with a real client.
x_probe() {
  if command -v import >/dev/null 2>&1; then
    DISPLAY="$DISPLAY_NUM" import -window root "$WORK/.xprobe.png" 2>/dev/null
  elif command -v xset >/dev/null 2>&1; then
    DISPLAY="$DISPLAY_NUM" xset q >/dev/null 2>&1
  else
    xdir_ready
  fi
}
if [ -z "${DISPLAY:-}" ]; then
  export DISPLAY="$DISPLAY_NUM"
  if ! x_probe; then
    # No live server on this display: clear whatever stale lock/socket a
    # previous (or killed) Xvfb left, then start one and wait until it answers.
    pkill -x Xvfb 2>/dev/null; sleep 0.5
    rm -f "/tmp/.X${DISPLAY_NUM#:}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM#:}" 2>/dev/null
    Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 40); do x_probe && break; sleep 0.25; done
  fi
  x_probe || { echo "!! no X display on $DISPLAY_NUM: started Xvfb but no client can connect"; exit 2; }
  note "DISPLAY=$DISPLAY_NUM answers X clients (Xvfb${XVFB_PID:+ pid $XVFB_PID})"
else
  x_probe || echo "   !! DISPLAY=$DISPLAY does not answer an X client — GTK will fail"
  note "using inherited DISPLAY=$DISPLAY"
fi

# start from a quiet box: no stale chain from a previous run
pkill -f 'build/backend_shel[l]' 2>/dev/null; pkill -f 'build/launcher-linux[ ]' 2>/dev/null
sleep 0.5

note "[1/5] tgui status reports the Linux toolchain"
OUT=$( cd "$DEMO" && bash "$ROOT/gui/bin/tgui" status 2>&1 )
printf '%s\n' "$OUT" | sed 's/^/     | /'
printf '%s' "$OUT" | grep -q 'launcher-linux' && ok "status lists build/launcher-linux" \
  || bad "status has no Linux section"
printf '%s' "$OUT" | grep -qi 'X display' && ok "status states the X-display requirement" \
  || bad "status does not mention the X display requirement"

note "[2/5] tgui dev: spawn the chain"
rm -f "$SHIM_LOG" "$SOCK"
# setsid puts the CLI in its own session, so cleanup's group-kill can never reach
# THIS script (without job control the CLI would share our process group and take
# the whole run down). stdbuf -oL because bash's printf into a redirected file is
# block-buffered: without it, live greps on tgui.out lag until the CLI exits.
# `bash <cli>`, not `exec <cli>`: the repo tracks no exec bits (every .sh is
# 100644) and README invokes the CLI as `bash gui/bin/tgui …`. NOTE the ordering:
# an env-assignment prefix must stay on the SAME logical line as the command —
# putting a comment between them leaves the assignments dangling and silently
# strips them from the child (that is how this run once lost TINYGUI_DEV_LOG).
TINYGUI_DEV_LOG="$SHIM_LOG" TINYGUI_DEV_SOCK="$SOCK" \
  setsid stdbuf -oL -eL bash -c "cd '$DEMO' && exec bash '$ROOT/gui/bin/tgui' dev" \
  > "$WORK/tgui.out" 2>&1 &
TGUI_PGID=$!
for _ in $(seq 1 60); do [ "$(cycles "$SHIM_LOG")" -ge 1 ] \
  && [ "$(cycle_stat "$SHIM_LOG" 1 'L->P: CALL')" -ge 13 ] && break
  kill -0 "$TGUI_PGID" 2>/dev/null || { note "the CLI exited early — not waiting out the poll"; break; }
  sleep 0.5; done
C1=$(cycle_stat "$SHIM_LOG" 1 'L->P: CALL'); R1=$(cycle_stat "$SHIM_LOG" 1 'P->L: RET')
E1=$(cycle_stat "$SHIM_LOG" 1 'WINDOW-E2E OK ping=pong')
note "cycle 1: CALL=$C1 RET=$R1 e2e-lines=$E1 (2 expected: CALL frame + stderr echo)"
[ "$C1" -ge 13 ] && [ "$R1" -ge 13 ] && ok ">=13/13 CALL/RET from 'tgui dev'" \
  || { bad "frame round-trip incomplete"; tail -20 "$SHIM_LOG" 2>/dev/null | sed 's/^/     | /'; }
[ "$E1" -ge 1 ] && ok "WINDOW-E2E marker present (the window really rendered)" \
  || { bad "no WINDOW-E2E marker"; tail -20 "$WORK/tgui.out" | sed 's/^/     | /'; }
[ -S "$SOCK" ] && ok "the CLI created its dev endpoint: $SOCK" || bad "dev endpoint missing: $SOCK"
if command -v import >/dev/null; then
  import -window root "$WORK/shot.png" 2>/dev/null \
    && ok "shot.png ($(wc -c < "$WORK/shot.png" | tr -d ' ') B)" || note "screenshot failed (non-fatal)"
fi

note "[3/5] tgui dev: hot restart on a backend edit"
touch "$DEMO/src/backend.php"
# A new `[shell] transport=` header only marks the START of cycle 2; the handshake
# takes another second or so, so wait on cycle 2's own frame count.
for _ in $(seq 1 60); do [ "$(cycle_stat "$SHIM_LOG" 2 'L->P: CALL')" -ge 13 ] && break; sleep 0.5; done
N=$(cycles "$SHIM_LOG")
C2=$(cycle_stat "$SHIM_LOG" 2 'L->P: CALL'); R2=$(cycle_stat "$SHIM_LOG" 2 'P->L: RET')
E2=$(cycle_stat "$SHIM_LOG" 2 'WINDOW-E2E OK ping=pong')
grep -q 'sources changed' "$WORK/tgui.out" && ok "the CLI logged the bounce" \
  || { bad "the CLI never reported a bounce"; tail -5 "$WORK/tgui.out" | sed 's/^/     | /'; }
[ "$N" -ge 2 ] && ok "a second dev cycle appeared in the frame log (cycles=$N)" \
  || bad "still $(cycles "$SHIM_LOG") cycle(s) after the edit"
[ "$C2" -ge 13 ] && [ "$R2" -ge 13 ] && [ "$E2" -ge 1 ] \
  && ok "cycle 2 replays the full handshake: CALL=$C2 RET=$R2 e2e-lines=$E2" \
  || bad "cycle 2 incomplete: CALL=$C2 RET=$R2 e2e-lines=$E2"

note "[4/5] teardown: close the window (kill the launcher), expect the chain to unwind"
# Kill by PID, not by process-group: the group contains this driver too (setsid
# was execed over, so $! is also the group id we were spawned in).
LPID=$(live_launcher)
[ -n "$LPID" ] && { kill "$LPID" 2>/dev/null; note "killed launcher pid $LPID"; } \
  || bad "no launcher process to kill"
for _ in $(seq 1 20); do [ -z "$(leftovers)" ] && break; sleep 0.5; done
LEFT="$(leftovers)"
[ -z "${LEFT// /}" ] && ok "shim exited on its own (endpoint-EOF teardown)" \
  || bad "processes survived the launcher exit: $LEFT"
kill -0 "$TGUI_PGID" 2>/dev/null && bad "tgui dev is still running" || ok "tgui dev exited with the window"
[ -e "$SOCK" ] && bad "socket file left behind: $SOCK" || ok "dev socket cleaned up"

note "[5/5] result"
echo; echo "== tgui linux dev driver: $([ $fail = 0 ] && echo PASS || echo FAIL)"
echo "   CLI log:    $WORK/tgui.out"
echo "   frame log:  $SHIM_LOG"
exit $fail
