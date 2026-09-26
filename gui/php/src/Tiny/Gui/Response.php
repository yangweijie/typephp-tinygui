<?php
/**
 * A handler's reply. Carries the value returned to the page (RET <id> <status>
 * <json>) plus any *window frames* that must be emitted to the launcher
 * *before* the RET — e.g. TITLE / SIZE / QUIT.
 *
 * Static factories keep handler code declarative:
 *   return Response::ok(['php' => PHP_VERSION]);
 *   return Response::error('unknown method');
 *   return Response::ok(true, ['QUIT']);          // quit after answering
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Response
{
    /**
     * @param mixed $result  the JSON-serialisable value returned to the page
     * @param int   $status  0 = ok, non-zero = error (launcher treats it as rejected)
     * @param string[] $frames  window frames emitted before RET (TITLE/SIZE/QUIT/...)
     */
    public function __construct(
        public mixed $result = null,
        public int $status = 0,
        public array $frames = [],
    ) {
    }

    public static function ok(mixed $result = true, array $frames = []): self
    {
        return new self($result, 0, $frames);
    }

    public static function error(string $message, array $frames = []): self
    {
        return new self($message, 1, $frames);
    }

    public function isError(): bool
    {
        return $this->status !== 0;
    }
}
