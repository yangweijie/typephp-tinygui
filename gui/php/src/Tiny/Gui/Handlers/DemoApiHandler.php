<?php
/**
 * Demo business API — proves the computation really happens in PHP. Replace or
 * extend this with your own domain logic; it is the template for app handlers.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{HandlerInterface, Request, Response};

final class DemoApiHandler implements HandlerInterface
{
    public function methods(): array
    {
        return [
            'api.version', 'api.sum', 'api.sha256', 'api.fib', 'api.now', 'api.echo',
            // Any 'app.*' method is also accepted via the prefix registration in
            // bootstrap.php, falling back to this handler for forward-compat.
        ];
    }

    public function handle(Request $req): ?Response
    {
        return match ($req->method) {
            'api.version' => Response::ok(['php' => PHP_VERSION, 'backend' => 'tpc-AOT']),
            'api.sum'     => Response::ok(array_sum(array_map('intval', array_values($req->params)))),
            'api.sha256'  => Response::ok(hash('sha256', (string)($req->params['text'] ?? ''))),
            'api.fib'     => Response::ok($this->fib((int)($req->params['n'] ?? 30))),
            'api.now'     => Response::ok([
                'iso'     => date('c'),
                'epoch'   => time(),
                'caller'  => $req->callerWin,
            ]),
            'api.echo'    => Response::ok($req->params),
            default       => null,
        };
    }

    private function fib(int $n): int
    {
        $n = max(0, $n);
        $a = 0;
        $b = 1;
        for ($i = 0; $i < $n; $i++) {
            [$a, $b] = [$b, $a + $b];
        }
        return $a;
    }
}
