<?php
/**
 * Demo backend for the TypePHP GUI framework (typephp-gui).
 *
 * This is the entrypoint compiled by tools/build-all.bat (`tpc src/backend.php
 * -o build/app.exe`). It loads the bundled framework under gui/php and serves
 * the demo dispatcher (core / window / menu / store + DemoApiHandler).
 *
 * Empty apps should call Gui::serve() / defaultDispatcher() so api.* is not
 * registered. To add your own tiny.* methods:
 *
 *   use Tiny\Gui\{Gui, State, Dispatcher, Response};
 *   require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';
 *   $s = new State();
 *   $d = Gui::defaultDispatcher($s);
 *   $d->on('demo.greet', function (\Tiny\Gui\Request $req) {
 *       return Response::ok('hello ' . ($req->params['name'] ?? 'world'));
 *   });
 *   Gui::serveWith($d, $s);
 *
 * Protocol & stdio contract: see gui/README.md and Tiny\Gui\Protocol.
 * stdout is THE WIRE (frames only); write debug output to STDERR.
 */

declare(strict_types=1);

use Tiny\Gui\Gui;

require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';

Gui::serveDemo();
