<?php
/**
 * Cached launcher state. The launcher pushes WINSTATE / SYS theme / SYSLOCALE
 * notifications *before* the page registers its listeners, so — exactly like
 * tinyjsapp's bridge.js — we cache the latest values and let the page pull them
 * on demand via theme.get / system.locale / win.getState.
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class State
{
    public ?array $theme = null;     // ['dark' => bool]
    public ?array $locale = null;    // system locale blob
    public ?array $winState = null;  // last WINSTATE snapshot

    public function apply(string $event, mixed $data): void
    {
        switch ($event) {
            case 'theme':
                $this->theme = is_array($data) ? $data : null;
                break;
            case 'locale':
                $this->locale = is_array($data) ? $data : null;
                break;
            case 'window-state':
                $this->winState = is_array($data) ? $data : null;
                break;
        }
    }
}
