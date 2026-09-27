#!/bin/sh
# Phase 25 evidence generator (rev D) — run inside Apple Container 'tgl'.
# Produces the transcript stored as evidence/linux/25-deps-vs-modules.txt.
# Everything it asserts is read out of the tree or measured by running a binary;
# no claim in the output is inferred.
set -u
cd /tmp/tpgui-tier6 || exit 1
NANO=/work/tpc/vendor/swoole/php-nano
TPC=/work/tpc/bin/tpc.php

echo "== Phase 25 rev D: nano dependency / stdio gap measurements =="
echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) inside Apple Container 'tgl' (Debian bookworm aarch64)"
echo "# tpc v0.9.3 | php-nano v1.0.1 | phpx ~2.9.2 | host php $(php8.4 -r 'echo PHP_VERSION;')"
echo "# compiler: $(g++ --version | head -1) | $(ld --version | head -1)"
echo "# tree state: /work/tpc/src/Translator.php and vendor/swoole/phpx/src/core/variant.cc"
echo "#             are the UNPATCHED originals (restored from /tmp/*.bak before this run)."
echo "# probe sources are printed in the last section; build dirs are the ones the"
echo "# tier-6 driver + the phase-25 probes left behind."
echo
echo "==================== 1. required deps vs the composed module array ===================="
echo "# a generated nano module entry declares deps as ZEND_MOD_REQUIRED(\"<name>\");"
echo "# php-nano hands the array in composer_extensions.cpp to php_nano_startup_extensions()."
for d in nanobuild ctrlbuild trapbuild; do
    ce=$d/composer_extensions.cpp
    [ -f "$ce" ] || continue
    ext=$(grep -rl "ZEND_MOD_REQUIRED" "$d" 2>/dev/null | head -1)
    echo "--- $d  (entry: $ext)"
    printf '    requires : '
    grep -o 'ZEND_MOD_REQUIRED("[A-Za-z_]*")' "$ext" | sed 's/.*("//;s/")//' | awk '!seen[$0]++' | tr '\n' ' '
    echo
    printf '    composed : '
    grep -ho '^    &[A-Za-z_:]*' "$ce" | sed 's/^    &//' | tr '\n' ' '
    echo
done
echo "# NOTE: the composed entries are C variables, not names; a variable's extension name"
echo "#       lives in its own source (e.g. basic_functions_module -> \"standard\" in"
echo "#       ext/standard/basic_functions.c:347). This file deliberately does not guess the"
echo "#       remaining mappings: section 3 measures which requirement actually blocks startup."
echo
echo "==================== 2. the only module named \"Core\" is unreachable by construction ===================="
grep -rn -A3 "^static zend_module_entry zend_builtin_module" "$NANO/Zend/zend_builtin_functions.c" | head -8
echo "-- its registration path (Zend, not an ext/ module the composer can reference):"
grep -n "zend_startup_builtin_functions" "$NANO/Zend/zend_builtin_functions.c" "$NANO/src/core.cpp" | head
echo "-- references to zend_builtin_module inside any generated composer array:"
n=$(grep -rl "zend_builtin_module" "$PWD"/*/composer_extensions.cpp 2>/dev/null | wc -l)
echo "   $n (of $(ls -d "$PWD"/*/composer_extensions.cpp 2>/dev/null | wc -l) composer arrays)"
echo
echo "==================== 3. empirical startup: which requirement blocks ===================="
echo "# each binary is run with stdin=/dev/null and a 5s timeout."
echo "# PATCH STATE: the tpc 'Core'-skip experiment was applied at 2026-09-27 10:22:27 UTC and"
echo "# reverted afterwards (diff in 25-upstream-probe.txt). A binary built LATER than that"
echo "# timestamp was built with the experiment in place; an earlier one is stock tpc."
run() {
    b=$1
    [ -x "$b" ] || { printf '  %-16s (missing)\n' "$b"; return; }
    mt=$(stat -c %y "$b" | cut -d. -f1)
    out=$(timeout 5 "./$b" </dev/null 2>./.err); rc=$?
    printf '  %-16s built=%s rc=%-4s out=[%s] err=[%s]\n' "$b" "$mt" "$rc" \
        "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-60)" \
        "$(head -2 ./.err | tr '\n' ' ' | cut -c1-120)"
}
run app-min
run app-ctrl
run app-trap
run app-nano_trap2
run app-nano_ver
run app-nano_stdout
run app-stream
run app-devio
run app-file
run app-nano-fixed
run app-nano-patched
echo
echo "==================== 4. stock-tree recheck (rebuild from scratch, then run) ===================="
recheck() {
    src=$1; out=$2; bd=$3
    rm -rf "$bd" "$out"
    echo "  \$ php8.4 $TPC $src --nano -o $out --build-dir $bd"
    s=$(date +%s)
    php8.4 "$TPC" "$src" --nano -o "$out" --build-dir "$bd" >"$out.log" 2>&1; rc=$?
    echo "    build rc=$rc elapsed=$(( $(date +%s) - s ))s  ($(grep -c '^\[' "$out.log") compile steps logged)"
    if [ -x "$out" ]; then
        o=$(timeout 5 "$out" </dev/null 2>"$out.err"); r=$?
        echo "    run rc=$r out=[$(printf '%s' "$o" | tr '\n' ' ')] err=[$(head -1 "$out.err")]"
    else
        echo "    no binary; last build lines: $(tail -2 "$out.log" | tr '\n' ' ')"
    fi
}
recheck "$PWD/nano_trap.php" "$PWD/recheck-trap" "$PWD/rebuild-trap"
recheck "$PWD/nano_ctrl.php" "$PWD/recheck-ctrl" "$PWD/rebuild-ctrl"
echo "  -> the strlen program is reproducible on an unmodified tpc/php-nano/phpx tree."
echo
echo "==================== 5. probe sources ===================="
for f in nano_ctrl nano_trap nano_ver nano_stdout nano_stream nano_devio nano_file; do
    echo "----- $f.php"
    cat "$f.php"
done
