<?php
/**
 * The frame pump. One process, one stdin/stdout frame channel (the C++ shim
 * proxies the launcher's IPC endpoint to our stdio — see gui/host and
 * shim/backend_shell.cpp). Three channels stay separate: stdout is THE WIRE,
 * stderr is diagnostics only (logged by the shim, never forwarded), so write
 * debug output to STDERR.
 *
 * processLine() is pure and testable; run() wraps it over real stdio.
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class Backend
{
    /**
     * Turn one inbound frame line into the bytes to write back (may be several
     * newline-terminated frames, or null if the line was empty/ignored).
     */
    public static function processLine(string $line, Dispatcher $d, State $s): ?string
    {
        $dec = Protocol::decode($line);

        if ($dec['type'] === 'ignore') {
            return null;
        }

        if ($dec['type'] === 'notification') {
            $s->apply($dec['event'], $dec['data']);
            return $dec['frame'] . "\n";
        }

        $req = $dec['request'];

        // Native dialogs are answered by the launcher itself — emit the DLG
        // frame and NOT a RET (mirrors bridge.js: `if (dlg) { send(...); return; }`).
        $dlg = Protocol::dialogFrame($req->id, $req->method, $req->params);
        if ($dlg !== null) {
            return $dlg . "\n";
        }

        try {
            $resp = $d->dispatch($req);
        } catch (\Throwable $e) {
            $resp = Response::error($e->getMessage());
        }

        $out = '';
        foreach ($resp->frames as $f) {
            $out .= $f . "\n";
        }
        $out .= Protocol::ret($req->id, $resp->status, $resp->result) . "\n";
        return $out;
    }

    /** Blocking stdin -> stdout loop. Emit "READY" so the shim knows we're up. */
    public static function run(Dispatcher $d, ?State $s = null): void
    {
        $s ??= new State();
        self::emit("READY\n");

        $buf = '';
        while (true) {
            $chunk = fread(STDIN, 4096);
            if ($chunk === false || $chunk === '') {
                if (feof(STDIN)) {
                    break;
                }
                continue;
            }
            $buf .= $chunk;
            while (($nl = strpos($buf, "\n")) !== false) {
                $frame = substr($buf, 0, $nl);
                $buf = substr($buf, $nl + 1);
                $resp = self::processLine($frame, $d, $s);
                if ($resp !== null) {
                    self::emit($resp);
                }
            }
        }
        if (trim($buf) !== '') {
            $resp = self::processLine($buf, $d, $s);
            if ($resp !== null) {
                self::emit($resp);
            }
        }
    }

    private static function emit(string $s): void
    {
        fwrite(STDOUT, $s);
        fflush(STDOUT);
    }
}
