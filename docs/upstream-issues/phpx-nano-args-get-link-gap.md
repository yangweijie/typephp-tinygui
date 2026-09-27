# Nano `--nano` builds that use closures fail to link: `undefined reference to php::Args::get(unsigned long) const`

Filed against: `swoole/phpx` (nano source manifest) — the missing definition is in phpx, the
consumer is `tpc`'s nano composition.

**Versions measured:** tpc v0.9.3 · swoole/php-nano v1.0.1 · swoole/phpx ~2.9.2 · host PHP 8.4.25 ·
g++ (Debian 12.2.0-14+deb12u1) 12.2.0 · GNU ld 2.40 · Debian bookworm aarch64 (Apple Container).

## Summary

A program compiled with `tpc --nano` that goes through `php::makeScopedCallableImpl()`
(closures invoked from compiled code) links against `php::Args::get(size_t) const`. That symbol
is declared in `phpx/include/phpx.h` but its **only definition lives in
`phpx/src/core/extension.cc`, which is not part of the nano source manifest**, so no nano build
can resolve it. The failure is at link time, on a program that compiles cleanly.

## Where the symbol lives

```
phpx/include/phpx.h:2525           Variant get(size_t i) const;      // declaration (class Args @2436)
phpx/src/core/extension.cc:278     Variant Args::get(size_t i) const {   // the only definition
```

`phpx/composer.json` → `extra.typephp-native.sources` lists **30** sources, of which 15 are
`src/core/*.cc`:

```
src/core/array.cc            src/core/big_int_nano.cc   src/core/foreach_iterator.cc
src/core/base.cc             src/core/class.cc          src/core/native_gc.cc
src/core/big_float_nano.cc   src/core/closure.cc        src/core/object.cc
                                                    src/core/scope.cc
src/core/string.cc           src/core/type_check.cc     src/core/variant.cc
src/core/decimal_nano.cc
```

`src/core/extension.cc` is **not** in that list (`extension.cc present? NO`), while
`src/core/closure.cc` **is** — and `closure.cc`'s `makeScopedCallableImpl()` lambda takes an
`Args&` parameter, which is what pulls `Args::get` into the link.

## Reproduction

The closure shape that ends up referencing `Args` is a plain `usort()` with a lambda
(`test/posix/upstream-nano-probes/nano_ctrl.php`):

```php
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
```

**This single file links and runs fine** (`nano-ctrl-ok a`, rc=0) — we have not managed to shrink
the failing case below a multi-module entry point, so please read the rest as "here is what we
actually hit", and tell us what extra ingredient to add.

What does fail is our shipping backend entry flattened into one file (16 modules, 41,995 B —
the aggregate is 1,223 lines and is reproducible from this repo with
`php8.4 tools/aggregate-backend.php src/backend.php -o build/backend_aggregated.php --root .`):

```
php8.4 /work/tpc/bin/tpc.php build/backend_aggregated.php --nano -o /tmp/tpgui-tier6/app-nano
```

**Actual** (`ld` output, from `evidence/linux/24-nano-aggregate-build.log`):

```
closure.cc:(.text._ZZN3phpL22makeScopedCallableImplERKNS_7VariantERKNS_13CallableScopeEbENKUlP18_zend_execute_dataP12_zval_structRNS_6ObjectERNS_4ArgsEE_clES7_S9_SB_SD_+0xec):
  undefined reference to `php::Args::get(unsigned long) const'
```

**Expected:** the closure machinery that php-nano composes should have every symbol it references
available among the composed sources.

## Attribution (measured, not assumed)

We diffed the two nano object sets that a `--dry` compile produces
(`evidence/linux/24-closure-nm.txt`):

| build | objects | `Args::get` define | `Args::get` reference |
|---|---|---|---|
| 240-object aggregate build | 240 | — (none) | `closure-f8759031b18c.o` |
| 138-object control build | 138 | — (none) | `closure-f8759031b18c.o` |

The Closure translation unit is **byte-identical** between the two runs (sha prefix `55c5e4bad9996223`),
and the 138-object control **does** link and run. So the size of the object set is not the cause:
the difference is only whether the final link reaches a TU that needs `Args::get`. That rules out
"our aggregation shape" and points at the manifest.

## Why the obvious fix is not enough

Adding `src/core/extension.cc` to `extra.typephp-native.sources` compiles nothing:

```
extension.cc:162:6: error: no declaration matches 'void php::Extension::addIniEntry(const char*, const char*, int)'
extension.cc:296:8: error: 'ZEND_RESULT_CODE' does not name a type; did you mean 'ZEND_CALL_CODE'?
extension.cc:348:9: error: '_check_args_num' was not declared in this scope
extension.cc:393:9: error: '_check_args_num' was not declared in this scope
```

(full log: `evidence/linux/25-naive-fix-fails.log`, build rc=255) — i.e. `extension.cc` is written
against the full PHP/PHPX headers and does not build under `-DPHP_NANO_SELECTIVE=1`.

## Verified workaround (proof that the symbol is the whole blocker)

We compiled the two `Args` accessors into a TU that **is** already in the manifest
(`src/core/variant.cc`, appended at namespace scope):

```cpp
namespace php {
Variant Args::get(size_t i) const {
    if (i >= count()) {
        return null;
    }
    return {&params.at(i), Ctor::CopyRef};
}

Array Args::toArray() const {
    Array array(params.size());
    for (const auto &param : params) {
        array.append(Variant(&param, Ctor::Indirect));
    }
    return array;
}
}  // namespace php
```

Result on the shipping 1,223-line backend entry:

```
Build successful: /tmp/tpgui-tier6/app-nano-fixed
binary = 6,933,344 B   stripped = 6,169,176 B
ldd: libstdc++ / libm / libgcc_s / libc / ld-linux — no libphp
```

So the nano route's *link* layer is otherwise sound; this one symbol is the wall.

## Suggested fix (any one of these unblocks us)

1. Split the `Args` (and any other helper that a composed TU references) definitions out of
   `src/core/extension.cc` into a file that is in `extra.typephp-native.sources`
   (e.g. `src/core/args.cc`), and add it to the manifest.
2. Or make `Args::get` / `Args::toArray` header-inline (`include/phpx.h`), so no out-of-line
   definition is required.
3. Or make `extension.cc` build under the nano header set and add it to the manifest — most
   complete, and the four errors above show it needs work.

## Evidence in our repo

- `evidence/linux/24-nano-aggregate-build.log` — the failing link line
- `evidence/linux/24-closure-nm.txt` — 240 vs 138 object sets, identical Closure TU
- `evidence/linux/25-upstream-probe.txt` — manifest dump, symbol locations, the variant.cc patch,
  and the successful 6.9 MB libphp-free link
- `evidence/linux/25-naive-fix-fails.log` — the four compile errors from the naive fix
