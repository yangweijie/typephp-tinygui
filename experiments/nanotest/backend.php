<?php
/**
 * tinyjsapp 后端（方案 B）：C++ launcher 父进程 + aot-compiler 编出的 PHP 子进程，
 * 经 C++ shim 的命名管道走 tinyjsapp 的 CALL/RET 帧协议。
 *
 * 编译：tpc.exe backend.php -o app.exe -f -O2      （bin 模式；Windows 上 nano 不可用）
 * 运行：由 backend_shell.exe（shim）以继承 stdio 方式 spawn。
 *
 * 协议（逐字对齐 runtime/bridge.js 的 handleCall 与 launcher-win.cc 的 pipe_read_loop）：
 *   帧 = 单行，'\n' 分隔
 *   launcher -> backend :  CALL <id> <json-args-array>
 *        json-args-array = ["<payload>", "<origin>"]     // payload 是页面传的 JSON 字符串
 *        payload         = {"method":"<m>","params":{...}}
 *        （launcher APPEND 调用帧的 origin 作为最后一元素，故其位置在末尾）
 *   backend  -> launcher:  RET <id> <status> <json>       // status 0=ok，非 0=error
 *                          TITLE <text>                   // 设置窗口标题
 *                          SIZE <w> <h>                   // 调整窗口尺寸
 *                          EVAL <js>                      // 在页面里跑 JS
 *                          QUIT                           // 关闭窗口
 *   （窗口类帧必须在 RET 之前发出；shim 会一路转发到 RET 行为止。）
 */

/**
 * 缓存的系统状态。launcher 的 WINSTATE / SYS theme / SYSLOCALE 通知帧在页面
 * 导航**之前**就会到达，此时页面还没有注册处理函数 —— 与 bridge.js 一样，
 * 后端把最近值缓存下来，页面用 theme.get / system.locale 按需拉取。
 */
final class TinyState
{
    public static ?array $theme = null;
    public static ?array $locale = null;
    public static ?array $winstate = null;
}

/** 写一帧并立即 flush。stdout 是管道时 C stdio 默认块缓冲(4KB)，小帧不及时送达会 hang。 */
function emit(string $s): void
{
    fwrite(STDOUT, $s);
    fflush(STDOUT);
}

/** 单行 JSON。 */
function jenc(mixed $v): string
{
    return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

/**
 * 与 bridge.js 的 esc() 逐字一致：把文本做成可安全放进帧字段的形式
 * （\ -> \\，tab/CR/LF -> \t/\r/\n）。launcher 侧 wire_unescape 是其逆运算。
 */
function esc(string $s): string
{
    return str_replace(
        ["\\", "\t", "\r", "\n"],
        ["\\\\", "\\t", "\\r", "\\n"],
        $s
    );
}

/** 把事件推给页面（main + 所有子窗口）：EVAL@* <esc(js)>。 */
function emitEvent(string $event, mixed $data): string
{
    return 'EVAL@* ' . esc(
        'window.__emit && window.__emit(' . jenc(['event' => $event, 'data' => $data]) . ')'
    ) . "\n";
}

/** 与 bridge.js 的 one() 一致：tab/CR/LF 拍平成空格（帧是换行分隔的）。 */
function one(mixed $s): string
{
    return str_replace(["\t", "\n", "\r"], ' ', (string)($s ?? ''));
}

/** 与 bridge.js 的 extList() 一致：文件类型过滤串。 */
function extList(mixed $types): string
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

/**
 * 原生对话框：**由 launcher 自己应答**（不经过我们），它拿到 id 后直接
 * resolve 页面的 promise（launcher-win.cc 的 route_ret）。
 * 因此后端必须发 `DLG <id> <op>\t<args...>` 并且**不发 RET**
 * —— 与 bridge.js 的 handleCall 里 `if (dlg) { send(...); return; }` 同构。
 * 返回 null 表示这不是对话框方法。
 */
function dialogFrame(string $id, string $method, array $p): ?string
{
    $msg  = one($p['message'] ?? '');
    $det  = one($p['detail'] ?? '');
    switch ($method) {
        case 'dialog.openFile':
            $args = ['open', extList($p['types'] ?? null)];
            break;
        case 'dialog.openFiles':
            $args = ['openmulti', extList($p['types'] ?? null)];
            break;
        case 'dialog.pickFolder':
            $args = ['dir'];
            break;
        case 'dialog.saveFile':
            $args = ['save', extList($p['types'] ?? null)];
            break;
        case 'dialog.alert':
            $args = ['alert', $msg, $det, one($p['ok'] ?? 'OK')];
            break;
        case 'dialog.confirm':
            $args = ['confirm', $msg, $det, one($p['ok'] ?? 'OK'), one($p['cancel'] ?? 'Cancel')];
            break;
        case 'dialog.prompt':
            $args = ['prompt', $msg, one($p['default'] ?? ''), one($p['ok'] ?? 'OK'), one($p['cancel'] ?? 'Cancel')];
            break;
        default:
            return null;
    }
    return 'DLG ' . $id . ' ' . implode("\t", $args);
}

/**
 * 菜单栏：多帧声明块（MENUBEGIN … MENU / ITEM / SEP / SUB / MENUEND）。
 * 与 bridge.js 的 sendMenuBlock + sendItems 一致。Windows 没有 stock
 * 编辑菜单，故 role 块直接落成 MENUROLE（launcher 侧对未知 role 会丢弃 items）。
 */
function menuFrames(array $params): array
{
    $stockRoles = ['standard', 'undo', 'redo', 'cut', 'copy', 'paste', 'selectAll'];
    $out = ['MENUBEGIN'];
    foreach ((array)($params['menus'] ?? []) as $m) {
        if (!empty($m['role'])) {
            $out[] = 'MENUROLE ' . one($m['role']);
            foreach ((array)($m['items'] ?? []) as $it) {
                if (!empty($it['role']) && in_array($it['role'], $stockRoles, true)) {
                    $out[] = 'ROLEITEM ' . $it['role'];
                }
            }
            continue;
        }
        $out[] = 'MENU ' . one($m['title'] ?? '');
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
                $out[] = 'SUB ' . implode("\t", [one($it['id'] ?? ''), one($it['label'] ?? $it['id'] ?? '')]);
                foreach ((array)$it['submenu'] as $s) {
                    $out[] = 'ITEM ' . implode("\t", [
                        one($s['id'] ?? ''), one($s['label'] ?? $s['id'] ?? ''), one($s['key'] ?? ''), '',
                    ]);
                }
                $out[] = 'SUBEND';
                continue;
            }
            $flags = (!empty($it['checked']) ? 'c' : '')
                   . (isset($it['enabled']) && $it['enabled'] === false ? 'd' : '');
            $out[] = 'ITEM ' . implode("\t", [
                one($it['id'] ?? ''), one($it['label'] ?? $it['id'] ?? ''), one($it['key'] ?? ''), $flags,
            ]);
        }
    }
    $out[] = 'MENUEND';
    return $out;
}

/**
 * 通知帧（launcher -> backend，无需 RET）：对齐 bridge.js 的读循环，
 * 把状态变化用 EVAL 推给页面。返回要写回的帧（或 null）。
 */
function frameForNotification(string $line): ?string
{
    // WINSTATE <win> <json> —— 窗口状态快照 -> 'window-state'
    if (str_starts_with($line, 'WINSTATE ')) {
        $sp = strpos($line, ' ', 9);
        if ($sp === false) {
            return null;
        }
        $win = substr($line, 9, $sp - 9);
        $st  = json_decode(substr($line, $sp + 1), true);
        $data = ['win' => $win] + (is_array($st) ? $st : []);
        TinyState::$winstate = $data;
        return emitEvent('window-state', $data);
    }

    // SYS theme light|dark -> 'theme' {dark};SYS sleep|wake -> 'sleep'/'wake'
    if (str_starts_with($line, 'SYS ')) {
        $parts = explode(' ', substr($line, 4), 3);
        $kind  = $parts[0] ?? '';
        $value = $parts[1] ?? '';
        if ($kind === 'theme') {
            TinyState::$theme = ['dark' => $value === 'dark'];
            return emitEvent('theme', TinyState::$theme);
        }
        return emitEvent($kind, []);   // sleep | wake
    }

    // SYSLOCALE <json> -> 'locale'
    if (str_starts_with($line, 'SYSLOCALE ')) {
        $info = json_decode(substr($line, 10), true);
        if (!is_array($info)) {
            return null;
        }
        TinyState::$locale = $info;
        return emitEvent('locale', $info);
    }

    // 菜单/托盘点击：launcher 发 `MENU <id>` / `TRAY <id>` / `TRAYCLICK`
    if (str_starts_with($line, 'MENU ')) {
        return emitEvent('menu', ['id' => substr($line, 5)]);
    }
    if (str_starts_with($line, 'TRAY ')) {
        return emitEvent('tray', ['id' => substr($line, 5)]);
    }
    if ($line === 'TRAYCLICK') {
        return emitEvent('trayclick', []);
    }

    // 其余通知帧（NAV/DROP/HOTKEY/GOT/…）本演示不消费：
    // 静默忽略。绝不写 STDERR —— shim 把 stderr 并进 stdout 转给 launcher，
    // 那会把垃圾行塞进帧流（launcher 会忽略，但脏）。
    return null;
}

/**
 * 业务分发。返回 [result, frames]；frames 是 RET 之前要发给 launcher 的窗口类帧。
 */
function dispatch(string $method, array $params, string $callerWin): array
{
    static $store = [];

    switch ($method) {
        // ---- 基础存活/自检 -------------------------------------------------
        case 'ping':
            return ['pong', []];
        // 每个页面在 tiny.js 就绪后都会宣告一次（bridge.js 的 API_ALWAYS 之一）。
        case 'client.hello':
            return [true, []];
        case 'log':
            fwrite(STDERR, '[php-backend] ' . jenc($params['msg'] ?? $params) . "\n");
            return [true, []];

        // ---- 系统信息（页面信息卡渲染用） ---------------------------------
        case 'sysinfo':
            return [[
                'runtime' => 'PHP ' . PHP_VERSION,
                'host'    => (string)(gethostname() ?: 'windows'),
                'cpu'     => (string)(php_uname('m')),
                'pid'     => (int)getmypid(),
                'cwd'     => (string)getcwd(),
                'home'    => (string)(getenv('USERPROFILE') ?: getenv('HOME') ?: ''),
                'os'      => (string)PHP_OS_FAMILY,
                'backend' => 'aot-compiler (tpc) AOT native',
            ], []];

        // ---- 目录浏览（后端真实文件系统访问的证明） -----------------------
        case 'listDir':
            $path = (string)($params['path'] ?? getcwd());
            $out  = [];
            $dh   = @opendir($path);
            if ($dh === false) {
                throw new \RuntimeException("cannot open dir: {$path}");
            }
            while (($e = readdir($dh)) !== false) {
                if ($e === '.' || $e === '..') {
                    continue;
                }
                $out[] = ['name' => $e, 'isDir' => is_dir($path . DIRECTORY_SEPARATOR . $e)];
                if (count($out) >= 200) {
                    break;
                }
            }
            closedir($dh);
            usort($out, fn($a, $b) => ($b['isDir'] <=> $a['isDir']) ?: strcmp($a['name'], $b['name']));
            return [['path' => $path, 'entries' => $out], []];

        // ---- 缓存状态拉取（对应 bridge.js 的 theme.get / system.locale）----
        case 'theme.get':
            return [TinyState::$theme, []];
        case 'system.locale':
            return [TinyState::$locale, []];
        case 'win.getState':
            return [TinyState::$winstate, []];

        // ---- 窗口控制：必须先发 TITLE/SIZE 帧给 launcher，再 RET ----------
        case 'win.setTitle':
            return [true, ['TITLE ' . str_replace(["\r", "\n"], ' ', (string)($params['title'] ?? 'tinyjs'))]];
        case 'win.setSize':
            return [true, ['SIZE ' . (int)($params['width'] ?? 960) . ' ' . (int)($params['height'] ?? 640)]];
        case 'quit':
            return [true, ['QUIT']];

        // ---- 菜单栏：整块声明帧（MENUBEGIN…MENU/ITEM/SEP/SUB…MENUEND）------
        // 注意：重置只有子窗口的 MENURESET@<win>，没有裸 MENURESET；
        // 要清空 app 菜单就再 menu.set 一次空列表。
        case 'menu.set':
            return [true, menuFrames($params)];

        // ---- 内存 KV（演示请求/响应式状态） -------------------------------
        case 'store.get':
            return [$store[$params['key'] ?? ''] ?? null, []];
        case 'store.set':
            $store[(string)$params['key']] = $params['value'] ?? null;
            return [true, []];
        case 'store.all':
            return [$store, []];

        // ---- 业务 API：主打“证明计算真的发生在 PHP 里” --------------------
        case 'api.version':
            return [['php' => PHP_VERSION, 'backend' => 'tpc-AOT'], []];
        case 'api.sum':
            return [array_sum(array_map('intval', array_values($params))), []];
        case 'api.sha256':
            return [hash('sha256', (string)($params['text'] ?? '')), []];
        case 'api.fib':
            $n = max(0, (int)($params['n'] ?? 30));
            $a = 0; $b = 1;
            for ($i = 0; $i < $n; $i++) { [$a, $b] = [$b, $a + $b]; }
            return [$a, []];
        case 'api.now':
            return [['iso' => date('c'), 'epoch' => time(), 'caller' => $callerWin], []];
    }

    throw new \RuntimeException("unknown method: {$method}");
}

/** 解析一帧，返回要写回 launcher 的文本；无应答返回 null。 */
function handleFrame(string $raw): ?string
{
    $line = rtrim($raw, "\r\n");
    if ($line === '') {
        return null;
    }
    if (!str_starts_with($line, 'CALL ')) {
        return frameForNotification($line);   // 通知帧：转成 EVAL 事件推给页面
    }

    $sp = strpos($line, ' ', 5);
    if ($sp === false) {
        return null;
    }
    $id   = substr($line, 5, $sp - 5);
    $body = substr($line, $sp + 1);
    $callerWin = str_contains($id, ':') ? substr($id, 0, strpos($id, ':')) : 'main';

    $status = 0;
    $result = null;
    $frames = [];
    try {
        $args = json_decode($body, true);
        // 兼容两种形态：真实 launcher 发 JSON 数组 ["<payload>","<origin>"]；
        // headless 冒烟测试可能直接发对象 {"method":...}。
        if (is_array($args) && array_is_list($args)) {
            $payload = $args[0] ?? '{}';
            $msg     = is_string($payload) ? json_decode($payload, true) : $payload;
        } else {
            $msg = $args;
        }
        if (!is_array($msg) || !isset($msg['method'])) {
            throw new \RuntimeException('malformed payload');
        }
        $method = (string)$msg['method'];
        $params = (array)($msg['params'] ?? []);

        // 原生对话框短路：launcher 自己跑 panel 并 resolve 页面 promise，
        // 后端**不发 RET**（同 bridge.js：`if (dlg) { send(...); return; }`）。
        $dlg = dialogFrame($id, $method, $params);
        if ($dlg !== null) {
            return $dlg . "\n";
        }

        [$result, $frames] = dispatch($method, $params, $callerWin);
    } catch (\Throwable $e) {
        $status = 1;
        $result = $e->getMessage();
    }

    $out = '';
    foreach ($frames as $f) {
        $out .= $f . "\n";           // TITLE/SIZE/QUIT 先发给 launcher
    }
    $out .= 'RET ' . $id . ' ' . $status . ' ' . jenc($result) . "\n";
    return $out;
}

function main(): void
{
    // shim 会把首帧原样转发给 launcher；launcher 读循环忽略不认识的帧，无害。
    emit("READY\n");
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
            $buf   = substr($buf, $nl + 1);
            $resp  = handleFrame($frame);
            if ($resp !== null) {
                emit($resp);
            }
        }
    }
    if (trim($buf) !== '') {
        $resp = handleFrame($buf);
        if ($resp !== null) {
            emit($resp);
        }
    }
}
