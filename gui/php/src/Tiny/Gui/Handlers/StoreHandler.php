<?php
/**
 * In-memory key/value store (tiny.store.get/set/all). Backed by a plain array so
 * it survives for the life of the backend process; pair with tinyjs.json
 * persistence if you need it across restarts.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{HandlerInterface, Request, Response};

final class StoreHandler implements HandlerInterface
{
    /** @var array<string,mixed> */
    private array $store = [];

    public function methods(): array
    {
        return ['store.get', 'store.set', 'store.all'];
    }

    public function handle(Request $req): ?Response
    {
        return match ($req->method) {
            'store.get' => Response::ok($this->store[(string)($req->params['key'] ?? '')] ?? null),
            'store.set' => $this->set($req),
            'store.all' => Response::ok($this->store),
            default     => null,
        };
    }

    private function set(Request $req): Response
    {
        $this->store[(string)$req->params['key']] = $req->params['value'] ?? null;
        return Response::ok(true);
    }
}
