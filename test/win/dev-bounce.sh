#!/usr/bin/env bash
# ===========================================================================
# Phase 21e — Windows acceptance driver for `tgui dev`'s HOT RESTART.
#
# Run this ON A WINDOWS BOX, inside Git Bash (MINGW64) at the repo checkout:
#
#     bash test/win/dev-bounce.sh              # full run
#     REBUILD_SHIM=0 bash test/win/dev-bounce.sh   # skip the MinGW shim rebuild
#     WORK=/c/temp/tpgui-21e bash test/win/dev-bounce.sh
#
# WHAT IT PROVES (the four things no macOS/Linux run can prove):
#   1. Git Bash's `kill` reaches a NATIVE launcher-win.exe, and `kill -0` stops
#      reporting it alive — i.e. the CLI's only hot-restart lever works here.
#   2. When that launcher dies, the shim notices the named-pipe EOF, reaps its
#      own PHP child (app.exe) and exits — so a bounce does NOT accumulate
#      processes. This is the load-bearing assertion: on Windows the CLI has no
#      bounded shim-reap fallback (dev_reap_shim is Linux-only), and a killed
#      process runs no atexit handler, so terminate_typephp_backend() in
#      launcher-win.cc never fires. EOF teardown is the ONLY reaper.
#   3. The mtime watcher works with Git Bash's GNU `stat -c` dialect (hot_snap
#      probes -f vs -c at runtime; the BSD form was hardcoded before #19).
#   4. 13 CALL / 13 RET replay on the respawned window + a real rendered window
#      (screenshot via PowerShell, best effort).
#
# It also opportunistically closes the OTHER open Windows gap from Phase 22c:
# the shim's _WIN32 branch has not been recompiled since the 21a app-kind code
# landed. If a MinGW g++ is on PATH we rebuild it with -Wall -Wextra first.
#
# Evidence lands in $WORK: tgui.out (CLI log), shim.log (frame log, APPEND so
# every cycle is in it), tasklist.{before,after-cycle2,teardown}.txt, shot.png.
# Read the last line for PASS/FAIL, and paste the whole $WORK dir back if it FAILs.
# ===========================================================================
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="$ROOT/demo"
WORK="${WORK:-/tmp/tpgui-21e}"
REBUILD_SHIM="${REBUILD_SHIM:-1}"
fail=0
compile_gap=0

note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }
skip() { printf '   --   %s\n' "$*"; }

CLIPID=""
cleanup() {
  # A FAIL mid-run must not leave a window + PHP chain behind on the user's box.
  [ -n "$CLIPID" ] && kill "$CLIPID" 2>/dev/null
  for n in launcher-win.exe backend.exe app.exe; do
    for p in $(win_pids "$n"); do win_kill "$p"; done
  done
  return 0
}
trap cleanup EXIT

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *) printf '!! this driver is the WINDOWS acceptance run (Phase 21e).\n   On %s use test/posix/linux-tgui-window.sh (Linux) or run tgui dev on macOS.\n' "$(uname -s)"; exit 2 ;;
esac

mkdir -p "$WORK"
SHIM_LOG="$WORK/shim.log"
CLI_OUT="$WORK/tgui.out"

# --- Windows process inventory ------------------------------------------------
# tasklist's /NH flags get mangled by MSYS path conversion, so disable it for
# these calls rather than relying on the `//` spelling (which behaves differently
# in Git Bash vs MSYS2). Output: CSV rows, "image name","pid",...
win_rows() { # <image-name> -> "<name> <pid>" per match
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' tasklist /NH /FO CSV 2>/dev/null \
    | tr -d '"' | awk -F',' -v n="$1" 'tolower($1) == tolower(n) { print $1" "$2 }'
}
win_count() { # <image-name> -> number of live processes
  local c; c=$(win_rows "$1" | wc -l | tr -d ' '); printf '%s' "${c:-0}"
}
win_pids() { win_rows "$1" | awk '{print $2}'; }
win_kill() { # <pid>
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill /PID "$1" /F >/dev/null 2>&1
}
to_win() { # POSIX path -> native (the native shim cannot read /d/... paths)
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" | tr '\\' '/'; else printf '%s' "$1"; fi
}

LAUNCHER="$ROOT/build/runtime/launcher-win.exe"
SHIM="$ROOT/build/runtime/backend.exe"
# Resolve the three paths exactly the way gui/bin/tgui does, because a wrong
# guess here reads as "21e is broken" when it is only the driver's: tgui takes
# TINYGUI_LAUNCHER/TYPEPHP_BACKEND/TYPEPHP_APP, defaults to build/runtime/{launcher-win,backend}.exe
# + build/app.exe, and then lets tinyjs.json's typephp.app OVERRIDE that — but
# only if `php` is on PATH (tgui's cfg() has no grep fallback). demo/tinyjs.json
# does declare `backend/app.exe`, so that is what a demo run spawns.
[ -n "${TINYGUI_LAUNCHER:-}" ] && LAUNCHER="$TINYGUI_LAUNCHER"
[ -n "${TYPEPHP_BACKEND:-}" ] && SHIM="$TYPEPHP_BACKEND"
APP="$ROOT/build/app.exe"
[ -n "${TYPEPHP_APP:-}" ] && APP="$TYPEPHP_APP"
if [ -f "$DEMO/tinyjs.json" ] && command -v php >/dev/null 2>&1; then
  AC=$(php -r '$j=json_decode(file_get_contents($argv[1]),true); echo $j["typephp"]["app"] ?? "";' "$DEMO/tinyjs.json" 2>/dev/null)
  [ -n "${AC:-}" ] && APP="$DEMO/$AC"
elif [ -f "$DEMO/tinyjs.json" ]; then
  note "php is not on PATH — tgui's cfg() will IGNORE tinyjs.json, so it uses build/app.exe instead"
fi

# --- [1/7] preflight ----------------------------------------------------------
note "[1/7] preflight: toolchain + the CLI itself"
bash -n "$ROOT/gui/bin/tgui" && ok "bash -n gui/bin/tgui clean" \
  || { bad "gui/bin/tgui does not parse"; exit 2; }
command -v tasklist >/dev/null 2>&1 && command -v taskkill >/dev/null 2>&1 \
  && ok "tasklist / taskkill usable" || { bad "no tasklist/taskkill — cannot assert process counts"; exit 2; }
[ -f "$DEMO/tinyjs.json" ] || { bad "no $DEMO/tinyjs.json"; exit 2; }

# The launcher spawns TYPEPHP_BACKEND (= runtime/backend.exe), which spawns the
# app. Neither runtime/backend.exe nor demo/backend/app.exe is in git — stage them
# from build/ the way demo/build.bat would, because a missing app is NOT a silent
# failure here: the launcher would block on ConnectNamedPipe forever (the Windows
# twin of bug #25). tgui's own `[ -f "$app" ]` gate also runs BEFORE the json
# override, against build/app.exe — so if only the json path exists, back-fill
# build/app.exe too, or the CLI dies at a gate the run does not care about.
if [ ! -f "$SHIM" ] && [ -f "$ROOT/build/backend_shell.exe" ]; then
  mkdir -p "$(dirname "$SHIM")" && cp -f "$ROOT/build/backend_shell.exe" "$SHIM" \
    && note "staged $(basename "$SHIM") from build/backend_shell.exe"
fi
if [ ! -f "$APP" ] && [ -f "$ROOT/build/app.exe" ]; then
  mkdir -p "$(dirname "$APP")" && cp -f "$ROOT/build/app.exe" "$APP"
  for d in php8ts.dll phpx.dll libmpdec-4.0.1.dll libmpdec++-4.0.1.dll gmp-10.dll mpfr-6.dll; do
    [ -f "$ROOT/build/$d" ] && cp -f "$ROOT/build/$d" "$(dirname "$APP")/$d"
  done
  note "staged $APP (+ DLLs) from build/ (same as demo\\build.bat)"
fi
if [ ! -f "$ROOT/build/app.exe" ] && [ -f "$APP" ]; then
  cp -f "$APP" "$ROOT/build/app.exe" \
    && note "back-filled build/app.exe from $APP (tgui gates on it before the json override)"
fi
note "resolved trio: launcher=$LAUNCHER"
note "              shim   =$SHIM"
note "              app    =$APP"
for f in "$LAUNCHER" "$SHIM" "$APP"; do
  [ -f "$f" ] && ok "artifact $(basename "$f")" \
    || { bad "missing $f — run tools\\build-all.bat then tools\\build-launcher.sh --install (and demo\\build.bat) first"; }
done
[ $fail = 0 ] || { echo; echo "== 21e driver: FAIL (preflight)"; exit 1; }

# stat dialect: hot_snap probes `stat -f '%m' /` and must fall through to GNU
# `-c` here. If a box answers BOTH, hot_snap silently picks BSD and every digest
# is identical, which would read as "the watcher is dead" — assert the split.
if stat -f '%m' / >/dev/null 2>&1; then
  bad "GNU stat here accepts the BSD form '-f %m' too — hot_snap would pick a dialect that never changes"
else
  stat -c '%Y' / >/dev/null 2>&1 && ok "stat dialect: BSD '-f' rejected, GNU '-c' works (hot_snap picks GNU)" \
    || bad "no usable stat dialect — watcher cannot compute a digest"
fi

# --- [2/7] rebuild the shim on the _WIN32 branch (22c's other open item) ------
if [ "$REBUILD_SHIM" = 1 ] && command -v g++ >/dev/null 2>&1; then
  note "[2/7] MinGW rebuild of shim/backend_shell.cpp (-Wall -Wextra)"
  CXXW="$WORK/shim-build.log"
  if g++ -std=c++17 -O2 -Wall -Wextra -o "$ROOT/build/backend_shell.exe" \
         "$ROOT/shim/backend_shell.cpp" -ladvapi32 > "$CXXW" 2>&1; then
    NW=$(grep -c 'warning:' "$CXXW" 2>/dev/null); NW="${NW:-0}"
    [ "$NW" = 0 ] && ok "shim compiled clean, 0 warning ($(wc -c < "$ROOT/build/backend_shell.exe" | tr -d ' ') B)" \
      || { bad "$NW warning(s) from the _WIN32 branch — see $CXXW"; sed -n '1,15p' "$CXXW" | sed 's/^/     | /'; }
    cp -f "$ROOT/build/backend_shell.exe" "$SHIM" 2>/dev/null \
      && note "runtime/backend.exe refreshed from the fresh build"
  else
    bad "shim FAILED to compile on Windows — tail of $CXXW:"; tail -20 "$CXXW" | sed 's/^/     | /'
  fi
else
  compile_gap=1
  skip "[2/7] skipped$([ "$REBUILD_SHIM" = 1 ] && echo ' (no g++ on PATH)') — the _WIN32 branch of backend_shell.cpp stays un-recompiled"
fi

# --- [3/7] start clean --------------------------------------------------------
note "[3/7] quiet box: no stale chain from a previous run"
for n in launcher-win.exe backend.exe app.exe; do
  for p in $(win_pids "$n"); do win_kill "$p"; done
done
rm -f "$SHIM_LOG" "$CLI_OUT"
sleep 1

# --- [4/7] cycle 1: tgui dev spawns and completes the handshake --------------
# The frame log is APPEND-only and every cycle starts with `[shell] transport=`,
# so cycles are split on that header. Counting CALL/marker lines across the whole
# file is meaningless once a bounce has happened, and WINDOW-E2E appears twice per
# cycle (CALL frame + the backend's stderr echo), so it is not a cycle counter.
cycles()     { local n; n=$(grep -c '^\[shell\] transport=' "$SHIM_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
cycle_stat() { local v; v=$(awk -v want="$2" -v pat="$3" '
  /^\[shell\] transport=/ { n++ }
  n == want { if (index($0, pat)) c++ }
  END { printf "%d", c + 0 }' "$SHIM_LOG" 2>/dev/null); printf '%s' "${v:-0}"; }
pipe_of()    { local v; v=$(awk -v want="$1" '/^\[shell\] transport=/ { n++; if (n == want) { sub(/.*pipe=/, ""); sub(/ .*/, ""); print; exit } }' "$SHIM_LOG" 2>/dev/null); printf '%s' "$v"; }

note "[4/7] cycle 1: bash gui/bin/tgui dev"
# TYPEPHP_SHELL_LOG must be a NATIVE path (the shim is a native binary and reads
# the env var directly — Git Bash translates argv, not env). It is inherited
# launcher -> shim because CreateProcessW is called with a null env block.
# stdbuf -oL only if present: bash's printf into a redirected file is
# block-buffered, so without it the live greps on tgui.out lag until the CLI exits.
# Guard stdbuf FUNCTIONALLY, not just by presence: on some MinGW installs
# `stdbuf.exe` is on PATH but its companion libstdbuf.dll is missing, so
# `stdbuf -oL bash ...` fails to launch and the whole CLI command dies before
# it starts (symptom: "the CLI exited early", CALL=0). A plain `command -v`
# check hides that. `stdbuf -oL true` loads the preload DLL, so a non-zero
# exit (or the libstdbuf.dll error) means "unusable" -> fall back to no buffering
# (the shim frame log is native output, unaffected; tgui.out is only read at end).
LINEBUF=""
if command -v stdbuf >/dev/null 2>&1 && stdbuf -oL true >/dev/null 2>&1; then
  LINEBUF="stdbuf -oL -eL"
fi
( cd "$DEMO" && TYPEPHP_SHELL_LOG="$(to_win "$SHIM_LOG")" \
    $LINEBUF bash "$ROOT/gui/bin/tgui" dev > "$CLI_OUT" 2>&1 &
  printf '%s' "$!" > "$WORK/cli.pid" )
CLIPID=$(cat "$WORK/cli.pid" 2>/dev/null)
[ -n "${CLIPID:-}" ] || { bad "could not read the CLI pid from $WORK/cli.pid"; exit 1; }
[ -n "$LINEBUF" ] || note "no stdbuf — if a grep below looks stale, re-run after the CLI has exited"
for _ in $(seq 1 90); do
  [ "$(cycle_stat "$SHIM_LOG" 1 'L->P: CALL')" -ge 13 ] && break
  kill -0 "$CLIPID" 2>/dev/null || { note "the CLI exited early"; break; }
  sleep 1
done
C1=$(cycle_stat "$SHIM_LOG" 1 'L->P: CALL'); R1=$(cycle_stat "$SHIM_LOG" 1 'P->L: RET')
E1=$(cycle_stat "$SHIM_LOG" 1 'WINDOW-E2E OK ping=pong')
note "cycle 1: CALL=$C1 RET=$R1 e2e-lines=$E1 pipe=$(pipe_of 1)"
[ "$C1" -ge 13 ] && [ "$R1" -ge 13 ] && ok "cycle 1 frames: $C1 CALL / $R1 RET" \
  || { bad "cycle 1 incomplete (CALL=$C1 RET=$R1)"; tail -20 "$SHIM_LOG" 2>/dev/null | sed 's/^/     | /'; tail -10 "$CLI_OUT" | sed 's/^/     | /'; }
[ "$E1" -ge 1 ] && ok "WINDOW-E2E marker present (the window really rendered)" \
  || bad "no WINDOW-E2E marker in cycle 1"
[ "$(win_count launcher-win.exe)" = 1 ] && ok "exactly 1 launcher-win.exe up" \
  || bad "expected 1 launcher-win.exe, found $(win_count launcher-win.exe)"

# PowerShell screen grab: a real desktop session has something to show. Best
# effort — a headless/RDP-less box can still pass every other assertion here.
cat > "$WORK/shot.ps1" <<'PS1'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$b = New-Object System.Drawing.Bitmap ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width), ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($b)
$g.CopyFromScreen([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Location, [System.Drawing.Point]::Empty, $b.Size)
$b.Save($args[0])
PS1
if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$(to_win "$WORK/shot.ps1")" "$(to_win "$WORK/shot.png")" >/dev/null 2>&1 \
    && ok "shot.png ($(wc -c < "$WORK/shot.png" | tr -d ' ') B)" || skip "screenshot failed (non-fatal)"
fi
win_rows launcher-win.exe > "$WORK/tasklist.before.txt"
win_rows backend.exe >> "$WORK/tasklist.before.txt"
win_rows app.exe >> "$WORK/tasklist.before.txt"

# --- [5/7] the bounce itself --------------------------------------------------
note "[5/7] touch src/backend.php -> the CLI must kill + respawn (cycle 2)"
touch "$ROOT/src/backend.php"   # demo/src/backend.php is a 0-byte stub; the real backend is at repo src/
# NOTE on what this does and does not prove: on Windows the backend is a tpc-
# compiled app.exe, so editing PHP does NOT change what the respawned process
# runs (only `touch`ing the file changes its mtime, which is all the watcher
# reads). This step therefore proves the RESTART mechanism, not hot reload of
# logic. If the watcher ever grows a recompile hook, re-read this line.
for _ in $(seq 1 90); do
  [ "$(cycle_stat "$SHIM_LOG" 2 'L->P: CALL')" -ge 13 ] && break
  sleep 1
done
grep -q 'sources changed' "$CLI_OUT" && ok "the CLI logged the bounce" \
  || { bad "the CLI never reported a bounce (watcher or Git Bash kill is the suspect)"; tail -10 "$CLI_OUT" | sed 's/^/     | /'; }
[ "$(cycles)" -ge 2 ] && ok "a 2nd frame cycle appeared (cycles=$(cycles))" || bad "still $(cycles) cycle(s) after the edit"
C2=$(cycle_stat "$SHIM_LOG" 2 'L->P: CALL'); R2=$(cycle_stat "$SHIM_LOG" 2 'P->L: RET')
E2=$(cycle_stat "$SHIM_LOG" 2 'WINDOW-E2E OK ping=pong')
[ "$C2" -ge 13 ] && [ "$R2" -ge 13 ] && [ "$E2" -ge 1 ] \
  && ok "cycle 2 replays the handshake: CALL=$C2 RET=$R2 + marker" \
  || bad "cycle 2 incomplete: CALL=$C2 RET=$R2 e2e-lines=$E2"
P1=$(pipe_of 1); P2=$(pipe_of 2)
[ -n "$P1" ] && [ "$P1" != "$P2" ] && ok "cycle 2 came up on a NEW pipe ($P1 -> $P2)" \
  || bad "pipe name did not change across the bounce (old instance never died)"

# THE load-bearing assertion for 21e: EOF teardown must have reaped cycle 1's
# shim + PHP child. Give it a moment (the shim polls with a 100ms wait), then
# require exactly one of each — two means every bounce leaks a process pair.
sleep 3
NL=$(win_count launcher-win.exe); NS=$(win_count backend.exe); NA=$(win_count app.exe)
[ "$NL" = 1 ] && [ "$NS" = 1 ] && [ "$NA" = 1 ] \
  && ok "no leak after the bounce: launcher=$NL shim=$NS app=$NA" \
  || { bad "process LEAK (want 1/1/1, got launcher=$NL shim=$NS app=$NA) — the shim's pipe-EOF teardown did not run on Windows"; \
       win_rows launcher-win.exe; win_rows backend.exe; win_rows app.exe; }
win_rows launcher-win.exe > "$WORK/tasklist.after-cycle2.txt"
win_rows backend.exe >> "$WORK/tasklist.after-cycle2.txt"
win_rows app.exe >> "$WORK/tasklist.after-cycle2.txt"

# --- [6/7] a second bounce: leaks compound, one data point does not ----------
note "[6/7] second bounce (a single sample cannot tell 'clean' from 'slow leak')"
touch "$ROOT/src/backend.php"
for _ in $(seq 1 90); do
  [ "$(cycle_stat "$SHIM_LOG" 3 'L->P: CALL')" -ge 13 ] && break
  sleep 1
done
C3=$(cycle_stat "$SHIM_LOG" 3 'L->P: CALL'); R3=$(cycle_stat "$SHIM_LOG" 3 'P->L: RET')
E3=$(cycle_stat "$SHIM_LOG" 3 'WINDOW-E2E OK ping=pong')
[ "$C3" -ge 13 ] && [ "$R3" -ge 13 ] && [ "$E3" -ge 1 ] \
  && ok "cycle 3 also replays it: CALL=$C3 RET=$R3 + marker" \
  || bad "cycle 3 incomplete: CALL=$C3 RET=$R3 e2e-lines=$E3"
sleep 3
NL=$(win_count launcher-win.exe); NS=$(win_count backend.exe); NA=$(win_count app.exe)
[ "$NL" = 1 ] && [ "$NS" = 1 ] && [ "$NA" = 1 ] \
  && ok "still 1/1/1 after two bounces — the EOF teardown chain holds" \
  || { bad "process count GREW across bounces (launcher=$NL shim=$NS app=$NA)"; \
       win_rows backend.exe; win_rows app.exe; }
# `kill -0` against a dead NATIVE process: if Git Bash kept reporting the launcher
# alive, the inner watcher loop would never break and no respawn would happen at
# all — so reaching cycle 3 already proves it. Say so explicitly, but only if we
# actually got there (an earlier FAIL must not print a proven line).
if [ "$(cycles)" -ge 3 ]; then
  ok "Git Bash kill + kill -0 semantics proven by 3 live cycles on 3 distinct pipes"
fi

# --- [7/7] teardown: close the window, everything must unwind ----------------
note "[7/7] teardown: kill launcher-win.exe (== the user closed the window)"
for p in $(win_pids launcher-win.exe); do win_kill "$p"; note "taskkill'd launcher pid $p"; done
for _ in $(seq 1 20); do
  [ "$(win_count launcher-win.exe)" = 0 ] && [ "$(win_count backend.exe)" = 0 ] && [ "$(win_count app.exe)" = 0 ] && break
  sleep 1
done
win_rows launcher-win.exe > "$WORK/tasklist.teardown.txt"
win_rows backend.exe >> "$WORK/tasklist.teardown.txt"
win_rows app.exe >> "$WORK/tasklist.teardown.txt"
NL=$(win_count launcher-win.exe); NS=$(win_count backend.exe); NA=$(win_count app.exe)
[ "$NL$NS$NA" = "000" ] && ok "zero residue (launcher=$NL shim=$NS app=$NA)" \
  || { bad "processes survived the window close (launcher=$NL shim=$NS app=$NA)"; cat "$WORK/tasklist.teardown.txt"; }
for _ in $(seq 1 15); do kill -0 "$CLIPID" 2>/dev/null || break; sleep 1; done
kill -0 "$CLIPID" 2>/dev/null && bad "tgui dev is still running after the window closed" \
  || ok "tgui dev exited with the window"
grep -q '^\[shell\] done\|launcher closed' "$SHIM_LOG" \
  && ok "the shim logged its EOF teardown" || note "no explicit teardown line in the shim log (informational)"

echo
echo "== 21e windows dev driver: $([ $fail = 0 ] && echo PASS || echo FAIL)"
[ $compile_gap = 1 ] && echo "   NOTE: the shim's _WIN32 branch was NOT recompiled this run (step [2/7] skipped) — that gap stays open."
echo "   evidence: $WORK"
echo "   CLI log:  $CLI_OUT"
echo "   frame log: $SHIM_LOG  ($(cycles) cycles)"
echo "   A PASS here is real-desktop evidence (no Xvfb involved), which is what"
echo "   Phase 21e has been missing — and it retires README's 'Windows dev is"
echo "   single-shot after the fusion' note. Delete that note in the same commit."
exit $fail
