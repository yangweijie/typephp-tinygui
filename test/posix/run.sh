#!/usr/bin/env bash
# POSIX verification kit for planb/backend_shell.cpp  (Phase 16b).
#
# Verifies the *POSIX half* of the cross-platform shim — the part that cannot be
# compiled on the Windows dev box (MinGW has no fork/execv, no sys/un.h):
#   AF_UNIX endpoint creation, accept, the bidirectional poll/read pump, child
#   spawn over inherited stdio, and the clean teardown + socket unlink.
#
# It needs only g++ and python3: no GTK/webkit (so no `launcher-linux` build),
# no display, and no PHP AOT toolchain. Those are separate tiers — see README.md.
#
# Usage:
#   ./run.sh                     # default: 5 calls, mock backend
#   N_CALLS=20 ./run.sh
#   BACKEND_APP=/path/wrapper.php ./run.sh    # tier 2: real PHP backend
#
# Exit: 0 = every check passed, 1 = at least one failed, 2 = missing toolchain.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Resolve the shim whether this kit runs in-tree (<repo>/test/posix) or
# standalone after being copied out. See resolve-root.sh.
. "$HERE/resolve-root.sh"
typephp_locate "$HERE"
typephp_default_work "$HERE"
SRC="$TP_SHIM_SRC"
WORK="${WORK:-$TP_WORK}"
N_CALLS="${N_CALLS:-5}"
BACKEND_APP="${BACKEND_APP:-$HERE/mock_backend.py}"

SHIM="$WORK/backend_shell"
SLOG="$WORK/shim.log"
LOUT="$WORK/launcher.out"

# The socket needs a path short enough for sun_path, so it is chosen after the
# scratch dir exists. typephp_socket_cleanup only has work to do in the rare
# case where that had to move the socket elsewhere.
trap typephp_socket_cleanup EXIT

pass=0
fail=0
ok()  { echo "  [PASS] $*"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $*"; fail=$((fail + 1)); }

# Refuse to run on Windows: there the shim compiles the _WIN32 branch and serves
# a NAMED PIPE, so every AF_UNIX assertion below would fail for the wrong reason.
# This check comes FIRST, before the toolchain probes: otherwise a Windows host
# reports "no python with socket.AF_UNIX", which is true but explains nothing.
# CYGWIN is accepted deliberately: Cygwin's g++ is a real POSIX target (it does
# NOT define _WIN32, so the shim takes the POSIX branch), and its runtime has
# fork/execv, poll, sys/un.h and AF_UNIX. That makes this kit runnable locally
# when no Linux box is available — see README.md for what that does and does not
# prove.
case "$(uname -s)" in
  Linux | Darwin | CYGWIN*) ;;
  *)
    echo "This kit verifies the POSIX branch, but this host is $(uname -s)."
    echo "On Windows the shim takes the _WIN32 path (named pipe, not AF_UNIX),"
    echo "so the AF_UNIX assertions would fail for the wrong reason."
    echo
    echo "Run it on Linux/macOS, OR under Cygwin's bash if you have it locally:"
    echo "  /cygwin64/bin/bash -lc 'cd \$(cygpath -u \"\$PWD\") && bash posix-test/run.sh'"
    echo "  (Cygwin g++ does not define _WIN32 and has AF_UNIX — a real POSIX target.)"
    exit 2 ;;
esac

if ! command -v g++ >/dev/null 2>&1; then
  echo "g++ not found — install build-essential"; exit 2
fi
# The fixture self-test drives mock_backend.py through mock_launcher.py, so its
# interpreter needs socket.AF_UNIX. Windows' native Python does not have it (a
# documented gap, not a version issue), which is why Cygwin's python — not the
# Windows one — has to win when running under Cygwin. Probe rather than trusting
# whichever `python3` happens to come first. (The C client below has no such
# dependency, so this only gates step [1/5].)
PY=""
for cand in python3 python; do
  p="$(command -v "$cand" 2>/dev/null)" || continue
  if "$p" -c 'import socket; socket.AF_UNIX' >/dev/null 2>&1; then PY="$p"; break; fi
done
if [ -z "$PY" ]; then
  echo "no python with socket.AF_UNIX found (tried: python3 python)"
  echo "  the fixture self-test needs one; under Cygwin use Cygwin's python3"
  exit 2
fi

echo "======================================================================"
echo " POSIX shim verification   (backend_shell.cpp @ $(uname -s))"
echo "======================================================================"

mkdir -p "$WORK"
typephp_socket_path "$WORK"
SOCK="$TP_SOCK"

# -------------------------------------------------------------- fixtures ----
echo "== [1/5] fixture self-test (mock launcher vs mock backend) =="
if "$PY" "$HERE/selftest_fixtures.py" >"$WORK/fixtures.out" 2>&1; then
  ok "kit fixtures agree on the frame protocol"
else
  bad "fixture self-test FAILED — do not blame the shim until this is green"
  sed 's/^/     /' "$WORK/fixtures.out"
fi

# ---------------------------------------------------------------- build -----
echo "== [2/5] build the POSIX branch =="
rm -f "$SHIM"
if g++ -std=c++17 -O2 -Wall -Wextra -o "$SHIM" "$SRC" 2>"$WORK/build.log"; then
  ok "compiled clean with -Wall -Wextra ($(wc -c <"$SHIM" | tr -d ' ') bytes)"
else
  bad "compile FAILED — this is the branch Windows could not check"
  sed 's/^/     /' "$WORK/build.log"
  echo; echo "RESULT: $pass passed, $fail failed"; exit 1
fi
if [ -s "$WORK/build.log" ]; then
  echo "     warnings:"; sed 's/^/       /' "$WORK/build.log"
else
  ok "no warnings"
fi

# Client selection. C is preferred even on Linux: it mirrors the real C++
# launcher, and under Cygwin it is REQUIRED — CPython's AF_UNIX sockets there do
# not interoperate with native AF_UNIX (C server + Python client => accept()
# ECONNABORTED), which would look like a shim bug. See mock_launcher.c.
CLIENT="${CLIENT:-auto}"
CC_BIN="${CC:-gcc}"
command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN="g++ -x c"
if [ "$CLIENT" != "py" ]; then
  # shellcheck disable=SC2086
  if $CC_BIN -O2 -Wall -Wextra -o "$WORK/mock_launcher" "$HERE/mock_launcher.c" \
       >"$WORK/cc.log" 2>&1; then
    ok "built the C client (mock_launcher)"
    CLIENT_BIN="$WORK/mock_launcher"
  else
    echo "     C client build failed:"; sed 's/^/       /' "$WORK/cc.log"
    if [ "$CLIENT" = "bin" ]; then
      bad "CLIENT=bin was requested but the C client did not build"
      echo; echo "RESULT: $pass passed, $fail failed"; exit 1
    fi
    CLIENT_BIN=""
  fi
fi
if [ -z "${CLIENT_BIN:-}" ]; then
  CLIENT_BIN="$PY $HERE/mock_launcher.py"
  ok "using the Python client (mock_launcher.py)"
  case "$(uname -s)" in
    CYGWIN*)
      echo "     NOTE: on Cygwin the Python client cannot talk to a C shim"
      echo "           (CPython AF_UNIX and native AF_UNIX do not interoperate)"
      echo "           — install gcc, or expect the exchange step to fail." ;;
  esac
fi

# ---------------------------------------------------------------- start -----
echo "== [3/5] start the shim (backend: $BACKEND_APP) =="
chmod +x "$HERE/mock_backend.py" "$HERE/mock_launcher.py" 2>/dev/null || true
chmod +x "$BACKEND_APP" 2>/dev/null || true    # shebang'd script == the backend
rm -f "$SOCK" "$SLOG" "$LOUT"

# dev mode: argv[1] is the endpoint name. TYPEPHP_APP overrides which binary the
# shim spawns (launch mode would read <exe_stem>.conf instead).
TYPEPHP_SHELL_LOG="$SLOG" TYPEPHP_APP="$BACKEND_APP" \
  "$SHIM" "$SOCK" >"$WORK/shim.out" 2>&1 &
SHIM_PID=$!

for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
if [ -S "$SOCK" ]; then
  ok "AF_UNIX listening socket created: $SOCK"
else
  bad "socket never appeared — bind/listen failed"
  sed 's/^/       /' "$SLOG" 2>/dev/null | tail -5
  kill "$SHIM_PID" 2>/dev/null
  echo; echo "RESULT: $pass passed, $fail failed"; exit 1
fi
grep -q "transport=unix-socket" "$SLOG" 2>/dev/null \
  && ok "shim reports transport=unix-socket" \
  || bad "shim did not log transport=unix-socket"

# --------------------------------------------------------------- exchange ---
echo "== [4/5] frame exchange over the socket =="
# shellcheck disable=SC2086
if $CLIENT_BIN "$SOCK" "$N_CALLS" >"$LOUT" 2>&1; then
  ok "protocol round-trip clean over AF_UNIX"
else
  bad "protocol mismatch / stall"
fi
sed 's/^/     /' "$LOUT"

# ---------------------------------------------------------------- teardown --
echo "== [5/5] teardown =="
# The mock launcher closed its end, so the shim must notice and exit on its own.
waited=0
for _ in $(seq 1 100); do
  kill -0 "$SHIM_PID" 2>/dev/null || { waited=1; break; }
  sleep 0.1
done
if [ "$waited" -eq 1 ]; then
  wait "$SHIM_PID"; rc=$?
  [ "$rc" -eq 0 ] && ok "shim exited 0 on its own" || bad "shim exit code $rc"
else
  bad "shim still running after the peer closed (teardown stuck)"
  kill "$SHIM_PID" 2>/dev/null
fi
grep -q "launcher closed" "$SLOG" 2>/dev/null \
  && ok "shim logged 'launcher closed'" \
  || bad "shim never noticed the peer going away"
grep -q "write to backend failed" "$SLOG" 2>/dev/null \
  && bad "shim hit 'write to backend failed'" \
  || ok "no backend write failures"
if [ -e "$SOCK" ]; then
  bad "socket file left behind: $SOCK (would block the next bind)"
else
  ok "socket file unlinked on exit"
fi

echo
echo "----------------------------------------------------------------------"
# `grep -c` prints 0 and exits 1 when nothing matches, so `|| echo 0` would emit a
# second line; normalise explicitly instead.
f_call="$(grep -c 'L->P: CALL' "$SLOG" 2>/dev/null || true)"; f_call="${f_call:-0}"
f_ret="$(grep -c 'P->L: RET' "$SLOG" 2>/dev/null || true)";  f_ret="${f_ret:-0}"
printf "frames: CALL=%s RET=%s\n" "$f_call" "$f_ret"
echo "log: $SLOG"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "POSIX BRANCH OK"
