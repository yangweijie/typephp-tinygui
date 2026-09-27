#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 24 — tier 6: the REAL nano target, compiled from the shipping backend.
# Run INSIDE the Linux container (needs tpc + php-nano, see docs/planning).
#
# Phase 16b-2 measured `tpc --nano` on a 5-line program and recorded Errors #22:
# the demo backend `require`s its framework, and real nano refuses `require` at
# compile time, so the shipping backend could never be built for the freestanding
# target. This driver closes that gap with tools/aggregate-backend.php and proves
# three separate things, each with a control that can fail:
#
#   [1] aggregation is deterministic and refuses what it cannot prove safe
#   [2] the aggregated file is BEHAVIOURALLY IDENTICAL to the multi-file tree
#       (same frames in, byte-identical frames out under stock PHP) — this is the
#       claim that matters, because a "smaller binary" that answers differently
#       would be a regression dressed as a win
#   [3] real nano still refuses the UNAGGREGATED entry (negative control: if this
#       starts passing, the finding it rests on is stale)
#   [4a] real nano ACCEPTS the aggregated file at its front end (--dry): the
#        require refusal of Errors #22 is gone, and so are the two rules found
#        behind it (no top-level code, entry = global function main())
#   [4b] the full --nano build+link, and if a binary appears, size + ldd (no
#        libphp) + the same frames as stock PHP. As of php-nano v1.0.1 this step
#        stops in ld on an upstream symbol gap, so it is reported as a GAP that
#        matches a signature — not as a pass, and not as our failure.
#   [4c] attributes that gap by measurement instead of assertion: a ~15-line
#        program with the same constructs LINKS (and runs), and both builds
#        compose the byte-identical Closure object that carries the undefined
#        symbol. Link and run are separate assertions — see [4d].
#   [4d] the other nano trap, so nobody re-reads [4b] wrong later: a nano binary can
#        link cleanly and still die at startup, because the generated module entry may
#        declare ZEND_MOD_REQUIRED("Core") while php-nano resolves required deps only
#        against the composed array — and the one module named "Core" is `static`
#        inside Zend/zend_builtin_functions.c, so NO composed array can ever hold it.
#        That makes the dep unsatisfiable for every nano build, this aggregate
#        included: Phase 25 measured the linked aggregate dying at startup exactly
#        like the 3-line probe. (Phase 24's own [4c] line claimed the opposite from
#        "the set keeps basic_functions_module"; basic_functions_module is named
#        "standard", so that was an inference dressed as a measurement — see
#        docs/upstream-issues/ and evidence/linux/25-*.)
#
# Expected final line when the upstream gaps are still open:
#   == tier-6 result: PASS-with-recorded-GAP (2 upstream gap(s): link:php::Args::get | startup:basic_functions)
# The second tag names the module that probe's set dropped; the decisive condition is
# the unsatisfiable ZEND_MOD_REQUIRED("Core") (see [4d] above). The gap list is derived
# from the driver's own GAP lines, so it changes with reality rather than being fixed.
#
# Usage (from the repo root inside the container):
#   PHP_BIN=php8.4 TPC=/work/tpc/bin/tpc.php bash test/posix/tier6-nano-aggregate.sh
#
# TPC is the compiler ENTRY script, not /work/tpc/cli.php: cli.php is a
# `include $argv[1]; main()` wrapper, so pointing at it makes tpc run our backend
# as PHP (it prints READY and answers stdin) and then die on `undefined function
# main()` — a silent, misleading pass-through rather than a compile.
# ---------------------------------------------------------------------------
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/tpgui-tier6}"; mkdir -p "$WORK"
PHP_BIN="${PHP_BIN:-$(command -v php8.4 || command -v php)}"
TPC="${TPC:-/work/tpc/bin/tpc.php}"
# Underscore, not a dot: tpc --nano derives the target name from the source
# basename and rejects anything that is not a valid identifier
# ("The target name `backend.aggregated` must be a valid identifier").
AGG="$ROOT/build/backend_aggregated.php"
FRAMES="$WORK/frames.txt"
fail=0
gaps=0
GAPLIST=""

note() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; fail=1; }
gap()  { printf '   GAP  %s\n' "$2"; gaps=$((gaps + 1)); GAPLIST="${GAPLIST:+$GAPLIST | }$1"; }
sect() { printf '\n== %s\n' "$*"; }
rec()  { note "$*"; printf '%s\n' "$*" >> "$WORK/tier6-report.txt"; }
: > "$WORK/tier6-report.txt"

[ -x "$PHP_BIN" ] || [ -n "$(command -v "$PHP_BIN")" ] || { echo "php missing: $PHP_BIN"; exit 2; }
[ -f "$TPC" ] || { echo "tpc entry missing: $TPC (set TPC=)"; exit 2; }
note "php: $("$PHP_BIN" -r 'echo PHP_VERSION;')"
note "tpc: $TPC"

# The frame fixture is deliberately stateful (store.set then store.get then
# store.all) and ends with `quit`, so an empty or truncated answer cannot slip
# through a diff that only looks at the first line.
cat > "$FRAMES" <<'EOF'
CALL 1 ["{\"method\":\"ping\",\"params\":{}}"]
CALL 2 ["{\"method\":\"api.fib\",\"params\":{\"n\":20}}"]
CALL 3 ["{\"method\":\"store.set\",\"params\":{\"key\":\"greeting\",\"value\":\"hi from nano\"}}"]
CALL 4 ["{\"method\":\"store.get\",\"params\":{\"key\":\"greeting\"}}"]
CALL 5 ["{\"method\":\"store.all\",\"params\":{}}"]
SYS theme {"dark":true,"accent":"#102030"}
CALL 6 ["{\"method\":\"theme.get\",\"params\":{}}"]
WINSTATE main {"visible":true,"maximized":false,"minimized":false,"fullscreen":false,"width":800,"height":600}
CALL 7 ["{\"method\":\"win.getState\",\"params\":{}}"]
CALL 8 ["{\"method\":\"nope.missing\",\"params\":{}}"]
CALL 9 ["{\"method\":\"sysinfo\",\"params\":{}}"]
CALL 10 ["{\"method\":\"listDir\",\"params\":{\"path\":\"src\"}}"]
CALL 11 ["{\"method\":\"quit\",\"params\":{}}"]
EOF

# Volatile sysinfo/listDir fields are masked by name, never by eyeball.
cat > "$WORK/normalize.py" <<'PY'
import json, re, sys

VOLATILE = ("pid", "runtime", "host", "cwd", "root", "home", "os", "backend", "cpu")

def norm(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        m = re.match(r"^(RET (\S+) (-?\d+) )(.*)$", line)
        if not m:
            out.append(line)
            continue
        payload = m.group(4)
        try:
            v = json.loads(payload)
        except Exception:
            out.append(line)
            continue
        if isinstance(v, dict):
            v = {k: x for k, x in v.items() if k not in VOLATILE}
            payload = json.dumps(v, sort_keys=True, ensure_ascii=False)
        elif isinstance(v, list) and payload.startswith("[{"):
            payload = json.dumps(v, sort_keys=True, ensure_ascii=False)
        out.append(m.group(1) + payload)
    return "\n".join(out)

print(norm(sys.argv[1]))
PY

# ---------------------------------------------------------------- [1] -----
sect "[1] aggregate the require graph"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" src/backend.php -o "$AGG" --root "$ROOT" \
  >"$WORK/aggregate.txt" 2>&1 \
  && ok "tools/aggregate-backend.php" || { bad "aggregation failed"; cat "$WORK/aggregate.txt"; exit 1; }
sed -n 's/^/   /p' "$WORK/aggregate.txt"
MODS=$(grep -c '^  - ' "$WORK/aggregate.txt")
[ "$MODS" -ge 15 ] && ok "pulled in $MODS modules" || bad "only $MODS modules — the require graph is bigger than that"
"$PHP_BIN" -l "$AGG" >/dev/null 2>&1 && ok "aggregated file parses" || bad "aggregated file does not parse"

# determinism: a second run must be byte-identical, and --check must agree
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" src/backend.php -o "$AGG.2" --root "$ROOT" --quiet \
  && cmp -s "$AGG" "$AGG.2" && ok "deterministic: re-aggregation is byte-identical" \
  || bad "aggregation is not deterministic"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" src/backend.php -o "$AGG" --check && ok "--check passes on a fresh output" || bad "--check disagrees with a fresh output"
printf 'x' >> "$AGG"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" src/backend.php -o "$AGG" --check 2>/dev/null
[ $? -eq 2 ] && ok "--check catches a stale output (exit 2)" || bad "--check did not flag a modified file"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" src/backend.php -o "$AGG" --root "$ROOT" --quiet

# refusals: the tool must not guess
printf '<?php\ndeclare(strict_types=1);\n$f = "x.php";\nrequire $f;\n' > "$WORK/dyn.php"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" "$WORK/dyn.php" -o "$WORK/dyn.agg" --root "$WORK" >/dev/null 2>&1 \
  && bad "accepted a dynamic require" || ok "refuses a dynamic require"
printf '<?php\ndeclare(strict_types=1);\nrequire_once "/etc/hostname";\n' > "$WORK/outside.php"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" "$WORK/outside.php" -o "$WORK/out.agg" --root "$WORK" >/dev/null 2>&1 \
  && bad "pulled a file in from outside --root" || ok "refuses a target outside --root"

# The __DIR__ guard has to be proven live, not trusted: token_get_all() on a body
# whose `<?php` was cut reads the whole file as T_INLINE_HTML, so a guard written
# against that stream matched nothing at all. Same for a namespaced require.
printf '<?php\ndeclare(strict_types=1);\nnamespace App;\nrequire_once __DIR__ . "/lib/lib.php";\n' > "$WORK/ent.php"
mkdir -p "$WORK/lib" && printf '<?php\ndeclare(strict_types=1);\nnamespace App\\Lib;\nclass Where { public function dir(): string { return __DIR__; } }\n' > "$WORK/lib/lib.php"
"$PHP_BIN" "$ROOT/tools/aggregate-backend.php" "$WORK/ent.php" -o "$WORK/ent.agg" --root "$WORK" >"$WORK/dirguard.log" 2>&1 \
  && bad "accepted a module that still uses __DIR__" || ok "refuses a surviving __DIR__"
grep -q 'still uses __DIR__' "$WORK/dirguard.log" || bad "__DIR__ refusal did not report its reason: $(tail -1 "$WORK/dirguard.log")"

# Executable code must be hoistable into the global main() tpc looks for.
grep -c '^function main(): void$' "$AGG" | grep -qx 1 \
  && ok "exactly one hoisted entry function main()" || bad "not exactly one 'function main(): void' in the aggregate"
grep -q '^namespace {$' "$AGG" \
  && ok "the global entry sits in its own namespace block" \
  || bad "no global `namespace {` block — main() would land in the last module's namespace and tpc would have no entry"
[ "$(grep -c '^namespace' "$AGG")" -eq "$MODS" ] \
  && ok "every module keeps its own namespace scope ($MODS blocks)" \
  || bad "module count ($MODS) != namespace block count ($(grep -c '^namespace' "$AGG"))"

# ---------------------------------------------------------------- [2] -----
sect "[2] the aggregated file behaves like the multi-file tree (stock PHP)"
run_stock() { ( cd "$ROOT" && "$PHP_BIN" "$1" < "$FRAMES" > "$2" 2>"$2.err" ); }
# The aggregate's entry lives inside function main() (nano has no top-level code),
# so stock PHP needs the one-line call tpc generates for itself.
( cd "$ROOT" && "$PHP_BIN" -r 'require $argv[1]; main();' "$AGG" < "$FRAMES" > "$WORK/agg.txt" 2>"$WORK/agg.txt.err" )
run_stock src/backend.php "$WORK/multi.txt"
"$PHP_BIN" "$WORK/normalize.py" "$WORK/multi.txt" > "$WORK/multi.norm"
"$PHP_BIN" "$WORK/normalize.py" "$WORK/agg.txt"   > "$WORK/agg.norm"
if diff -u "$WORK/multi.norm" "$WORK/agg.norm" > "$WORK/agg.diff"; then
  ok "byte-identical frames after masking volatile sysinfo fields"
else
  bad "aggregation changed behaviour:"; sed -n '1,20p' "$WORK/agg.diff"
fi
# The fixture must actually have been answered — a diff of two empty files proves nothing.
RETS=$(grep -c '^RET ' "$WORK/agg.txt" || true)
[ "${RETS:-0}" -ge 11 ] && ok "$RETS RET frames answered" || bad "only ${RETS:-0} RET frames — the fixture did not run"
grep -q '^RET 4 0 "hi from nano"' "$WORK/agg.txt" && ok "stateful round-trip present (store.get returned what store.set stored)" \
  || bad "store round-trip missing from the fixture output"
grep -q '^RET 11 0 true' "$WORK/agg.txt" && grep -q '^QUIT' "$WORK/agg.txt" \
  && ok "quit emitted QUIT before its RET (frame order intact)" \
  || bad "quit frame order changed"
rec "[2] stock-php equivalence: RET=$RETS diff=$( [ -s "$WORK/agg.diff" ] && echo non-empty || echo empty)"

# ---------------------------------------------------------------- [3] -----
sect "[3] negative control — real nano still refuses the unaggregated entry"
( cd "$ROOT" && "$PHP_BIN" "$TPC" src/backend.php --nano -o "$WORK/app-unagg" ) >"$WORK/nano-unagg.log" 2>&1
rc=$?
if grep -q '^READY' "$WORK/nano-unagg.log"; then
  # See the header: this means $TPC ran the backend as plain PHP instead of
  # compiling it (cli.php-style wrapper). Nothing here is a compile result.
  bad "\$TPC=$TPC is not the compiler entry — the backend ran as PHP (READY on stdout)"
elif [ $rc -ne 0 ] && grep -qiE 'require.*not supported|is not supported in nano mode' "$WORK/nano-unagg.log"; then
  ok "tpc --nano on src/backend.php fails as Errors #22 recorded"
  grep -m1 -iE 'not supported' "$WORK/nano-unagg.log" | sed 's/^/        /'
else
  bad "tpc --nano on the unaggregated entry exited $rc without the require refusal — either the control is broken or the finding is stale"
  tail -5 "$WORK/nano-unagg.log" | sed 's/^/        /'
fi
rec "[3] control: unaggregated --nano rc=$rc ($(grep -m1 -ioE 'require[^.]*not supported[^.]*' "$WORK/nano-unagg.log" | head -c 80))"

# ---------------------------------------------------------------- [4] -----
sect "[4] compile the aggregated backend for the freestanding nano target"
# 4a — fast front-end gate. --dry runs nano's parse/convert/arginfo stages, which
#      is exactly where the `require` refusal (Errors #22), the stray-code rule and
#      the entry-function rule live. This is the assertion that candidate ⑤ was
#      about, and it fails in seconds instead of minutes.
( cd "$ROOT" && "$PHP_BIN" "$TPC" "$AGG" --nano --dry --build-dir "$WORK/nanodry" -o "$WORK/app-dry" ) \
    >"$WORK/nano-dry.log" 2>&1 \
  && ok "nano front end accepts the aggregate (--dry: convert + arginfo generated)" \
  || { bad "nano rejects the aggregate at the front end:"; tail -15 "$WORK/nano-dry.log" | sed 's/^/        /'; }
rec "[4a] nano --dry front end: $([ -s "$WORK/nano-dry.log" ] && grep -qm1 'Dry run completed' "$WORK/nano-dry.log" && echo accepted || echo unknown)"

# 4b — the full build, in its own --build-dir (sharing /work/tpc/build with the
#      --dry run above is not something this check should depend on).
note "this is the slow part (full source build); see $WORK/nano-agg.log"
( cd "$ROOT" && "$PHP_BIN" "$TPC" "$AGG" --nano --no-progress --build-dir "$WORK/nanobuild" -o "$WORK/app-nano" ) \
    >"$WORK/nano-agg.log" 2>&1
crc=$?
# The one blocker left after 4a is upstream, not ours: the composed nano runtime
# links phpx's Closure.cc, whose makeScopedCallableImpl body calls php::Args::get,
# without the phpx core TU that defines Args::get — so the link dies on an
# undefined reference. [4c] is what turns "we believe it's upstream" into a
# measurement. Matched by signature on purpose: any *other* failure must fail
# loudly, and if upstream fixes this the block below stops taking the gap branch
# and starts asserting on the real binary.
UPSTREAM_LINK_SIG='undefined reference to .php::Args::get'
if [ $crc -ne 0 ] && grep -q "$UPSTREAM_LINK_SIG" "$WORK/nano-agg.log"; then
  gap "link:php::Args::get" "full --nano link blocked upstream ($UPSTREAM_LINK_SIG) — front end is clean"
  grep -m1 -B1 "$UPSTREAM_LINK_SIG" "$WORK/nano-agg.log" | sed 's/^/        /'
  NANO_LINK=gap
  rec "[4b] full --nano link: GAP (upstream) — $(grep -m1 "$UPSTREAM_LINK_SIG" "$WORK/nano-agg.log" | head -c 110)"
elif [ $crc -eq 0 ] && [ -x "$WORK/app-nano" ]; then
  ok "tpc --nano compiled the aggregated backend"
  NANO_LINK=ok
else
  bad "tpc --nano failed (rc=$crc) for a reason that is not the recorded upstream gap — last lines:"
  tail -25 "$WORK/nano-agg.log" | sed 's/^/        /'
  NANO_LINK=fail
fi

# 4c — attribute that gap, don't assert it. Build a ~15-line program that uses the
#      same constructs (closure created in a method, handed to usort) and compare
#      object sets: if the *same* Closure translation unit (same content hash) sits
#      in both, with the same undefined php::Args::get, and only the small build
#      links, the blocker is which sections the composed runtime keeps alive — not
#      our PHP, and not this aggregator.
#
#      Link and run are asserted as two separate facts on purpose: a nano build can
#      link fine and still fail at startup ("Unable to start PHP Nano extensions"),
#      and reading one as the other would misattribute the [4b] gap. That second
#      failure is reproducible on its own — measured by [4d]: a 3-line program that
#      calls strlen gets ZEND_MOD_REQUIRED("Core") in its generated module entry, and
#      php-nano's dependency check only searches the composed list, so startup returns
#      FAILURE. `echo strlen("ab")`, `strcmp` and `array_key_exists` each reproduce it;
#      `implode`/`ucfirst` do not. Hence this control sorts with <=> only — NOT because
#      that would spare the aggregate: the "Core" name is unsatisfiable for every nano
#      build, this one included, which is what the block at the end of [4c] now records
#      (it used to claim the aggregate was unaffected — see [4d] and Phase 25).
sect "[4c] control — the same Closure object links in a minimal nano program"
if [ "${NANO_LINK:-}" != gap ]; then
  note "[4c] nothing to attribute (the full build $([ "${NANO_LINK:-}" = ok ] && echo linked || echo failed for another reason))"
else
  cat > "$WORK/nano_ctrl.php" <<'PHPCTRL'
<?php
declare(strict_types=1);

final class Sorter
{
    public function rows(): array
    {
        $out = [["name" => "b", "isDir" => false], ["name" => "a", "isDir" => true]];
        usort($out, function ($a, $b) {
            return [$b['isDir'], $a['name']] <=> [$a['isDir'], $b['name']];
        });
        return $out;
    }
}

function main(): void
{
    $s = new Sorter();
    echo "nano-ctrl-ok ", $s->rows()[0]['name'], "\n";
}
PHPCTRL
  ( cd "$WORK" && "$PHP_BIN" "$TPC" nano_ctrl.php --nano --no-progress --build-dir "$WORK/ctrlbuild" -o "$WORK/app-ctrl" ) \
      >"$WORK/nano-ctrl.log" 2>&1
  ctrl_rc=$?
  if [ $ctrl_rc -ne 0 ] || [ ! -x "$WORK/app-ctrl" ]; then
    bad "the control does NOT link (rc=$ctrl_rc) — then php-nano itself is broken in this container and the [4b] gap needs re-reading: $(tail -3 "$WORK/nano-ctrl.log" | head -2)"
  else
    ok "the minimal program links (rc=0, $(stat -c %s "$WORK/app-ctrl") B)"
    ctrl_out=$("$WORK/app-ctrl" 2>&1); ctrl_rrc=$?
    if [ $ctrl_rrc -eq 0 ] && printf '%s' "$ctrl_out" | grep -q 'nano-ctrl-ok'; then
      ok "and runs: $(printf '%s' "$ctrl_out" | head -1)"
    else
      gap "control:startup" "the control links but does not run (rc=$ctrl_rrc): $(printf '%s' "$ctrl_out" | head -1)"
      rec "[4c] control links but fails at startup (rc=$ctrl_rrc): $(printf '%s' "$ctrl_out" | head -1)"
    fi
    scan() {   # <dir> -> "<n> objects, define=<d>, reference=<r>"
      local d=$1 n=0 def=0 ref=0 o
      for o in $(find "$d" -name '*.o'); do
        n=$((n + 1))
        nm -C --defined-only "$o" 2>/dev/null | grep -q 'php::Args::get' && def=$((def + 1))
        nm -C --undefined-only "$o" 2>/dev/null | grep -q 'php::Args::get' && ref=$((ref + 1))
      done
      printf '%s objects, define php::Args::get=%s, reference it=%s' "$n" "$def" "$ref"
    }
    BIG=$(scan "$WORK/nanobuild/cache/objects")
    SMALL=$(scan "$WORK/ctrlbuild/cache/objects")
    note "failing build : $BIG"
    note "control build : $SMALL"
    CLO_BIG=$(basename "$(ls "$WORK"/nanobuild/cache/objects/nano/closure-*.o 2>/dev/null | head -1)")
    CLO_SMALL=$(basename "$(ls "$WORK"/ctrlbuild/cache/objects/nano/closure-*.o 2>/dev/null | head -1)")
    if [ -n "$CLO_BIG" ] && [ "$CLO_BIG" = "$CLO_SMALL" ]; then
      ok "both compose the same Closure TU ($CLO_BIG) — only the big link keeps its call section alive"
      rec "[4c] control: the minimal nano program links$([ "${ctrl_rrc:-1}" -eq 0 ] && echo ' AND runs'); same Closure TU $CLO_BIG"
      rec "[4c] failing build objects: $BIG"
      rec "[4c] control build objects : $SMALL"
    else
      bad "the Closure objects differ ($CLO_BIG vs $CLO_SMALL) — the gap is not attributable to runtime composition"
    fi
    # What [4c] can honestly say about this build and the startup trap: its set keeps
    # basic_functions_module (whose ->name is "standard"), and its entry declares
    # ZEND_MOD_REQUIRED("Core") — a name no composer array can ever hold. So the
    # aggregate is on the wrong side of [4d] too; it simply cannot be observed until
    # the [4b] link gap is closed upstream. Phase 25 did close it locally and the
    # linked aggregate then died exactly like the 3-line probe.
    AGG_DEPS=$(grep -h -o 'ZEND_MOD_REQUIRED("[A-Za-z_]*")' "$WORK"/nanobuild/extension-*.cc 2>/dev/null | sort -u | tr '\n' ' ')
    if grep -q 'basic_functions_module' "$WORK/nanobuild/composer_extensions.cpp"; then
      ok "the aggregated set keeps basic_functions_module (->name \"standard\"); deps: $AGG_DEPS"
      rec "[4c] aggregated runtime set: keeps basic_functions_module ($(grep -c '^    &' "$WORK/nanobuild/composer_extensions.cpp") modules listed); generated deps: $AGG_DEPS"
      case " $AGG_DEPS " in
        *'ZEND_MOD_REQUIRED("Core")'*)
          note "  and it declares ZEND_MOD_REQUIRED(\"Core\"), which no composed array can satisfy:"
          note "  this build is subject to [4d] as well (measured on the linked binary in Phase 25)." ;;
      esac
    else
      bad "the aggregated build drops basic_functions_module — the demo hits the startup gap even earlier"
    fi
  fi
fi

# 4d — the OTHER nano trap, measured so this file can say out loud why the [4c]
#      control sorts with <=> instead of strcmp. A 3-line `echo strlen("…")` build
#      links cleanly and the binary still dies: its generated module entry declares
#      ZEND_MOD_REQUIRED("Core"), php-nano's dependency check only searches the
#      composed set (php-nano/src/extension.cpp: dependency_state →
#      DependencyState::Invalid), and the one entry named "Core" is `static` inside
#      Zend/zend_builtin_functions.c — so it can never be in that set. Whether a
#      build also drops basic_functions_module is a second, separate observation (it
#      decides whether `standard` resolves, not `Core`), which is why the verdict
#      below comes from RUNNING the probe and the set is only reported as attribution.
#      Signature-matched on purpose: when upstream fixes either half, this turns into
#      an ok and stops being a GAP.
sect "[4d] a nano binary can link and still fail at startup (the strcmp/strlen trap)"
cat > "$WORK/nano_trap.php" <<'PHPTRAP'
<?php
declare(strict_types=1);

function main(): void
{
    echo strlen("nano-trap-probe"), "\n";
}
PHPTRAP
( cd "$WORK" && "$PHP_BIN" "$TPC" nano_trap.php --nano --no-progress --build-dir "$WORK/trapbuild" -o "$WORK/app-trap" ) \
    >"$WORK/nano-trap.log" 2>&1
trap_rc=$?
if [ $trap_rc -ne 0 ]; then
  bad "the [4d] probe did not even build (rc=$trap_rc): $(tail -3 "$WORK/nano-trap.log" | head -2)"
else
  DEP=$(grep -h -o 'ZEND_MOD_REQUIRED("[A-Za-z_]*")' "$WORK"/trapbuild/extension-*.cc 2>/dev/null | sort -u | tr '\n' ' ')
  KEEPS_BF=no
  grep -q 'basic_functions_module' "$WORK/trapbuild/composer_extensions.cpp" && KEEPS_BF=yes
  trap_out=$("$WORK/app-trap" 2>&1); trrc=$?
  # The gap tag stays `startup:basic_functions` because the stored Phase 24 evidence
  # (evidence/linux/24-*) was written with it; the condition it stands for is the
  # unsatisfiable ZEND_MOD_REQUIRED("Core").
  if [ $trrc -eq 0 ] && printf '%s' "$trap_out" | grep -qx '15'; then
    ok "the probe runs (prints 15) — the startup gap no longer reproduces (deps: $DEP, basic_functions kept=$KEEPS_BF)"
    rec "[4d] startup probe: LINKED AND RAN (deps: $DEP; basic_functions kept=$KEEPS_BF) — upstream gap closed"
  elif [ $trrc -ne 0 ] && printf '%s' "$trap_out" | grep -q 'Unable to start PHP Nano extensions'; then
    gap "startup:basic_functions" "clean link, dead startup — $DEP can never be composed (the only \"Core\" entry is static in Zend); basic_functions kept=$KEEPS_BF, rc=$trrc"
    rec "[4d] startup probe: LINKED but startup FAILED ($(printf '%s' "$trap_out" | head -1), rc=$trrc); generated deps: $DEP; basic_functions kept=$KEEPS_BF"
  else
    bad "the probe neither reproduced the startup gap nor ran cleanly (rc=$trrc): $(printf '%s' "$trap_out" | head -2)"
  fi
fi

if [ "${NANO_LINK:-}" = ok ]; then
  SZ=$(stat -c %s "$WORK/app-nano")
  cp "$WORK/app-nano" "$WORK/app-nano.stripped" && strip "$WORK/app-nano.stripped" 2>/dev/null
  SSZ=$(stat -c %s "$WORK/app-nano.stripped" 2>/dev/null || echo 0)
  ok "binary ${SZ} B (stripped ${SSZ} B)"
  LDD=$(ldd "$WORK/app-nano" 2>/dev/null | tr -s ' ')
  printf '%s\n' "$LDD" | sed 's/^/        /'
  if printf '%s' "$LDD" | grep -qi 'libphp'; then
    bad "the nano binary links libphp — that is a bin-mode build, not freestanding"
  else
    ok "ldd shows no libphp (freestanding: $(printf '%s' "$LDD" | grep -c '\.so') libs)"
  fi
  file "$WORK/app-nano" | sed 's/^/        /'

  # Same frames, same cwd, same env as the stock-PHP run — only the runtime differs.
  ( cd "$ROOT" && "$WORK/app-nano" < "$FRAMES" > "$WORK/nano.txt" 2>"$WORK/nano.txt.err" )
  nrc=$?
  note "freestanding binary exited $nrc (11 = it served QUIT and left)"
  "$PHP_BIN" "$WORK/normalize.py" "$WORK/nano.txt" > "$WORK/nano.norm"
  if diff -u "$WORK/multi.norm" "$WORK/nano.norm" > "$WORK/nano.diff"; then
    ok "the freestanding binary answers the SAME frames as stock PHP"
  else
    bad "nano output differs from stock PHP:"
    sed -n '1,40p' "$WORK/nano.diff"
  fi
  NRETS=$(grep -c '^RET ' "$WORK/nano.txt" || true)
  [ "${NRETS:-0}" -ge 11 ] && ok "$NRETS RET frames from the nano binary" || bad "only ${NRETS:-0} RET frames from the nano binary"
  grep -q '^READY' "$WORK/nano.txt" && ok "READY banner (the shim's startup signal) present" \
    || bad "no READY banner — the shim would never consider the backend up"
  # sysinfo must still be truthful, not merely masked: the nano binary has to
  # report its OWN runtime/pid/root, which is the whole point of the sysinfo
  # method. So mask for the diff, assert presence separately.
  "$PHP_BIN" -r '
    foreach (file($argv[1]) as $l) { if (preg_match("/^RET 9 0 /", $l)) { $v = json_decode(trim(substr($l, 8)), true);
      $missing = array_diff(["runtime","pid","cwd","root","os","backend","cpu"], array_keys($v));
      if ($missing) { fwrite(STDERR, "sysinfo lost: ".implode(",", $missing)."\n"); exit(1); }
      printf("runtime=%s os=%s backend=%s cpu=%s\n", $v["runtime"], $v["os"], $v["backend"], $v["cpu"]);
      exit(0); } }
    fwrite(STDERR, "no sysinfo RET\n"); exit(1);
  ' "$WORK/nano.txt" > "$WORK/sysinfo-nano.txt" 2>&1 \
    && ok "sysinfo still reports every field: $(cat "$WORK/sysinfo-nano.txt")" \
    || bad "sysinfo regressed under nano: $(cat "$WORK/sysinfo-nano.txt")"
  "$PHP_BIN" -r '
    foreach (file($argv[1]) as $l) { if (preg_match("/^RET 9 0 /", $l)) { $v = json_decode(trim(substr($l, 8)), true);
      printf("runtime=%s os=%s backend=%s cpu=%s\n", $v["runtime"] ?? "?", $v["os"] ?? "?", $v["backend"] ?? "?", $v["cpu"] ?? "?"); exit(0); } }
    exit(1);
  ' "$WORK/multi.txt" > "$WORK/sysinfo-stock.txt" 2>&1 || true
  note "stock-php sysinfo: $(cat "$WORK/sysinfo-stock.txt")"
  rec "[4] nano build: ok binary=${SZ}B stripped=${SSZ}B ldd-libphp=no RET=${NRETS}"
  rec "[4] sysinfo under nano : $(cat "$WORK/sysinfo-nano.txt")"
  rec "[4] sysinfo stock php  : $(cat "$WORK/sysinfo-stock.txt")"
fi

echo
if [ $fail = 0 ] && [ $gaps = 0 ]; then
  verdict='PASS'
elif [ $fail = 0 ]; then
  # A recorded, signature-matched blocker we do not own. Say so out loud: this
  # line is NOT a claim that a nano binary of the shipping backend exists.
  verdict="PASS-with-recorded-GAP ($gaps upstream gap(s): $GAPLIST)"
else
  verdict=FAIL
fi
echo "== tier-6 result: $verdict"
echo "== report: $WORK/tier6-report.txt"
sed -n 's/^/   /p' "$WORK/tier6-report.txt"
exit $fail
