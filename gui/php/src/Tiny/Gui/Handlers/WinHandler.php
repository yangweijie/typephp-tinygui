<?php
/**
 * Window control: setTitle / setSize emit a window frame that the launcher
 * applies *before* the RET, and quit emits QUIT. These are the only methods that
 * send a non-RET frame back with the answer.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{HandlerInterface, Protocol, Request, Response};

final class WinHandler implements HandlerInterface
{
    public function methods(): array
    {
        return ['win.setTitle', 'win.setSize', 'quit'];
    }

    public function handle(Request $req): ?Response
    {
        return match ($req->method) {
            'win.setTitle' => Response::ok(true, [
                'TITLE ' . str_replace(["\r", "\n"], ' ', (string)($req->params['title'] ?? 'tinyjs')),
            ]),
            'win.setSize' => Response::ok(true, [
                'SIZE ' . (int)($req->params['width'] ?? 960) . ' ' . (int)($req->params['height'] ?? 640),
            ]),
            'quit' => Response::ok(true, ['QUIT']),
            default => null,
        };
    }
}
