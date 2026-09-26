<?php
/**
 * Headless smoke test for the Tiny\Gui framework. No window, no launcher — feeds
 * frame lines into Backend::processLine() and asserts the wire output.
 *
 *   php gui/php/test/smoke.php
 */

declare(strict_types=1);

use Tiny\Gui\{Backend, Dispatcher, Gui, Protocol, State};

require __DIR__ . '/../src/Tiny/Gui/bootstrap.php';

$s = new State();
$d = Gui::defaultDispatcher($s);

$fail = 0;
$pass = 0;
function check(string $name, bool $ok, string $detail = ''): void
{
    global $pass, $fail;
    if ($ok) {
        $pass++;
        echo "  ok   $name\n";
    } else {
        $fail++;
        echo "  FAIL $name  $detail\n";
    }
}

// Build a CALL frame exactly as the launcher would: body = JSON array
// ["<payload-string>", "<origin>"].
$call = fn(string $id, string $method, array $params = [], string $origin = '') =>
    'CALL ' . $id . ' ' . Protocol::jenc([Protocol::jenc(['method' => $method, 'params' => $params]), $origin]);

// 1. ping
$out = Backend::processLine($call('1', 'ping'), $d, $s);
check('ping -> pong', $out === 'RET 1 0 "pong"' . "\n", (string)$out);

// 2. api.fib n=10 -> 55
$out = Backend::processLine($call('2', 'api.fib', ['n' => 10]), $d, $s);
check('api.fib(10) == 55', $out === 'RET 2 0 55' . "\n", (string)$out);

// 3. win.setTitle emits TITLE before RET
$out = Backend::processLine($call('3', 'win.setTitle', ['title' => 'Hi']), $d, $s);
check('win.setTitle -> TITLE+RET', $out === "TITLE Hi\nRET 3 0 true\n", (string)$out);

// 4. menu.set emits the full block
$out = Backend::processLine($call('4', 'menu.set', ['menus' => [
    ['title' => 'File', 'items' => [['id' => 'new', 'label' => 'New']]],
]]), $d, $s);
// Launcher fields are TAB-separated (matches bridge.js wire_unescape). Use real tabs.
$t = "\t";
$expect = "MENUBEGIN\nMENU File\nITEM new{$t}New{$t}{$t}\nMENUEND\nRET 4 0 true\n";
check('menu.set -> block', $out === $expect, (string)$out);

// 5. dialog short-circuit: DLG frame, NO RET (tab-separated: id op msg det ok cancel)
$out = Backend::processLine($call('5', 'dialog.confirm', ['message' => 'OK?']), $d, $s);
check('dialog.confirm -> DLG (no RET)', $out === "DLG 5 confirm{$t}OK?{$t}{$t}OK{$t}Cancel\n", (string)$out);

// 6. notification caches + emits EVAL event; then theme.get returns it
$out = Backend::processLine('SYS theme dark', $d, $s);
check('SYS theme -> EVAL event', str_starts_with($out ?? '', 'EVAL@* '), (string)$out);
$out = Backend::processLine($call('6', 'theme.get'), $d, $s);
check('theme.get -> cached {dark:true}', $out === 'RET 6 0 {"dark":true}' . "\n", (string)$out);

// 7. WINSTATE caches; win.getState returns it
$out = Backend::processLine('WINSTATE main {"width":800,"height":600}', $d, $s);
check('WINSTATE -> EVAL event', str_starts_with($out ?? '', 'EVAL@* '), (string)$out);
$out = Backend::processLine($call('7', 'win.getState'), $d, $s);
check('win.getState -> cached', $out === 'RET 7 0 {"win":"main","width":800,"height":600}' . "\n", (string)$out);

// 8. unknown method -> RET status 1
$out = Backend::processLine($call('8', 'no.such'), $d, $s);
check('unknown -> error', str_starts_with($out ?? '', 'RET 8 1 '), (string)$out);

// 9. store round-trip
Backend::processLine($call('9', 'store.set', ['key' => 'k', 'value' => ['a' => 1]]), $d, $s);
$out = Backend::processLine($call('10', 'store.get', ['key' => 'k']), $d, $s);
check('store set/get', $out === 'RET 10 0 {"a":1}' . "\n", (string)$out);

// 10. empty line ignored (null)
check('empty line ignored', Backend::processLine('', $d, $s) === null);

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
