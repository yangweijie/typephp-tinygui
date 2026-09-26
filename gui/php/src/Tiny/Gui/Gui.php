<?php
/**
 * Facade: build the default dispatcher (all built-in handlers) and serve.
 *
 *   require '…/bootstrap.php';
 *   \Tiny\Gui\Gui::serve();                       // built-ins only
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
    public static function defaultDispatcher(State $s): Dispatcher
    {
        $d = new Dispatcher();
        $d->add(new Handlers\CoreHandler($s));
        $d->add(new Handlers\WinHandler());
        $d->add(new Handlers\MenuHandler());
        $d->add(new Handlers\StoreHandler());
        $d->add(new Handlers\DemoApiHandler());
        return $d;
    }

    public static function serve(): void
    {
        $s = new State();
        self::serveWith(self::defaultDispatcher($s), $s);
    }

    public static function serveWith(Dispatcher $d, ?State $s = null): void
    {
        Backend::run($d, $s);
    }
}
