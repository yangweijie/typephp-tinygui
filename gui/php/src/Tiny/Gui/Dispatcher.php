<?php
/**
 * Routes a Request to the handler that owns its method.
 *
 * Two registration styles, both first-match-wins and both returning null to fall
 * through (so an "observer" handler can peek at a method without answering it):
 *
 *   $d->add(new DemoApiHandler());          // HandlerInterface -> self-doc methods
 *   $d->on('win.setTitle', fn($req) => ...); // one-off closure
 *   $d->onPrefix('app.', fn($req) => ...);   // wildcard group (e.g. app.*)
 *
 * Unknown methods throw, which Backend turns into a RET with status 1.
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Dispatcher
{
    /** @var array<string, callable(Request):?Response> */
    private array $exact = [];

    /** @var array<string, callable(Request):?Response> */
    private array $prefix = [];

    /** @var HandlerInterface[] */
    private array $handlers = [];

    public function add(HandlerInterface $h): void
    {
        $this->handlers[] = $h;
        foreach ($h->methods() as $m) {
            $this->exact[$m] = [$h, 'handle'];
        }
    }

    /** Register a closure for one exact method. */
    public function on(string $method, callable $fn): void
    {
        $this->exact[$method] = $fn;
    }

    /** Register a closure for every method sharing a prefix (e.g. 'app.'). */
    public function onPrefix(string $prefix, callable $fn): void
    {
        $this->prefix[$prefix] = $fn;
    }

    public function dispatch(Request $req): Response
    {
        if (isset($this->exact[$req->method])) {
            $r = ($this->exact[$req->method])($req);
            if ($r instanceof Response) {
                return $r;
            }
        }
        foreach ($this->prefix as $p => $fn) {
            if (str_starts_with($req->method, $p)) {
                $r = $fn($req);
                if ($r instanceof Response) {
                    return $r;
                }
            }
        }
        throw new \RuntimeException('unknown method: ' . $req->method);
    }
}
