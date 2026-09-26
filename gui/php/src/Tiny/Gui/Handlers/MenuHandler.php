<?php
/**
 * Menu bar: a single menu.set produces a multi-frame declaration block
 * (MENUBEGIN … MENU/ITEM/SEP/SUB/SUBEND … MENUEND) sent to the launcher before
 * the RET. Mirrors tinyjsapp's bridge.js sendMenuBlock.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{HandlerInterface, Protocol, Request, Response};

final class MenuHandler implements HandlerInterface
{
    public function methods(): array
    {
        return ['menu.set'];
    }

    public function handle(Request $req): ?Response
    {
        if ($req->method !== 'menu.set') {
            return null;
        }
        return Response::ok(true, $this->menuFrames((array)($req->params['menus'] ?? [])));
    }

    /** @param array<int,array> $menus */
    private function menuFrames(array $menus): array
    {
        $stockRoles = ['standard', 'undo', 'redo', 'cut', 'copy', 'paste', 'selectAll'];
        $out = ['MENUBEGIN'];
        foreach ($menus as $m) {
            if (!empty($m['role'])) {
                $out[] = 'MENUROLE ' . Protocol::one($m['role']);
                foreach ((array)($m['items'] ?? []) as $it) {
                    if (!empty($it['role']) && in_array($it['role'], $stockRoles, true)) {
                        $out[] = 'ROLEITEM ' . $it['role'];
                    }
                }
                continue;
            }
            $out[] = 'MENU ' . Protocol::one($m['title'] ?? '');
            foreach ((array)($m['items'] ?? []) as $it) {
                if (!empty($it['role'])) {
                    if (in_array($it['role'], $stockRoles, true)) {
                        $out[] = 'ROLEITEM ' . $it['role'];
                    }
                    continue;
                }
                if (!empty($it['separator'])) {
                    $out[] = 'SEP';
                    continue;
                }
                if (!empty($it['submenu'])) {
                    $out[] = 'SUB ' . implode("\t", [
                        Protocol::one($it['id'] ?? ''), Protocol::one($it['label'] ?? $it['id'] ?? ''),
                    ]);
                    foreach ((array)$it['submenu'] as $s) {
                        $out[] = 'ITEM ' . implode("\t", [
                            Protocol::one($s['id'] ?? ''), Protocol::one($s['label'] ?? $s['id'] ?? ''),
                            Protocol::one($s['key'] ?? ''), '',
                        ]);
                    }
                    $out[] = 'SUBEND';
                    continue;
                }
                $flags = (!empty($it['checked']) ? 'c' : '')
                       . (isset($it['enabled']) && $it['enabled'] === false ? 'd' : '');
                $out[] = 'ITEM ' . implode("\t", [
                    Protocol::one($it['id'] ?? ''), Protocol::one($it['label'] ?? $it['id'] ?? ''),
                    Protocol::one($it['key'] ?? ''), $flags,
                ]);
            }
        }
        $out[] = 'MENUEND';
        return $out;
    }
}
