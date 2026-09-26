<?php
/**
 * Canonical GUI backend entrypoint. Compiled by aot-compiler:
 *   tpc gui/php/backend.php -o app.exe -f -O2
 *
 * Spawns under the C++ shim (shim/backend_shell.cpp), which proxies the
 * launcher's IPC endpoint to this process's stdio.
 */

declare(strict_types=1);

use Tiny\Gui\Gui;

require __DIR__ . '/src/Tiny/Gui/bootstrap.php';

Gui::serve();
