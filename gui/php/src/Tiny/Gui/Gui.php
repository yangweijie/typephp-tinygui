<?php
/**
 * Facade: build the default dispatcher (all built-in handlers) and serve.
 *
 *   require '…/bootstrap.php';
 *   \Tiny\Gui\Gui::serve();                       // empty app: Core/Win/Menu/Store
 *   \Tiny\Gui\Gui::serveDemo();                   // plus DemoApiHandler (api.*)
 *
 *   // or extend before serving:
 *   $s = new \Tiny\Gui\State();
 *   $d = \Tiny\Gui\Gui::defaultDispatcher($s);
 *   $d->on('my.thing', fn($req) => \Tiny\Gui\Response::ok('ok'));
 *   \Tiny\Gui\Gui::serveWith($d, $s);
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Gui
{
    public static function defaultDispatcher(State $s, ?AppRoot $root = null): Dispatcher
    {
        $root ??= AppRoot::fromEnv();
        $d = new Dispatcher();
        $d->add(new Handlers\CoreHandler($s, $root));
        $d->add(new Handlers\WinHandler());
        $d->add(new Handlers\MenuHandler());
        $d->add(new Handlers\StoreHandler());
        return $d;
    }

    /** Same as defaultDispatcher, plus DemoApiHandler (`api.fib` / `api.echo` / …). */
    public static function demoDispatcher(State $s, ?AppRoot $root = null): Dispatcher
    {
        $d = self::defaultDispatcher($s, $root);
        $d->add(new Handlers\DemoApiHandler());
        return $d;
    }

    public static function serve(): void
    {
        $s = new State();
        self::serveWith(self::defaultDispatcher($s), $s);
    }

    public static function serveDemo(): void
    {
        $s = new State();
        self::serveWith(self::demoDispatcher($s), $s);
    }

    public static function serveWith(Dispatcher $d, ?State $s = null): void
    {
        Backend::run($d, $s);
    }
}
