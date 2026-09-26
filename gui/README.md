# `gui/` — the TypePHP GUI module

This module is the fused-in GUI implementation. It **replaces** the old setup where
`typephp-gui` depended on a separate `tinyjsapp` checkout and integrated via
out-of-tree patches (`patches/cli-typephp.patch`, `patches/launcher-win-typephp.patch`,
`tools/bootstrap-tinyjsapp.sh`). Now the host, the client, the protocol framework,
and the CLI are all **first-class parts of this repository**.

See [`docs/GUI_FUSION_DESIGN.md`](../docs/GUI_FUSION_DESIGN.md) for the full
migration rationale (scope, module division, integration approach, compatibility
strategy, and the developer-facing design).

## What lives here

```
gui/
  LICENSE.NOTICE        MIT attribution (tinyjsapp + this project)
  host/                 the native GUI host (vendored + OWNED)
    src/launcher-win.cc     WebView2 host, --typephp merged in-tree
    src/launcher-linux.cc   WebKitGTK host (pristine vendored)
    src/launcher-macos.cc    WKWebView host (pristine vendored)
    src/tiny_client.h        GENERATED from runtime/tiny.js (build only)
    include/                 webview.h, WebView2.h, miniaudio.h
    script/gen-client.sh     embeds runtime/tiny.js -> tiny_client.h
  runtime/
    tiny.js              the window.tiny client shim (vendored; our copy)
  php/                  the PHP-native protocol framework (OURS — the fusion)
    src/Tiny/Gui/           Request, Response, Protocol, Dispatcher, Backend,
                           State, Gui (facade), Handlers/*
    backend.php             canonical entrypoint (tpc gui/php/backend.php -o app.exe)
    test/smoke.php          headless protocol test (php gui/php/test/smoke.php)
  bin/
    tgui                 dev / build / publish / init / status CLI
```

## How it differs from upstream (the re-architecture)

Tinyjsapp is a **JS-backend** toolkit: a txiki.js module graph spawns the native
host and answers `CALL` frames over a pipe. We keep the *host* (it is excellent
and MIT-licensed) but replace the **entire backend half** with a PHP-native stack:

| Upstream | Here |
|---|---|
| `cli.js` (JS CLI, patched for `--typephp`) | `gui/bin/tgui` (bash — owns dev/build/publish) |
| `runtime/bridge.js` (JS backend bridge) | `gui/php/src/Tiny/Gui/*` (typed, extensible PHP framework) |
| JS backend module graph | compiled PHP (`tpc … -o app.exe`) driven by `shim/backend_shell.cpp` |
| flat `backend.php` dispatch | `Dispatcher` + `HandlerInterface` + ready-made handlers |

The innovative core is `gui/php/src/Tiny/Gui`: a small, dependency-free protocol
framework with a clean extension point (`HandlerInterface`) instead of one giant
`switch`. Add a feature by implementing a handler and calling `Dispatcher::add()` —
no edits to a central function, no wire-format knowledge required.

## Build

```bash
# 1. native host (launcher-win.exe + runtime trio) — Windows/Cygwin
bash tools/build-launcher.sh

# 2. shim (C++ proxy) + PHP backend (app.exe) — Windows
tools\build-all.bat

# 3. run the demo
cd demo && bash ../gui/bin/tgui dev
```

## Extend it

```php
use Tiny\Gui\{Gui, State, Dispatcher, Response, Request};

require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';

$s = new State();
$d = Gui::defaultDispatcher($s);          // core + win + menu + store（不含 demo API）
$d->on('demo.greet', function (Request $req): Response {
    return Response::ok('hello ' . ($req->params['name'] ?? 'world'));
});
Gui::serveWith($d, $s);
```

Or implement `Tiny\Gui\HandlerInterface` for a self-documenting, reusable handler.

## Compatibility

- **Wire format unchanged.** The host still speaks the same line-framed
  `CALL <id> <json>` / `RET <id> <status> <json>` / `EVAL` / `DLG` / `MENU*`
  protocol, so the vendored launcher needs no changes and old frontends keep
  working.
- **`shim/backend_shell.cpp` unchanged in role** — it still proxies the host's
  IPC endpoint to the PHP backend's stdio.
- **`src/backend.php` (demo) preserved** — now a thin entrypoint that loads the
  framework; the demo build path (`tpc src/backend.php -o build/app.exe`) is intact.
