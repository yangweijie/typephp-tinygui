<?php
/**
 * Headless smoke test for the Tiny\Gui framework. No window, no launcher — feeds
 * frame lines into Backend::processLine() and asserts the wire output.
 *
 *   php gui/php/test/smoke.php
 */

declare(strict_types=1);

use Tiny\Gui\{AppRoot, Backend, Dispatcher, Gui, Protocol, Response, State};

require __DIR__ . '/../src/Tiny/Gui/bootstrap.php';

$sandbox = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'tgui-smoke-' . bin2hex(random_bytes(4));
mkdir($sandbox);
file_put_contents($sandbox . DIRECTORY_SEPARATOR . 'hello.txt', "hi\n");
putenv('TYPEPHP_APP_ROOT=' . $sandbox);

$s = new State();
$d = Gui::demoDispatcher($s, new AppRoot((string)realpath($sandbox)));
$d->on('test.nan', fn() => Response::ok(NAN));

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

// 11. malformed CALL with id still RETs an error (does not hang the launcher)
$out = Backend::processLine('CALL 11 not-json', $d, $s);
check('bad CALL payload -> RET status 1', str_starts_with($out ?? '', 'RET 11 1 '), (string)$out);

$out = Backend::processLine($call('12', ''), $d, $s);
check('empty method -> RET status 1', str_starts_with($out ?? '', 'RET 12 1 '), (string)$out);

// 12. unencodable RET becomes status 1, never the literal false
$out = Backend::processLine($call('13', 'test.nan'), $d, $s);
check('NAN result -> json encode error RET', str_starts_with($out ?? '', 'RET 13 1 ') && !str_contains((string)$out, 'false'), (string)$out);

// 13. listDir / fs sandbox
$out = Backend::processLine($call('14', 'listDir', ['path' => '.']), $d, $s);
check('listDir . inside sandbox', str_starts_with($out ?? '', 'RET 14 0 ') && str_contains((string)$out, 'hello.txt'), (string)$out);

$out = Backend::processLine($call('15', 'listDir', ['path' => '..']), $d, $s);
check('listDir .. rejected', str_starts_with($out ?? '', 'RET 15 1 '), (string)$out);

$out = Backend::processLine($call('16', 'fs.readText', ['path' => 'hello.txt']), $d, $s);
check('fs.readText hello.txt', $out === "RET 16 0 \"hi\\n\"\n", (string)$out);

$out = Backend::processLine($call('17', 'fs.writeText', ['path' => 'out.txt', 'content' => 'ok']), $d, $s);
check('fs.writeText out.txt', $out === "RET 17 0 true\n", (string)$out);
check('fs.writeText landed', is_file($sandbox . DIRECTORY_SEPARATOR . 'out.txt') && file_get_contents($sandbox . DIRECTORY_SEPARATOR . 'out.txt') === 'ok');

$out = Backend::processLine($call('18', 'fs.exists', ['path' => 'hello.txt']), $d, $s);
check('fs.exists true', $out === "RET 18 0 true\n", (string)$out);

$out = Backend::processLine($call('19', 'store.set', []), $d, $s);
check('store.set missing key -> error', str_starts_with($out ?? '', 'RET 19 1 '), (string)$out);

$out = Backend::processLine($call('20', 'api.echo', ['x' => 1]), $d, $s);
check('api.echo', $out === "RET 20 0 {\"x\":1}\n", (string)$out);

$empty = Gui::defaultDispatcher($s, new AppRoot((string)realpath($sandbox)));
$out = Backend::processLine($call('21', 'api.fib', ['n' => 10]), $empty, $s);
check('empty app has no api.fib', str_starts_with($out ?? '', 'RET 21 1 '), (string)$out);

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
