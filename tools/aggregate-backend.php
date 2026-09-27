<?php
/**
 * tools/aggregate-backend.php — turn a require-chained PHP entry into ONE file.
 *
 * Why this exists: real `tpc --nano` refuses `require`/`include` at compile time,
 * so a framework loaded through bootstrap.php can never be compiled for the
 * freestanding nano target as-is. Windows' `--nano` is only a policy wrapper and
 * never reported this — exactly the "Windows passes != real nano passes" trap in
 * the plan file. Aggregation fixes it without touching the source layout: the
 * multi-file tree stays the single source of truth, the shipping nano artifact is
 * generated from it.
 *
 * What it does, at TOKEN level (never regex over source — a comment that merely
 * mentions `require` must survive untouched):
 *   1. walks `require`/`require_once <expr>` statements whose expression is a
 *      constant composition of `__DIR__` and quoted strings, resolves each target
 *      against the *including* file and recurses post-order, so a module is
 *      emitted before its requirer (the order PHP would run them in);
 *   2. cuts from each emitted body: the leading `<?php`, top-level `declare(...)`,
 *      and every require statement it resolved;
 *   3. hoists the entry's trailing top-level executable statements into
 *      `function main(): void` — nano has a second, harsher rule beyond
 *      `require`: `CompilerBase::ENTRY_FUNCTION` means a namespace body may only
 *      contain declarations, so `Gui::serveDemo();` at the bottom of the entry is
 *      "stray code" and aborts the compile (see Preprocessor::prepareNamespace);
 *   4. refuses anything it cannot prove safe — a dynamic or nested require, a
 *      missing target, a target outside --root, a `declare` that is not
 *      strict_types=1, a surviving `__DIR__`/`__FILE__`, or executable code that
 *      is not a clean tail of the entry file.
 *
 * Because of step 3 the aggregated file no longer self-runs under stock PHP:
 * invoke it as `php -r 'require $argv[1]; main();' build/backend_aggregated.php`.
 *
 * Emitting one `declare(strict_types=1);` at the top is only behaviour-preserving
 * because every input file already declares it; that is asserted, not assumed.
 *
 * Usage:
 *   php tools/aggregate-backend.php src/backend.php -o build/backend_aggregated.php
 *   php tools/aggregate-backend.php --check src/backend.php -o build/backend_aggregated.php
 *
 * Exit: 0 ok, 1 refusal/error, 2 --check found the output missing or stale.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "aggregate-backend.php is a CLI tool\n");
    exit(1);
}

$argvv = array_slice($_SERVER['argv'], 1);
$entry = null;
$out = null;
$root = (string)getcwd();
$check = false;
$quiet = false;
for ($i = 0, $an = count($argvv); $i < $an; $i++) {
    $a = $argvv[$i];
    if ($a === '-o' || $a === '--out') {
        $out = $argvv[++$i] ?? null;
    } elseif ($a === '--root') {
        $root = (string)($argvv[++$i] ?? '');
    } elseif ($a === '--check') {
        $check = true;
    } elseif ($a === '--quiet') {
        $quiet = true;
    } elseif ($a === '-h' || $a === '--help') {
        echo "Usage: php tools/aggregate-backend.php <entry.php> -o <out.php> [--root <dir>] [--check] [--quiet]\n",
             "  entry   PHP file whose only runtime deps are `require(_once) __DIR__ . '/x.php'` chains\n",
             "  -o      aggregated output file\n",
             "  --root  refuse to pull in anything outside this directory (default: cwd)\n",
             "  --check write nothing; exit 2 when <out> is missing or not byte-identical\n";
        exit(0);
    } elseif ($entry === null) {
        $entry = $a;
    } else {
        fwrite(STDERR, "unexpected argument: {$a}\n");
        exit(1);
    }
}
if ($entry === null || $out === null) {
    fwrite(STDERR, "need <entry.php> and -o <out.php> (try --help)\n");
    exit(1);
}

$rootR = realpath($root);
$entryR = realpath($entry);
if ($rootR === false) {
    fwrite(STDERR, "cannot resolve --root: {$root}\n");
    exit(1);
}
if ($entryR === false) {
    fwrite(STDERR, "cannot resolve entry: {$entry}\n");
    exit(1);
}

$fail = static function (string $msg): never {
    fwrite(STDERR, "aggregate: {$msg}\n");
    exit(1);
};

$relOf = static function (string $p) use ($rootR): string {
    $pre = $rootR . DIRECTORY_SEPARATOR;
    if (str_starts_with($p, $pre)) {
        $p = substr($p, strlen($pre));
    }
    return str_replace('\\', '/', $p);
};

/**
 * Evaluate a require argument. Accepted grammar, and only this: quoted strings
 * and `__DIR__`, joined with `.`. A variable, a call, or interpolation returns
 * null so the caller refuses instead of guessing at a path.
 */
$evalRequire = static function (array $toks, string $fileDir) use ($relOf): ?string {
    $path = '';
    $want = 'part';
    foreach ($toks as $t) {
        if (is_array($t) && $t[0] === T_WHITESPACE) {
            continue;
        }
        if ($want === 'part') {
            if (is_array($t) && $t[0] === T_DIR) {
                $path .= $fileDir;
            } elseif (is_array($t) && $t[0] === T_CONSTANT_ENCAPSED_STRING) {
                $q = $t[1][0];
                $inner = substr($t[1], 1, -1);
                $path .= $q === "'"
                    ? str_replace(["\\'", '\\\\'], ["'", '\\'], $inner)
                    : stripcslashes($inner);
            } else {
                return null;
            }
            $want = 'glue';
        } else {
            if ($t !== '.') {
                return null;
            }
            $want = 'part';
        }
    }
    return $want === 'glue' ? $path : null;
};

// Token classification, statement by statement, at brace/paren depth 0.
$DECL_FIRST = [T_NAMESPACE, T_USE, T_CLASS, T_INTERFACE, T_TRAIT, T_ENUM,
               T_FUNCTION, T_CONST, T_ATTRIBUTE, T_DECLARE, T_ABSTRACT, T_FINAL];
if (defined('T_READONLY')) {
    $DECL_FIRST[] = T_READONLY;
}

// `"{$x}"` and `"${x}"` emit T_CURLY_OPEN / T_DOLLAR_OPEN_CURLY_BRACES for the
// opening brace but a *plain* '}' as the closer. Counting only the plain '{'
// would drive the depth negative on the first interpolated string and then every
// top-level check downstream silently stops firing.
$INTERP_OPEN = [T_CURLY_OPEN];
if (defined('T_DOLLAR_OPEN_CURLY_BRACES')) {
    $INTERP_OPEN[] = T_DOLLAR_OPEN_CURLY_BRACES;
}
$isInterpOpen = static fn (array $t): bool => in_array($t[0], $INTERP_OPEN, true);

$sources = [];   // realpath => ['rel' => string, 'body' => string]
$order = [];     // realpaths in emit order

$scan = static function (string $fileR) use (
    &$scan, &$sources, &$order, $rootR, $relOf, $evalRequire, $fail, $isInterpOpen
): void {
    if (isset($sources[$fileR])) {
        return;                              // require_once semantics: emit once
    }
    $rel = $relOf($fileR);
    $src = file_get_contents($fileR);
    if ($src === false) {
        $fail("{$rel}: cannot read");
    }
    $dirR = dirname($fileR);
    $len = strlen($src);
    $tokens = token_get_all($src);
    $nt = count($tokens);

    $start = [];                              // token index => byte offset
    $off = 0;
    for ($i = 0; $i < $nt; $i++) {
        $start[$i] = $off;
        $off += strlen(is_array($tokens[$i]) ? $tokens[$i][1] : $tokens[$i]);
    }

    $cuts = [];
    $depth = 0;
    $openTagCut = false;
    for ($i = 0; $i < $nt; $i++) {
        $t = $tokens[$i];
        $text = is_array($t) ? $t[1] : $t;

        if (is_array($t)) {
            if ($t[0] === T_OPEN_TAG && !$openTagCut) {
                // Only the file's own opening tag; a later one would mean the
                // source escaped PHP mode, which aggregation must not paper over.
                $openTagCut = true;
                $cuts[] = [$start[$i], $start[$i] + strlen($text)];
                continue;
            }
            if ($isInterpOpen($t)) {
                $depth++;                      // closed by a plain '}' below
                continue;
            }
            if ($depth !== 0) {
                continue;
            }
            if ($t[0] === T_REQUIRE || $t[0] === T_REQUIRE_ONCE
                || $t[0] === T_INCLUDE || $t[0] === T_INCLUDE_ONCE) {
                $kw = $text;
                $args = [];
                $d2 = 0;
                $j = $i + 1;
                for (; $j < $nt; $j++) {
                    $tx = is_array($tokens[$j]) ? $tokens[$j][1] : $tokens[$j];
                    if ($tx === '(' || $tx === '[') {
                        $d2++;
                    } elseif ($tx === ')' || $tx === ']') {
                        $d2--;
                    } elseif ($tx === ';' && $d2 === 0) {
                        break;
                    }
                    $args[] = $tokens[$j];
                }
                if ($j >= $nt) {
                    $fail("{$rel}: unterminated `{$kw}`");
                }
                $end = $start[$j] + 1;
                while ($end < $len && ($src[$end] === "\n" || $src[$end] === "\r")) {
                    $end++;
                }
                $target = $evalRequire($args, $dirR);
                if ($target === null) {
                    $fail("{$rel}: `{$kw}` at byte {$start[$i]} is not a constant `__DIR__ . '/x.php'` chain — refusing to guess");
                }
                $abs = realpath($target);
                if ($abs === false) {
                    $fail("{$rel}: required file does not exist: {$target}");
                }
                if ($abs !== $rootR && !str_starts_with($abs, $rootR . DIRECTORY_SEPARATOR)) {
                    $fail("{$rel}: required file {$abs} is outside --root {$rootR}");
                }
                $cuts[] = [$start[$i], $end];
                $scan($abs);                  // dependency before dependent
                $i = $j;
                continue;
            }
            if ($t[0] === T_DECLARE) {
                $body = '';
                $d2 = 0;
                $j = $i + 1;
                for (; $j < $nt; $j++) {
                    $tx = is_array($tokens[$j]) ? $tokens[$j][1] : $tokens[$j];
                    if ($tx === '(') {
                        $d2++;
                    } elseif ($tx === ')') {
                        $d2--;
                    } elseif ($tx === ';' && $d2 === 0) {
                        break;
                    }
                    $body .= $tx;
                }
                if ($j >= $nt) {
                    $fail("{$rel}: unterminated declare");
                }
                if (preg_match('/\(\s*strict_types\s*=\s*1\s*\)/i', '(' . $body) !== 1) {
                    $fail("{$rel}: declare({$body}) is not `strict_types=1` — merging modules that disagree would silently change typing semantics");
                }
                $end = $start[$j] + 1;
                while ($end < $len && ($src[$end] === "\n" || $src[$end] === "\r")) {
                    $end++;
                }
                $cuts[] = [$start[$i], $end];
                $i = $j;
                continue;
            }
            continue;
        }

        if ($text === '{' || $text === '(' || $text === '[') {
            $depth++;
        } elseif ($text === '}' || $text === ')' || $text === ']') {
            $depth--;
        }
    }

    usort($cuts, static fn (array $a, array $b): int => $b[0] <=> $a[0]);
    $body = $src;
    foreach ($cuts as $c) {
        $body = substr($body, 0, $c[0]) . substr($body, $c[1]);
    }
    $body = rtrim(ltrim($body, "\r\n")) . "\n";

    $sources[$fileR] = ['rel' => $rel, 'body' => $body, 'ns' => null];
    $order[] = $fileR;
};

$scan($entryR);

// Nothing may still depend on where a module physically lives: __DIR__/__FILE__
// would silently mean the aggregated file's location instead.
// The synthetic open tag is not cosmetic: token_get_all() on a body whose `<?php`
// was cut reads it as T_INLINE_HTML, so without it this check would pass on
// nothing and the guard would be vacuous.
foreach ($order as $fr) {
    foreach (token_get_all("<?php\n" . $sources[$fr]['body']) as $t) {
        if (is_array($t) && ($t[0] === T_DIR || $t[0] === T_FILE)) {
            $fail("{$sources[$fr]['rel']}: still uses " . ($t[0] === T_DIR ? '__DIR__' : '__FILE__')
                  . ' — its meaning changes once aggregated; read $_SERVER (see AppRoot::fromEnv) instead');
        }
    }
}

// ---- step 3: hoist the entry's executable tail into function main() ---------
//
// nano's other hard rule: a namespace body may contain declarations only
// (Preprocessor::prepareNamespace -> foundStrayCode), and the program entry is
// the global function `main` (CompilerBase::ENTRY_FUNCTION). So the aggregated
// file has to end in `function main(): void { <entry tail> }`.

/**
 * Read (and remove) the module's single top-level `namespace X;` declaration.
 * Returns [qualifiedName, bodyWithoutThatStatement].
 *
 * This matters beyond tidiness: after concatenation the LAST `namespace`
 * declaration governs everything to EOF, so a global-namespace entry appended
 * after `namespace Tiny\Gui;` would silently inherit that namespace — its
 * `use Tiny\Gui\Gui;` would alias a non-existent Tiny\Gui\Gui\Gui and its
 * hoisted `main()` would not be the global entry tpc looks for. Each module is
 * therefore re-emitted as its own braced block, which is the only form PHP (and
 * tpc's prepareNamespace) allows for several namespaces in one file.
 */
$takeNamespace = static function (string $rel, string $body) use ($fail, $isInterpOpen): array {
    $synthetic = "<?php\n";
    $tokens = token_get_all($synthetic . $body);
    $ns = '';
    $cutFrom = null;
    $cutTo = null;
    $depth = 0;
    $n = count($tokens);
    for ($i = 0; $i < $n; $i++) {
        $t = $tokens[$i];
        $text = is_array($t) ? $t[1] : $t;
        if (is_array($t)) {
            if ($t[0] === T_WHITESPACE || $t[0] === T_COMMENT || $t[0] === T_DOC_COMMENT
                || $t[0] === T_OPEN_TAG) {
                continue;
            }
            if ($isInterpOpen($t)) {
                $depth++;
                continue;
            }
            if ($t[0] === T_NAMESPACE && $depth === 0) {
                if ($cutFrom !== null) {
                    $fail("{$rel}: a second top-level namespace declaration — one file may only belong to one");
                }
                $cutFrom = $i;
                $j = $i + 1;
                for (; $j < $n; $j++) {
                    $tj = $tokens[$j];
                    $xj = is_array($tj) ? $tj[1] : $tj;
                    if ($xj === ';') {
                        break;
                    }
                    if ($xj === '{') {
                        $fail("{$rel}: braced `namespace X {{` form — the aggregator only understands the semicolon form");
                    }
                    if (is_array($tj) && $tj[0] === T_WHITESPACE) {
                        continue;
                    }
                    if (is_array($tj) && !in_array($tj[0], [T_STRING, T_NAME_QUALIFIED, T_NAME_FULLY_QUALIFIED,
                                                            T_NAME_RELATIVE], true)) {
                        $fail("{$rel}: unexpected token in namespace declaration");
                    }
                    $ns .= $xj;
                }
                if ($j >= $n) {
                    $fail("{$rel}: unterminated namespace declaration");
                }
                $cutTo = $j;
                $i = $j;
                continue;
            }
            continue;
        }
        if ($text === '{' || $text === '(' || $text === '[') {
            $depth++;
        } elseif ($text === '}' || $text === ')' || $text === ']') {
            $depth--;
        }
    }
    if ($cutFrom === null) {
        return ['', $body];                    // global namespace
    }
    // Byte offsets: rebuild from the token stream (the synthetic prefix shifts them).
    $off = 0;
    $start = [];
    foreach ($tokens as $k => $tk) {
        $start[$k] = $off - strlen($synthetic);
        $off += strlen(is_array($tk) ? $tk[1] : $tk);
    }
    $from = $start[$cutFrom];
    $to = $start[$cutTo] + 1;                   // past the ';'
    while ($to < strlen($body) && ($body[$to] === "\n" || $body[$to] === "\r")) {
        $to++;
    }
    $kept = substr($body, 0, $from) . substr($body, $to);
    return [$ns, ltrim($kept, "\r\n") . "\n"];
};

/**
 * Split one module body into [prelude, execTail]. execTail is '' when the module
 * has no top-level executable code. Refuses rather than guesses: declarations
 * interleaved with executable code, or executable code inside a namespace
 * (there `main` would not be the global entry function tpc looks for).
 */
$splitEntryTail = static function (string $rel, string $body) use ($fail, $DECL_FIRST, $isInterpOpen): array {
    // The emitted bodies have their `<?php` cut, so tokenizing one directly
    // would read the whole file as T_INLINE_HTML. Re-open PHP mode with a
    // synthetic tag and shift the offsets back.
    $synthetic = "<?php\n";
    $base = -strlen($synthetic);
    $tokens = token_get_all($synthetic . $body);
    $start = [];
    $off = 0;
    foreach ($tokens as $i => $t) {
        $start[$i] = $off + $base;
        $off += strlen(is_array($t) ? $t[1] : $t);
    }
    $depth = 0;
    $atStmtStart = true;
    $hasNamespace = false;
    $stmts = [];                 // [offset, kind]
    foreach ($tokens as $i => $t) {
        $text = is_array($t) ? $t[1] : $t;
        if (is_array($t)) {
            if (in_array($t[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT, T_OPEN_TAG], true)) {
                continue;
            }
            if ($t[0] === T_NAMESPACE) {
                $hasNamespace = true;
            }
            if ($isInterpOpen($t)) {
                $depth++;                       // closed by a plain '}' below
                continue;
            }
            if ($depth === 0 && $atStmtStart) {
                $stmts[] = [$start[$i], in_array($t[0], $DECL_FIRST, true) ? 'decl' : 'exec'];
                $atStmtStart = false;
            }
            continue;
        }
        if ($text === '{' || $text === '(' || $text === '[') {
            $depth++;
            continue;
        }
        if ($text === '}' || $text === ')' || $text === ']') {
            $depth--;
            if ($depth === 0) {
                $atStmtStart = true;           // a brace-bodied declaration just ended
            }
            continue;
        }
        if ($depth === 0 && $text === ';') {
            $atStmtStart = true;
        }
    }
    $firstExec = null;
    foreach ($stmts as $k => [$o, $kind]) {
        if ($kind === 'exec' && $firstExec === null) {
            $firstExec = $k;
        } elseif ($firstExec !== null && $kind === 'decl') {
            $fail("{$rel}: declaration at byte {$o} follows executable code — hoisting it into main() would make the declaration conditional, refusing");
        }
    }
    if ($firstExec === null) {
        return [$body, ''];
    }
    if ($hasNamespace) {
        $fail("{$rel}: executable code at byte {$stmts[$firstExec][0]} inside a namespace — only the global-namespace entry may be hoisted to main()");
    }
    $tailStart = $stmts[$firstExec][0];
    $prelude = rtrim(substr($body, 0, $tailStart));
    $tail = rtrim(substr($body, $tailStart));
    if ($tail === '') {
        return [$body, ''];
    }
    return [$prelude . "\n", $tail . "\n"];
};

$entryTail = '';
foreach ($order as $fr) {
    [$kept, $tail] = $splitEntryTail($sources[$fr]['rel'], $sources[$fr]['body']);
    if ($tail !== '') {
        if ($fr !== $entryR) {
            $fail("{$sources[$fr]['rel']}: has top-level executable code but is not the entry — only the entry's tail can become main()");
        }
        $entryTail = $tail;
        $sources[$fr]['body'] = $kept;
    }
}

foreach ($order as $fr) {
    [$ns, $kept] = $takeNamespace($sources[$fr]['rel'], $sources[$fr]['body']);
    $sources[$fr]['ns'] = $ns;
    $sources[$fr]['body'] = $kept;
}

// Deliberately NOT the real -o path: embedding it would make two runs that
// produce identical content differ byte-for-byte, and "the aggregator is
// deterministic" is a claim test/posix/tier6-nano-aggregate.sh has to check.
$regenerate = 'php tools/aggregate-backend.php ' . $relOf($entryR) . ' -o <this file>';
$header = "<?php\n/**\n"
    . " * GENERATED by tools/aggregate-backend.php — DO NOT EDIT.\n"
    . " *\n"
    . " * Single-file form of " . $relOf($entryR) . " for targets that cannot resolve\n"
    . " * `require` at all (tpc --nano rejects it at compile time). The multi-file tree\n"
    . " * stays the source of truth; rebuild this with:\n"
    . " *   {$regenerate}\n"
    . " *\n"
    . " * The entry's top-level code was hoisted into function main(): nano only runs a\n"
    . " * global main(), so under stock PHP run it as\n"
    . " *   php -r 'require \$argv[1]; main();' <this file>\n"
    . " *\n"
    . " * Modules, in emit order (post-order of the require graph):\n";
foreach ($order as $fr) {
    $header .= ' *   - ' . $sources[$fr]['rel'] . "\n";
}
$header .= " */\n\ndeclare(strict_types=1);\n";

$parts = [$header];
foreach ($order as $fr) {
    $ns = $sources[$fr]['ns'];
    $block = "\n// ==== from " . $sources[$fr]['rel'] . " ====\n"
          . 'namespace' . ($ns !== '' ? ' ' . $ns : '') . " {" . "\n"
          . $sources[$fr]['body'];
    if ($fr === $entryR && $entryTail !== '') {
        $block .= "\n// ==== hoisted: nano takes its program entry from the global function main() ====\n"
               . "function main(): void\n{\n" . $entryTail . "}\n";
    }
    $parts[] = $block . "}\n";
}
$text = implode('', $parts);

if ($check) {
    $cur = is_file($out) ? (string)file_get_contents($out) : '';
    if ($cur !== $text) {
        fwrite(STDERR, "aggregate: --check — {$out} is missing or stale (run: {$regenerate})\n");
        exit(2);
    }
    exit(0);
}

$dir = dirname($out);
if (!is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
    $fail("cannot create output directory {$dir}");
}
if (file_put_contents($out, $text) === false) {
    $fail("cannot write {$out}");
}
if (!$quiet) {
    printf("aggregated %d module(s) -> %s (%d B, %d lines)\n",
           count($order), $out, strlen($text), substr_count($text, "\n"));
    foreach ($order as $fr) {
        echo '  - ' . $sources[$fr]['rel'] . "\n";
    }
}
exit(0);
