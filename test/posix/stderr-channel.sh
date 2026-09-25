#!/usr/bin/env bash
# stderr-isolation probe for planb/backend_shell.cpp  (Phase 16b-1).
#
# The shim gives the backend THREE stdio channels: stdin/stdout carry frames,
# stderr is drained into the shim's own log and never forwarded. This script
# proves that separation is real rather than merely intended, using a backend
# that is actively hostile on stderr (`mock_backend_noisy.py`):
#
# Run A (NOISY_CHANNEL=stderr, the shipping behaviour)
#   - the protocol must stay clean, AND
#   - the noise must show up in the shim log as `[shell] backend stderr: …`.
# Run B (NOISY_CHANNEL=stdout, positive control)
#   - the identical decoy is pushed into the FRAME channel instead, and the
#     client MUST then fail.
#
# Run B is what gives run A its teeth. "The client passed" is worthless on its
# own — it could simply mean the decoy was never written. Flipping one env var
# and watching the same client break is what shows the decoy is genuinely
# protocol-breaking and that run A survived it for the right reason.
#
# Step [3/4] then repeats the exercise with the REAL `backend.php`, because the
# synthetic backend is only a stand-in for one specific real behaviour: the `log`
# case (`tiny.log(msg)`) is the single place in the shipping backend that writes
# to stderr. Mocking it proves the shim; driving it proves the pair.
#
# Why this is worth a whole tier: PHP's own error routing is version-dependent
# (8.5 sends notices to stderr, Cygwin's 7.4 sends them to stdout), so "which
# channel do diagnostics arrive on" is not something the shim can assume. Keeping
# them separate is the only arrangement that survives both.
#
# Usage:  ./stderr-channel.sh
# Exit:   0 = all checks passed, 1 = a check failed, 2 = missing toolchain.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/resolve-root.sh"
typephp_locate "$HERE"
SRC="$TP_SHIM_SRC"
WORK="${WORK:-$HERE/.work-stderr}"
N_CALLS="${N_CALLS:-4}"

SHIM="$WORK/backend_shell"
SOCK="$WORK/app.sock"

pass=0
fail=0
skip=0
ok()   { echo "  [PASS] $*"; pass=$((pass + 1)); }
bad()  { echo "  [FAIL] $*"; fail=$((fail + 1)); }
skip_() { echo "  [SKIP] $*"; skip=$((skip + 1)); }

# Same guard as run.sh: on Windows the shim compiles the _WIN32 branch and serves
# a named pipe, so none of this applies. CYGWIN is accepted on purpose.
case "$(uname -s)" in
  Linux | Darwin | CYGWIN*) ;;
  *)
    echo "This probe exercises the POSIX branch, but this host is $(uname -s)."
    exit 2 ;;
esac

if ! command -v g++ >/dev/null 2>&1; then
  echo "g++ not found — install build-essential"; exit 2
fi
CC_BIN="${CC:-gcc}"
command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN="g++ -x c"

echo "======================================================================"
echo " stderr channel isolation probe   (backend_shell.cpp @ $(uname -s))"
echo "======================================================================"

mkdir -p "$WORK"

# ---------------------------------------------------------------- build -----
echo "== [1/4] build the shim and the C client =="
if g++ -std=c++17 -O2 -Wall -Wextra -o "$SHIM" "$SRC" 2>"$WORK/build.log"; then
  ok "shim compiled clean with -Wall -Wextra"
else
  bad "shim compile FAILED"; sed 's/^/     /' "$WORK/build.log"
  echo; echo "RESULT: $pass passed, $fail failed"; exit 1
fi
# shellcheck disable=SC2086
if $CC_BIN -O2 -Wall -Wextra -o "$WORK/mock_launcher" "$HERE/mock_launcher.c" \
     >"$WORK/cc.log" 2>&1; then
  ok "built the C client (mock_launcher)"
else
  bad "C client build failed"
  sed 's/^/     /' "$WORK/cc.log"
  echo; echo "RESULT: $pass passed, $fail failed"; exit 1
fi

chmod +x "$HERE/mock_backend_noisy.py" 2>/dev/null || true

# One shim+client exchange.
#   $1 = label (names the log files)
#   $2 = backend executable (absolute — the shim execv()s TYPEPHP_APP verbatim)
#   $3 = extra env for the SHIM/BACKEND, e.g. "NOISY_CHANNEL=stdout" or ""
#   $4 = extra env for the CLIENT,      e.g. "MOCK_LOG_CALL=1"      or ""
# Leaves the client output in $WORK/client.<label>.out and the shim log in
# $WORK/shim.<label>.log; echoes the client's exit status on stdout (or NOSOCK).
run_case() {
  local label="$1" app="$2" benv="$3" cenv="$4"
  rm -f "$SOCK" "$WORK/shim.$label.log" "$WORK/client.$label.out"
  # shellcheck disable=SC2086
  env $benv TYPEPHP_SHELL_LOG="$WORK/shim.$label.log" TYPEPHP_APP="$app" \
    "$SHIM" "$SOCK" >/dev/null 2>&1 &
  local shim_pid=$!
  local i
  for i in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
  if [ ! -S "$SOCK" ]; then
    kill "$shim_pid" 2>/dev/null
    echo "NOSOCK"
    return
  fi
  # shellcheck disable=SC2086
  env $cenv "$WORK/mock_launcher" "$SOCK" "$N_CALLS" >"$WORK/client.$label.out" 2>&1
  local rc=$?
  # The client closed its end; the shim must finish by itself.
  for i in $(seq 1 100); do kill -0 "$shim_pid" 2>/dev/null || break; sleep 0.1; done
  kill "$shim_pid" 2>/dev/null
  wait "$shim_pid" 2>/dev/null
  echo "$rc"
}

# ---------------------------------------------------- A: the correct channel --
echo "== [2/4] run A — decoy on stderr (must stay off the wire) =="
rc_a="$(run_case a "$HERE/mock_backend_noisy.py" "NOISY_CHANNEL=stderr" "")"
if [ "$rc_a" = "NOSOCK" ]; then
  bad "the shim never created its socket"
  sed 's/^/     /' "$WORK/shim.a.log" 2>/dev/null | tail -5
  echo; echo "RESULT: $pass passed, $fail failed"; exit 1
fi

if [ "$rc_a" -eq 0 ]; then
  ok "client saw a clean protocol despite the noise ($N_CALLS CALL / $N_CALLS RET)"
else
  bad "client FAILED with the decoy on stderr (exit $rc_a) — the channels are not isolated"
  sed 's/^/     /' "$WORK/client.a.out"
fi

# The client accepts `RET <id> 0 ` prefixes, so a leaked decoy would have been
# consumed as the answer for that id. Assert none of them reached the wire.
frames="$WORK/shim.a.log"
leaked="$(grep -c '"decoy":true' "$frames" 2>/dev/null || true)"; leaked="${leaked:-0}"
in_frames="$(grep -c 'P->L: .*"decoy":true' "$frames" 2>/dev/null || true)"; in_frames="${in_frames:-0}"
if [ "$leaked" -gt 0 ] && [ "$in_frames" -eq 0 ]; then
  ok "all $leaked decoy frames stayed on stderr (0 forwarded to the launcher)"
else
  bad "decoy leaked onto the frame channel ($in_frames forwarded of $leaked written)"
  grep 'P->L: .*decoy' "$frames" 2>/dev/null | sed 's/^/     /' | head -4
fi

if [ "$in_frames" -eq 0 ]; then
  ok "no bogus frame was ever written toward the launcher"
else
  bad "$in_frames bogus frame(s) written toward the launcher"
fi

# The decoy must be *logged*, not swallowed — otherwise the change traded a
# protocol bug for a debugging blind spot.
logged="$(grep -c 'backend stderr: RET id' "$frames" 2>/dev/null || true)"; logged="${logged:-0}"
if [ "$logged" -eq "$N_CALLS" ]; then
  ok "every decoy was logged as a diagnostic ($logged/$N_CALLS)"
else
  bad "expected $N_CALLS 'backend stderr:' decoy lines, found $logged"
  grep 'backend stderr' "$frames" 2>/dev/null | sed 's/^/     /' | head -4
fi
grep -q 'backend stderr: PHP Notice: undefined variable in /srv/app/handler.php on line 42' "$frames" 2>/dev/null \
  && ok "the split stderr line was reassembled before logging (one line, not two)" \
  || bad "the partial stderr line was not reassembled into a single log line"
grep -qE 'backend stderr: PHP Notice: undefined variable in $' "$frames" 2>/dev/null \
  && bad "a half-line was logged before its newline arrived" \
  || ok "no truncated stderr line was logged early"

f_call="$(grep -c 'L->P: CALL' "$frames" 2>/dev/null || true)"; f_call="${f_call:-0}"
f_ret="$(grep -c 'P->L: RET' "$frames" 2>/dev/null || true)";  f_ret="${f_ret:-0}"
if [ "$f_call" -eq "$N_CALLS" ] && [ "$f_ret" -eq "$N_CALLS" ]; then
  ok "frame counts are exactly right (CALL=$f_call RET=$f_ret)"
else
  bad "unexpected frame counts (CALL=$f_call RET=$f_ret, want $N_CALLS each)"
fi

# ------------------------------------------- C: the REAL PHP backend's stderr --
#
# Steps [2/4] and [4/4] use a synthetic backend, which proves the shim. This step
# drives the shipping `backend.php` instead, so the pair is proven together: the
# `log` case is the one place in the real backend that writes to stderr, and
# `tiny.log(msg)` is a documented page API, so this path is reachable in practice
# and not just in a fixture.
#
# The wrapper is generated here rather than borrowed from tier2.sh so this script
# stands alone. PHP needs two path forms (Cygwin path in the shebang, Windows
# path for the script argument and for require) — see tier2.sh for why.
echo "== [3/4] real backend.php: tiny.log() must land in the shim log =="
PHP_EXE="${PHP_EXE:-}"
if [ -z "$PHP_EXE" ]; then
  for cand in php \
      "/cygdrive/d/git/php/tpc_v0.9.3_windows_x64/php.exe" \
      "/cygdrive/c/php/php.exe" /usr/bin/php; do
    p="$(command -v "$cand" 2>/dev/null)" || p="$cand"
    [ -x "$p" ] || continue
    v="$("$p" -r 'echo PHP_VERSION_ID;' 2>/dev/null || echo 0)"
    if [ "${v:-0}" -ge 80000 ] 2>/dev/null; then PHP_EXE="$p"; break; fi
  done
fi
to_php_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
PHPPROBE="$WORK/real_backend.php"
# The kit ships standalone, so the resolved default is not a guarantee —
# the backend under test is the user's. `BACKEND_PHP=` overrides.
BACKEND_PHP="${BACKEND_PHP:-$TP_BACKEND_DEF}"
if [ -z "$PHP_EXE" ]; then
  skip_ "no PHP >= 8.0 found (backend.php uses str_starts_with/str_contains)"
elif [ ! -f "$BACKEND_PHP" ]; then
  skip_ "no backend at $BACKEND_PHP — pass BACKEND_PHP=/path/to/backend.php"
else
  {
    printf '#!%s\n' "$(to_php_path "$PHP_EXE")"
    printf '<?php\n'
    printf 'require %s;\n' "$(printf "'%s'" "$(to_php_path "$BACKEND_PHP")")"
    printf 'main();\n'
  } >"$PHPPROBE"
  chmod +x "$PHPPROBE"

  rc_c="$(run_case c "$(to_php_path "$PHPPROBE")" "" "MOCK_LOG_CALL=1")"
  if [ "$rc_c" = "NOSOCK" ]; then
    bad "the shim never created its socket for the real-PHP run"
  elif [ "$rc_c" -eq 0 ]; then
    ok "real PHP backend completed $N_CALLS calls plus the log() call"
  else
    bad "real PHP backend run failed (exit $rc_c)"
    sed 's/^/     /' "$WORK/client.c.out"
  fi

  clog="$WORK/shim.c.log"
  # The exact line backend.php's `log` case produces: jenc("stderr-probe") adds
  # the quotes, and the shim prefixes everything it drains with its own tag.
  want='[shell] backend stderr: [php-backend] "stderr-probe"'
  if grep -qF "$want" "$clog" 2>/dev/null; then
    ok "the real backend's STDERR write reached the shim log, intact and prefixed"
  else
    bad "did not find '$want' in the shim log"
    grep 'backend stderr' "$clog" 2>/dev/null | sed 's/^/     /' | head -4
  fi
  # ...and, the point of the exercise, it must NOT have travelled toward the
  # launcher. Without this the step would pass even under the old merge.
  if grep -q 'P->L: .*php-backend' "$clog" 2>/dev/null; then
    bad "the PHP log line was forwarded to the launcher as a frame"
    grep 'P->L: .*php-backend' "$clog" | sed 's/^/     /' | head -4
  else
    ok "and it was never forwarded toward the launcher"
  fi
fi

# ------------------------------------------------------ B: positive control --
echo "== [4/4] run B — same decoy on stdout (control: MUST fail) =="
rc_b="$(run_case b "$HERE/mock_backend_noisy.py" "NOISY_CHANNEL=stdout" "")"
if [ "$rc_b" = "NOSOCK" ]; then
  bad "the control run could not start (no socket)"
else
  if [ "$rc_b" -ne 0 ]; then
    ok "control behaved as predicted: the client failed (exit $rc_b) once the decoy entered the frame channel"
    grep 'unexpected frame' "$WORK/client.b.out" 2>/dev/null | sed 's/^/         (control client said) /' \
      && ok "and it failed with an 'unexpected frame' symptom (the downstream effect of the decoy being taken as a reply)" \
      || bad "the control failed, but without an 'unexpected frame' symptom"
  else
    bad "control PASSED with a decoy RET on the frame channel — the probe proves nothing"
    sed 's/^/     /' "$WORK/client.b.out"
  fi
  # The decisive, log-based mirror of run A: here the decoys MUST be on the wire.
  # Asserting on the shim log rather than the client's wording keeps the control
  # independent of how the client happens to phrase its complaint.
  #
  # The count is only >=1 rather than ==N_CALLS, and deliberately so: the client
  # fails on the first mismatch and exits, so it never sends the later CALLs and
  # the backend never gets a chance to answer them. One decoy on the wire is
  # already conclusive — it is exactly what run A showed zero of.
  fwd_b="$(grep -c 'P->L: .*"decoy":true' "$WORK/shim.b.log" 2>/dev/null || true)"; fwd_b="${fwd_b:-0}"
  if [ "$fwd_b" -ge 1 ]; then
    ok "control: $fwd_b decoy(s) WERE forwarded to the launcher — the exact opposite of run A's 0"
  else
    bad "control: the decoy never reached the wire either, so the control proves nothing"
  fi
fi

echo
echo "----------------------------------------------------------------------"
echo "run A log (synthetic): $WORK/shim.a.log"
echo "run C log (real PHP) : $WORK/shim.c.log"
echo "run B log (control)  : $WORK/shim.b.log"
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
# A skip means "I could not run this here" (no PHP, or no backend to point at).
# Exit 2 rather than 0 so the omission is visible to a caller/CI instead of
# reading as "verified" — the same convention tier2.sh uses.
[ "$skip" -eq 0 ] || exit 2
echo "STDERR CHANNEL ISOLATION OK"
