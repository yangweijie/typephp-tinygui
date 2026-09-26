<?php
/**
 * A handler owns one or more tiny.* methods. Register it on the Dispatcher and
 * it receives every matching Request; return a Response to answer, or null to
 * let the next handler try (a handler that purely observes a method can return
 * null after doing its side effect).
 *
 * This is the primary extension point for app authors — implement this and call
 * Dispatcher::addHandler(). See Tiny\Gui\Handlers\DemoApiHandler for a sample.
 */

declare(strict_types=1);

namespace Tiny\Gui;

interface HandlerInterface
{
    /**
     * @return string[] method names (exact) this handler answers, e.g.
     *                 ['api.sum', 'api.sha256']. Use Dispatcher::onPrefix() for
     *                 wildcard groups like 'win.*'.
     */
    public function methods(): array;

    /** @return Response|null  a Response to answer, or null to fall through. */
    public function handle(Request $req): ?Response;
}
