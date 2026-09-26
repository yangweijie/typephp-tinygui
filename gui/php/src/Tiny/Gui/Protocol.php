<?php
/**
 * Stateless wire codec for the tinyjsapp frame protocol.
 *
 * Kept byte-for-byte compatible with the launcher's read loop and with the old
 * flat src/backend.php so the vendored C++ host (gui/host/src/launcher-*.cc)
 * needs no changes. This class owns *only* text<->value translation; routing and
 * side effects live in Dispatcher / Backend.
 *
 * Frame grammar (lines, '\n' separated):
 *   launcher -> backend :  CALL <id> <json-array>        json-array = ["<payload>","<origin>"]
 *                          WINSTATE <win> <json> | SYS <kind> <value> | SYSLOCALE <json>
 *                          MENU <id> | TRAY <id> | TRAYCLICK | NAV/DROP/...
 *   backend  -> launcher :  RET <id> <status> <json>
 *                          TITLE <t> | SIZE <w> <h> | QUIT | DLG <id> <op> <args>
 *                          MENUBEGIN … MENU/ITEM/SEP/SUB/SUBEND … MENUEND
 *                          EVAL <js> | EVAL@<win> <js>     (push events to the page)
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Protocol
{
    // ---- outbound frame builders ------------------------------------------

    /** RET <id> <status> <json> */
    public static function ret(string $id, int $status, mixed $result): string
    {
        return 'RET ' . $id . ' ' . $status . ' ' . self::jenc($result);
    }

    /** Push an event to every window: EVAL@* <esc(js)> */
    public static function event(string $event, mixed $data): string
    {
        $js = 'window.__emit && window.__emit('
            . self::jenc(['event' => $event, 'data' => $data]) . ')';
        return 'EVAL@* ' . self::esc($js);
    }

    /** Push an event to a single window: EVAL@<win> <esc(js)> */
    public static function eventTo(string $win, string $event, mixed $data): string
    {
        $js = 'window.__emit && window.__emit('
            . self::jenc(['event' => $event, 'data' => $data]) . ')';
        return 'EVAL@' . $win . ' ' . self::esc($js);
    }

    // ---- text escaping (mirror of bridge.js / launcher wire_unescape) ------

    /**
     * One-line JSON. Throws JsonException on failure so the frame pump can turn
     * it into RET status=1 instead of emitting the literal "false".
     */
    public static function jenc(mixed $v): string
    {
        return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    }

    /** \ -> \\, tab/CR/LF -> \t/\r/\n (frame fields may not contain raw newlines). */
    public static function esc(string $s): string
    {
        return str_replace(["\\", "\t", "\r", "\n"], ["\\\\", "\\t", "\\r", "\\n"], $s);
    }

    /** tab/CR/LF -> space (frame is newline-separated). */
    public static function one(mixed $s): string
    {
        return str_replace(["\t", "\n", "\r"], ' ', (string)($s ?? ''));
    }

    /** Lowercase, dot-stripped, safe file-extension list for dialog filters. */
    public static function extList(mixed $types): string
    {
        if (!is_array($types)) {
            return '';
        }
        $out = [];
        foreach ($types as $t) {
            $t = strtolower(ltrim(trim((string)$t), '.'));
            if (preg_match('/^[a-z0-9][a-z0-9+._-]*$/', $t)) {
                $out[] = $t;
            }
        }
        return implode(',', $out);
    }

    // ---- native dialogs: the launcher answers these itself ----------------

    /**
     * Native dialogs are driven by the launcher directly (it owns the OS panel
     * and resolves the page promise). So the backend must emit a DLG frame and
     * *not* a RET. Returns the DLG frame, or null if $method is not a dialog.
     */
    public static function dialogFrame(string $id, string $method, array $p): ?string
    {
        $msg = self::one($p['message'] ?? '');
        $det = self::one($p['detail'] ?? '');
        switch ($method) {
            case 'dialog.openFile':
                $args = ['open', self::extList($p['types'] ?? null)];
                break;
            case 'dialog.openFiles':
                $args = ['openmulti', self::extList($p['types'] ?? null)];
                break;
            case 'dialog.pickFolder':
                $args = ['dir'];
                break;
            case 'dialog.saveFile':
                $args = ['save', self::extList($p['types'] ?? null)];
                break;
            case 'dialog.alert':
                $args = ['alert', $msg, $det, self::one($p['ok'] ?? 'OK')];
                break;
            case 'dialog.confirm':
                $args = ['confirm', $msg, $det, self::one($p['ok'] ?? 'OK'), self::one($p['cancel'] ?? 'Cancel')];
                break;
            case 'dialog.prompt':
                $args = ['prompt', $msg, self::one($p['default'] ?? ''), self::one($p['ok'] ?? 'OK'), self::one($p['cancel'] ?? 'Cancel')];
                break;
            default:
                return null;
        }
        return 'DLG ' . $id . ' ' . implode("\t", $args);
    }

    // ---- inbound decoding --------------------------------------------------

    /**
     * Decode one inbound frame line.
     *
     * @return array{type:'call', request:Request}
     *               |array{type:'bad_call', id:string, error:string}
     *               |array{type:'notification', event:string, data:mixed}
     *               |array{type:'ignore'}
     */
    public static function decode(string $raw): array
    {
        $line = rtrim($raw, "\r\n");
        if ($line === '') {
            return ['type' => 'ignore'];
        }
        if (!str_starts_with($line, 'CALL ')) {
            return self::decodeNotification($line);
        }

        $sp = strpos($line, ' ', 5);
        if ($sp === false) {
            return ['type' => 'ignore'];
        }
        $id = substr($line, 5, $sp - 5);
        if ($id === '') {
            return ['type' => 'ignore'];
        }
        $body = substr($line, $sp + 1);

        $callerWin = str_contains($id, ':')
            ? substr($id, 0, strpos($id, ':'))
            : 'main';

        $args = json_decode($body, true);
        // Real launcher sends a JSON array ["<payload>","<origin>"]; a headless
        // smoke test may send a bare object {"method":...} — accept both.
        if (is_array($args) && array_is_list($args)) {
            $payload = $args[0] ?? '{}';
            $origin = $args[1] ?? null;
            $msg = is_string($payload) ? json_decode($payload, true) : $payload;
        } else {
            $origin = null;
            $msg = $args;
        }
        if (!is_array($msg) || !isset($msg['method']) || !is_string($msg['method']) || $msg['method'] === '') {
            return ['type' => 'bad_call', 'id' => $id, 'error' => 'invalid CALL payload'];
        }
        $req = new Request(
            $id,
            (string)$msg['method'],
            (array)($msg['params'] ?? []),
            is_string($origin) ? $origin : null,
            $callerWin,
        );
        return ['type' => 'call', 'request' => $req];
    }

    private static function decodeNotification(string $line): array
    {
        // WINSTATE <win> <json>
        if (str_starts_with($line, 'WINSTATE ')) {
            $sp = strpos($line, ' ', 9);
            if ($sp === false) {
                return ['type' => 'ignore'];
            }
            $win = substr($line, 9, $sp - 9);
            $st = json_decode(substr($line, $sp + 1), true);
            $data = ['win' => $win] + (is_array($st) ? $st : []);
            return ['type' => 'notification', 'event' => 'window-state', 'data' => $data];
        }
        // SYS theme <light|dark> ; SYS sleep|wake
        if (str_starts_with($line, 'SYS ')) {
            $parts = explode(' ', substr($line, 4), 3);
            $kind = $parts[0] ?? '';
            if ($kind === 'theme') {
                $data = ['dark' => ($parts[1] ?? '') === 'dark'];
                return ['type' => 'notification', 'event' => 'theme', 'data' => $data];
            }
            return ['type' => 'notification', 'event' => $kind, 'data' => []];
        }
        // SYSLOCALE <json>
        if (str_starts_with($line, 'SYSLOCALE ')) {
            $info = json_decode(substr($line, 10), true);
            if (!is_array($info)) {
                return ['type' => 'ignore'];
            }
            return ['type' => 'notification', 'event' => 'locale', 'data' => $info];
        }
        if (str_starts_with($line, 'MENU ')) {
            $id = substr($line, 5);
            return ['type' => 'notification', 'event' => 'menu', 'data' => ['id' => $id]];
        }
        if (str_starts_with($line, 'TRAY ')) {
            $id = substr($line, 5);
            return ['type' => 'notification', 'event' => 'tray', 'data' => ['id' => $id]];
        }
        if ($line === 'TRAYCLICK') {
            return ['type' => 'notification', 'event' => 'trayclick', 'data' => []];
        }
        // NAV / DROP / HOTKEY / GOT / … — not consumed by the core; ignore.
        return ['type' => 'ignore'];
    }
}
