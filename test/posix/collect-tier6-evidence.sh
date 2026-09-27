#!/usr/bin/env bash
# Phase 24 (candidate ⑤) evidence collector — RE-DERIVE, never restate.
#
# test/posix/tier6-nano-aggregate.sh prints its own verdict, but a verdict printed
# by the thing under test is not evidence. This script reads the STORED 24-* files
# under evidence/linux/ and recomputes every number the README and the plan files
# quote. Run it after copying new evidence in, or with REGEN=1 to rewrite the
# manifest from the stored files alone:
#
#   bash test/posix/collect-tier6-evidence.sh            # verify stored set
#   REGEN=1 bash test/posix/collect-tier6-evidence.sh    # rewrite the manifest
#
# Exit 0 = every derived claim holds; 1 = at least one does not.
#
# What "PASS" means here, precisely: the aggregated backend clears nano's front
# end, and the FULL build stops in ld on an upstream symbol (php::Args::get) that
# no composed object defines. [4c] is what turns that from a claim into a
# measurement — same Closure object, same undefined symbol, small link succeeds —
# so this collector asserts the GAP as loudly as it asserts the oks.
set -u
EV="${EV:-evidence/linux}"
OUT="$(cd "$EV" && pwd)/24-MANIFEST.txt"   # absolute: this script cd's into $EV
REGEN="${REGEN:-0}"
fail=0

[ -d "$EV" ] || { echo "no $EV"; exit 2; }
cd "$EV" || exit 2
for f in 24-tier6-driver.log 24-tier6-report.txt 24-nano-aggregate-build.log \
         24-nano-control-build.log 24-nano-startup-probe-build.log \
         24-nano-unaggregated.log 24-nano-dry.log 24-closure-nm.txt \
         25-deps-vs-modules.txt 25-upstream-probe.txt 25-naive-fix-fails.log; do
  [ -f "$f" ] || { echo "MISSING $f"; exit 2; }
done

note() { printf '%s\n' "$*"; }
chk() {   # <label> <expected-regex> <file...>
  local label=$1 re=$2; shift 2
  if grep -qE "$re" "$@" 2>/dev/null; then note "   ok   $label"
  else note "   FAIL $label (no /$re/ in $*)"; fail=1; fi
}
noch() {  # <label> <forbidden-regex> <file...>
  local label=$1 re=$2; shift 2
  if grep -qE "$re" "$@" 2>/dev/null; then note "   FAIL $label (found /$re/ in $*)"; fail=1
  else note "   ok   $label"; fi
}
val() { printf '   %-52s %s\n' "$1" "$2"; }

# --- derived from 24-tier6-driver.log ----------------------------------------
MODS=$(grep -oE 'aggregated [0-9]+ module' 24-tier6-driver.log | grep -oE '[0-9]+' | head -1)
AGGBYTES=$(grep -oE '\([0-9]+ B, [0-9]+ lines\)' 24-tier6-driver.log | grep -oE '[0-9]+' | head -1)
AGGLINES=$(grep -oE '\([0-9]+ B, [0-9]+ lines\)' 24-tier6-driver.log | grep -oE '[0-9]+' | tail -1)
DRY=$(grep -c '^\s*ok   nano front end accepts the aggregate' 24-tier6-driver.log)
LINKGAP=$(grep -c "undefined reference to .php::Args::get" 24-nano-aggregate-build.log)
CLO_BIG=$(grep -oE 'closure-[0-9a-f]+\.o' 24-closure-nm.txt | head -1)
CLO_SMALL=$(grep -oE 'closure-[0-9a-f]+\.o' 24-closure-nm.txt | tail -1)
OBJ_BIG=$(grep -oE 'objects=[0-9]+' 24-closure-nm.txt | head -1 | cut -d= -f2)
OBJ_SMALL=$(grep -oE 'objects=[0-9]+' 24-closure-nm.txt | tail -1 | cut -d= -f2)
DEFS=$(grep -c 'define=\[\]' 24-closure-nm.txt)
HASHES=$(sed -n 's/^ *\([0-9a-f]\{16\}\) closure.*/\1/p' 24-closure-nm.txt | sort -u | wc -l | tr -d ' ')
RETS=$(grep -oE 'stock-php equivalence: RET=[0-9]+' 24-tier6-report.txt | cut -d= -f2)

M=$(mktemp); {
  note "# Phase 24 / candidate ⑤ — --nano SINGLE-FILE AGGREGATION evidence"
  note "# collected: $(date -u +%Y-%m-%dT%H:%M:%SZ) by test/posix/collect-tier6-evidence.sh"
  note "# source:    /tmp/tpgui-tier6 inside the Apple Container 'tgl' (Debian bookworm, arm64)"
  note "# repo rev:  $(git -C ../.. rev-parse --short HEAD 2>/dev/null || echo '?')"
  note "# inputs:    tools/aggregate-backend.php + test/posix/tier6-nano-aggregate.sh"
  note "#            harness hashes: see == harness as committed below"
  note "# stored-set provenance: every file below comes out of ONE cold driver run"
  note "#   (rm -rf /tmp/tpgui-tier6 first, so nothing is [cached]), except"
  note "#   24-closure-nm.txt, which test/posix/tier6-nm-evidence.sh generates"
  note "#   from the object sets + logs that same run left behind."
  note "#   24-nano-dry.log is the driver's own [4a] output — the cold work dir is what"
  note "#   lets claim 8c assert the absence of [cached] reuse honestly."
  note "#   the container's copies of tools/aggregate-backend.php and"
  note "#   test/posix/tier6-nano-aggregate.sh were md5-matched against these host files"
  note "#   before the run — see the == inputs section at the bottom."
  note "# driver:    PHP_BIN=php8.4 TPC=/work/tpc/bin/tpc.php bash test/posix/tier6-nano-aggregate.sh"
  note "#            -> expected final line while both upstream gaps are open:"
  note "#              == tier-6 result: PASS-with-recorded-GAP (2 upstream gap(s): link:php::Args::get | startup:basic_functions)"
  note "#            (the gap list is derived from the driver's own GAP lines, so it grows"
  note "#             or shrinks with reality instead of being a fixed string.)"
  note "# SUPERSEDED IN PART — Phase 25 (2026-09-27). The [4c] ok line stored in"
  note "#   24-tier6-driver.log line 65 said: \"the aggregated build keeps"
  note "#   basic_functions_module, so its ZEND_MOD_REQUIRED(Core) is satisfiable'."
  note "#   That inference is FALSE and Phase 25 measured it: basic_functions_module is"
  note "#   named \"standard\" (php-nano ext/standard/basic_functions.c), and the ONLY entry"
  note "#   named \"Core\" is a static zend_module_entry in Zend/zend_builtin_functions.c, so"
  note "#   no composed array can ever satisfy that dep — the aggregate included. Once the"
  note "#   Args link gap was patched locally, the linked aggregate died with the same"
  note "#   \"Unable to start PHP Nano extensions\" as the 3-line probe. Claims 18c-18e below"
  note "#   derive that correction from evidence/linux/25-*; the raw Phase 24 logs are kept"
  note "#   unmodified as what that run actually printed."
  note "# this file is RE-DERIVED from the stored 24-* files below, not copied from stdout."
  note
  note "== derived claims"
  chk  "1 aggregation ran and lists its modules"        '^[[:space:]]*aggregated [0-9]+ module\(s\)' 24-tier6-driver.log
  chk  "2 determinism + --check + the three refusal paths" '^   ok   deterministic: re-aggregation is byte-identical' 24-tier6-driver.log
  chk  "3 the aggregator refuses a dynamic require"     '^   ok   refuses a dynamic require' 24-tier6-driver.log
  chk  "4 entry hoist: exactly one global main()"       '^   ok   exactly one hoisted entry function main\(\)' 24-tier6-driver.log
  chk  "5 every module keeps its own namespace scope"   '^   ok   every module keeps its own namespace scope' 24-tier6-driver.log
  chk  "6 stock-PHP behaviour is byte-identical"        '^   ok   byte-identical frames after masking' 24-tier6-driver.log
  chk  "7 negative control: unaggregated entry still refused" '^   ok   tpc --nano on src/backend.php fails as Errors #22 recorded' 24-tier6-driver.log
  chk  "7b the refusal is the require rule, verbatim"   '`require` is not supported in nano mode' 24-nano-unaggregated.log
  chk  "8 nano FRONT END accepts the aggregate (--dry)" '^   ok   nano front end accepts the aggregate' 24-tier6-driver.log
  chk  "8b --dry generated C++ out of it"                'Dry run completed: [0-9]+ C\+\+ source file' 24-nano-dry.log
  noch "8c ...from a cold cache: no [cached] reuse line" '^\[cached\]' 24-nano-dry.log
  chk  "9 the full build stops in ld, by signature"     "^   GAP  full --nano link blocked upstream" 24-tier6-driver.log
  chk  "10 the undefined symbol is really upstream's"   'undefined reference to .php::Args::get' 24-nano-aggregate-build.log
  chk  "11 control links (its build log says so)"        '^Build successful' 24-nano-control-build.log
  chk  "12 control link line present"                    'g\+\+ .* -o .*app-ctrl' 24-nano-control-build.log
  chk  "13 no composed object defines php::Args::get"    "^== php::Args::get over the composed nano object sets" 24-closure-nm.txt
  chk  "14 the control binary runs"                      '^nano-ctrl-ok a$' 24-closure-nm.txt
  chk  "15 the aggregate keeps basic_functions alive"    'nanobuild: basic_functions_module' 24-closure-nm.txt
  chk  "16 [4d] the startup probe links"                 '^Build successful: .*/app-trap' 24-nano-startup-probe-build.log
  chk  "17 [4d] ...and still cannot start"               '^Unable to start PHP Nano extensions' 24-closure-nm.txt
  chk  "18 [4d] its own set holds no modules at all"     '^  module set  : *$' 24-closure-nm.txt
  chk  "18b [4d] while requiring a module named Core"     'ZEND_MOD_REQUIRED\("Core"\)' 24-closure-nm.txt
  # 18c-18e: the Phase 25 correction, derived from the 25-* transcripts.
  chk  "18c the aggregate itself also declares ZEND_MOD_REQUIRED(\"Core\")" \
       '^    requires : standard date hash json pcre Core SPL' 25-deps-vs-modules.txt
  chk  "18d and the linked aggregate dies at startup too" \
       'app-nano-fixed .*rc=1 .*Unable to start PHP Nano extensions' 25-deps-vs-modules.txt
  chk  "18e both repros re-run on the stock (unpatched) tree" \
       'strlen program is reproducible on an unmodified' 25-deps-vs-modules.txt
  chk  "18f the only \"Core\" entry is static, so no array can hold it" \
       'static zend_module_entry zend_builtin_module' 25-deps-vs-modules.txt
  [ "$DEFS" = 2 ] && note "   ok   define=[] in BOTH object sets ($DEFS/2) — nothing to link against" \
                  || { note "   FAIL define=[] not found in both sets (got $DEFS/2)"; fail=1; }
  [ -n "$CLO_SMALL" ] && [ "$CLO_SMALL" = "$CLO_BIG" ] \
    && note "   ok   both builds compose the SAME Closure TU ($CLO_BIG)" \
    || { note "   FAIL Closure TU differs: $CLO_BIG vs $CLO_SMALL"; fail=1; }
  [ "$HASHES" = 1 ] && note "   ok   ... byte-for-byte (one distinct sha256 over the two copies)" \
                   || { note "   FAIL the two closure objects differ in content ($HASHES hashes)"; fail=1; }
  [ "${OBJ_BIG:-0}" -gt "${OBJ_SMALL:-0}" ] \
    && note "   ok   and only the BIG link ($OBJ_BIG objects) fails; the control's $OBJ_SMALL link" \
    || { note "   FAIL object counts do not order as expected ($OBJ_BIG vs $OBJ_SMALL)"; fail=1; }
  chk  "19 the driver's own verdict line is the gap-carrying one" '^== tier-6 result: PASS-with-recorded-GAP' 24-tier6-driver.log
  note
  note "== numbers the docs quote (all recomputed here)"
  val "modules aggregated"        "${MODS:-?}"
  val "aggregated file"           "${AGGBYTES:-?} B / ${AGGLINES:-?} lines (build/, gitignored)"
  val "stock-PHP RET frames"      "${RETS:-?}"
  val "nano --dry accepted"       "$([ "${DRY:-0}" -ge 1 ] && echo yes || echo NO)"
  val "ld undefined-Args::get"    "$LINKGAP hit(s) in the aggregate build log"
  val "objects: aggregate/control" "$OBJ_BIG / $OBJ_SMALL"
  val "closure TU"                "$CLO_BIG"
  note
  note "== stored files (sha256, bytes)"
  for f in 24-tier6-driver.log 24-tier6-report.txt 24-nano-aggregate-build.log \
           24-nano-control-build.log 24-nano-startup-probe-build.log \
           24-nano-unaggregated.log 24-nano-dry.log 24-closure-nm.txt; do
    [ -f "$f" ] && note "   $(sha256sum "$f" | cut -d' ' -f1)  $f  $(wc -c <"$f" | tr -d ' ')B"
  done
  note "== phase 25 upstream-gap files (sha256, bytes)"
  note "#   25-upstream-probe.txt carries two in-file annotations: its section B printed"
  note "#   'modules []' from a broken grep, and mislabelled which of the two aggregates"
  note "#   printed 'Unhandled TypePHP exception'. Both are corrected there and in"
  note "#   25-deps-vs-modules.txt, which is the authoritative version."
  for f in 25-deps-vs-modules.txt 25-upstream-probe.txt 25-naive-fix-fails.log; do
    [ -f "$f" ] && note "   $(sha256sum "$f" | cut -d' ' -f1)  $f  $(wc -c <"$f" | tr -d ' ')B"
  done
  note
  note "== harness as committed (sha256; the run used md5-matched copies)"
  note "#   these hashes are of the CURRENT working-tree files, not of what the cold run"
  note "#   executed (that set was md5-matched at run time). They changed in Phase 25 when"
  note "#   the [4c]/[4d] wording was corrected, so a hash shift here is expected history,"
  note "#   not proof of a stale run."
  for p in ../../tools/aggregate-backend.php ../../test/posix/tier6-nano-aggregate.sh \
           ../../test/posix/tier6-nm-evidence.sh ../../test/posix/collect-tier6-evidence.sh; do
    [ -f "$p" ] && note "   $(sha256sum "$p" | cut -d' ' -f1)  ${p#../../}"
  done
  note "== phase 25 probe harness (sha256)"
  for p in ../../test/posix/upstream-nano-probes/run-probes.sh \
           ../../test/posix/upstream-nano-probes/nano_trap.php \
           ../../test/posix/upstream-nano-probes/nano_ctrl.php \
           ../../test/posix/upstream-nano-probes/nano_stdout.php \
           ../../test/posix/upstream-nano-probes/nano_stream.php \
           ../../test/posix/upstream-nano-probes/nano_devio.php \
           ../../test/posix/upstream-nano-probes/nano_file.php; do
    [ -f "$p" ] && note "   $(sha256sum "$p" | cut -d' ' -f1)  ${p#../../}"
  done
  note
  note "== verdict as the driver printed it"
  grep '^== tier-6 result' 24-tier6-driver.log | sed 's/^/   /'
} > "$M"

cat "$M"
if [ "$REGEN" = 1 ]; then
  cp "$M" "$OUT"; chmod 644 "$OUT"; rm -f "$M"
  echo "rewrote $OUT"
  [ $fail = 0 ] || { echo "NOTE: rewritten from a stored set that still has FAILs"; exit 1; }
  exit 0
fi
# The manifest carries its own collection timestamp, so compare everything except
# that one line — otherwise a faithful regeneration would always look "stale".
if [ -f "$OUT" ]; then
  diff <(grep -v '^# collected:' "$OUT") <(grep -v '^# collected:' "$M") >/dev/null 2>&1 \
    && echo "   ok   24-MANIFEST.txt matches a fresh derivation" \
    || { echo "   FAIL 24-MANIFEST.txt is stale or was hand-edited — rerun with REGEN=1"; fail=1; }
else
  echo "   FAIL no 24-MANIFEST.txt yet — run with REGEN=1"; fail=1
fi
rm -f "$M"
echo
echo "== collect-tier6-evidence: $([ $fail = 0 ] && echo 'ALL CLAIMS DERIVE CLEAN' || echo 'CLAIMS FAILED')"
exit $fail
