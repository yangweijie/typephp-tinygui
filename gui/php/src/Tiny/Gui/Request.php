<?php
/**
 * A single inbound CALL frame, decoded into a typed value object.
 *
 * The wire format (verbatim with tinyjsapp's launcher) is:
 *   launcher -> backend :  CALL <id> ["<payload-json>", "<origin>"]
 * where <payload-json> = {"method": "...", "params": {...}}.
 *
 * Tiny\Gui\Protocol::decode() produces one of these so handlers never parse
 * frames by hand.
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Request
{
    public function __construct(
        public string $id,
        public string $method,
        public array $params,
        public ?string $origin,
        /** 'main' or a win.open() id; lets a handler see *which* window called. */
        public string $callerWin,
    ) {
    }

    /** Convenience accessor mirroring the old flat backend's pattern. */
    public function param(string $key, mixed $default = null): mixed
    {
        return $this->params[$key] ?? $default;
    }
}
