<?php
/**
 * Single include that pulls in the whole Tiny\Gui framework. No autoloader
 * needed — aot-compiler (tpc) bundles every require at compile time, and the dev
 * `php` path just runs them in order.
 */

declare(strict_types=1);

namespace Tiny\Gui;

require_once __DIR__ . '/Request.php';
require_once __DIR__ . '/Response.php';
require_once __DIR__ . '/HandlerInterface.php';
require_once __DIR__ . '/Protocol.php';
require_once __DIR__ . '/State.php';
require_once __DIR__ . '/Dispatcher.php';
require_once __DIR__ . '/Gui.php';
require_once __DIR__ . '/Backend.php';
require_once __DIR__ . '/Handlers/CoreHandler.php';
require_once __DIR__ . '/Handlers/WinHandler.php';
require_once __DIR__ . '/Handlers/MenuHandler.php';
require_once __DIR__ . '/Handlers/StoreHandler.php';
require_once __DIR__ . '/Handlers/DemoApiHandler.php';
