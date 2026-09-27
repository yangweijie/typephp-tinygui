# Nano programs that call a Zend builtin (`strlen`, `strcmp`, …) build fine and then die at startup: `ZEND_MOD_REQUIRED("Core")` can never be satisfied

Filed against: `tpc` (dependency emission) and/or `swoole/php-nano` (dependency resolution) —
the two halves disagree about what a module name means.

**Versions measured:** tpc v0.9.3 · swoole/php-nano v1.0.1 · swoole/phpx ~2.9.2 · host PHP 8.4.25 ·
g++ (Debian 12.2.0-14+deb12u1) 12.2.0 · GNU ld 2.40 · Debian bookworm aarch64 (Apple Container).

## Summary

`tpc --nano` writes `ZEND_MOD_REQUIRED("Core")` into the generated module entry whenever the
program calls a function that the compiling reflection attributes to the Zend core
(`strlen`, `strcmp`, `count`, …). php-nano resolves required deps **only** against the closed list
of modules it composes, and the module named `"Core"` is a `static` entry inside a Zend
translation unit that no generated composer array can reference. Result: the build reports
`Build successful`, the binary starts, prints

```
Unable to start PHP Nano extensions
```

and exits 1 — with **no PHP-level error and no output at all**. Anything that touches a string or
array function hits this, so `--nano` is effectively limited to programs that call nothing
built-in.

## Minimum reproduction

```php
<?php
declare(strict_types=1);

function main(): void
{
    echo strlen("nano-trap-probe"), "\n";
}
```

```
$ php8.4 /work/tpc/bin/tpc.php nano_trap.php --nano -o app-trap --build-dir rebuild-trap
Build successful: app-trap                     (rc=0, 6 s)
$ ./app-trap </dev/null ; echo $?
Unable to start PHP Nano extensions
1
```

Negative control, same tree and same command shape, one file that calls no built-in function
(`nano_ctrl.php` uses `usort()` with a closure and array destructuring, and *does* link fine):

```
$ php8.4 /work/tpc/bin/tpc.php nano_ctrl.php --nano -o app-ctrl --build-dir rebuild-ctrl
$ ./app-ctrl </dev/null ; echo $?
nano-ctrl-ok a
0
```

Both were re-run from scratch on an **unmodified** tpc/php-nano/phpx tree; the transcript is
`evidence/linux/25-deps-vs-modules.txt` §4.

## What the generated entry asks for vs what gets composed

```
--- trapbuild   requires : Core
                composed : typephp_project_app_trap::typephp_app_trap_module_entry
--- ctrlbuild   requires : standard
                composed : basic_functions_module random_module_entry typephp_project_app_ctrl::…
--- nanobuild   requires : standard date hash json pcre Core SPL
                composed : basic_functions_module date_module_entry filter_module_entry
                           hash_module_entry json_module_entry pcre_module_entry
                           reflection_module_entry random_module_entry spl_module_entry typephp_…
```

`standard`, `date`, `hash`, `json`, `pcre`, `SPL` are all present and do resolve
(`ctrlbuild` requires `standard` and runs). `Core` is the one that cannot.

## Root cause, both halves

**(1) tpc emits the name verbatim.** `Translator::resolveExtensionDependencies()`
(`src/Translator.php:2052-2060` for functions, `:2070-2078` for classes) takes

```php
$extension = $reflection !== null && $reflection->isInternal()
    ? $reflection->getExtensionName()          // "Core" for Zend builtins
    : $sourceIndex?->functionExtension($function);
```

and `appendExtensionDependency()` (`src/Translator.php:2088-2101`) only drops TypePHP's own
extension names (`Reflection::isTypePhpExtension`) before pushing the string. The list is then
written as `ZEND_MOD_REQUIRED(<name>)` at `src/Translator.php:1960`. This resolution path is
shared with the SAPI build backends, where `"Core"` *is* a real registered module — so the name is
harmless there and wrong here.

**(2) php-nano resolves against the composed array only.**
`dependency_state()` (`src/extension.cpp:44-70`) looks each dependency up with `find_available()`,
which compares `->name` over exactly the array handed to `php_nano_startup_extensions()`:

```cpp
// src/extension.cpp:29-35
if (extensions[index] != nullptr && extensions[index]->name != nullptr
    && std::strcmp(extensions[index]->name, name) == 0) {
    return extensions[index];
}
...
// src/extension.cpp:65-69
if (available == nullptr) {
    if (dependency->type == MODULE_DEP_REQUIRED) {
        return DependencyState::Invalid;
    }
```

**(3) `"Core"` is unreachable by construction.** The only module with that name in the whole tree:

```c
// php-nano/Zend/zend_builtin_functions.c:52-54
static zend_module_entry zend_builtin_module = { /* {{{ */
	STANDARD_MODULE_HEADER,
	"Core",
```

registered by `zend_startup_builtin_functions()` (`zend_builtin_functions.c:66-69`), which php-nano
calls unconditionally from `src/core.cpp:272` *before* the composer extensions start. Because the
entry is `static` in that TU, **no generated `composer_extensions.cpp` can put it in the array** —
we measured 0 references to `zend_builtin_module` across all 14 composer arrays our builds produced.

So the builtin functions *are* live in the process; the dependency that names them can still never
be satisfied.

## Verified fix (tpc side, 4 lines)

```php
// src/Translator.php, in appendExtensionDependency(), right after
// `$key = strtolower($extension);`  (:2088-2101)
// php-nano registers no module named "Core": the Zend builtins come from
// zend_startup_builtin_functions(), outside the composed extension array.
if ($key === 'core' && $this->isNanoMode()) {
    return;
}
```

Measured with that patch and **no other change**:

| program | before | after |
|---|---|---|
| `nano_trap.php` (`strlen`) | `Unable to start PHP Nano extensions`, rc=1 | prints `15`, rc=0 |
| `nano_ver.php` (`phpversion()`) | same death | prints `8.6.0beta3`, rc=0 |
| our 1,223-line aggregated backend | `Unable to start PHP Nano extensions`, rc=1 | gets past extension startup (then dies on a separate gap — see `php-nano-missing-stdio-handles.md`) |

The patch was reverted; the diff is in `evidence/linux/25-upstream-probe.txt`.

## Suggested fixes

1. **tpc:** don't emit Zend-internal module names into nano deps (the 4-liner above, or a small
   blacklist of names that php-nano starts implicitly: `Core`, and worth confirming `zend.*`).
2. **php-nano:** treat `"Core"` as always satisfied — `dependency_state()` knows
   `zend_startup_builtin_functions()` already ran, so a pseudo-entry or a name special case would
   make every existing tpc output work unchanged.
3. Either way, a clearer failure would help a lot: today the process prints one line to stderr and
   exits 1, and it is not obvious that a *dependency string* is what killed it. Naming the
   unsatisfied dependency in that message would have saved us a full build-to-build bisection.

## Evidence in our repo

- `evidence/linux/25-deps-vs-modules.txt` — requires vs composed arrays, the `"Core"` citation set,
  the empirical startup table, and the stock-tree recheck
- `evidence/linux/25-upstream-probe.txt` — the reverted `Translator.php` patch and the before/after
- `evidence/linux/24-tier6-driver.log` — the original "links fine, never runs" observation
