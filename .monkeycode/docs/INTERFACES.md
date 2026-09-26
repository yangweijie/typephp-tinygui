# 接口文档

本项目同时暴露：**行分隔帧协议**（launcher ↔ 后端）、**PHP `tiny.*` 方法**（页面 `tiny.api.call`）、**tgui CLI**、以及 **Composer 脚本**。认证：无网络鉴权；页面与后端同机，fs API 仅沙箱路径。

## 帧协议（stdout / stdin）

帧 = 一行，`\n` 分隔。编解码：`Tiny\Gui\Protocol`。泵：`Tiny\Gui\Backend`。

### launcher → backend

| 帧 | 后端行为 |
|---|---|
| `CALL <id> <json>` | json 为 `["<payload>","<origin>"]` 或裸对象。payload 含 `method`、`params`。成功/失败均应 `RET`（能解析出 id 时）。畸形 payload → `RET <id> 1 "invalid CALL payload"` |
| `WINSTATE <win> <json>` | 缓存 `State::winState`，向页面 `EVAL@*` 推 `window-state` |
| `SYS theme light\|dark` | 缓存 theme，推 `theme` |
| `SYS <kind>` | 推名为 kind 的空事件 |
| `SYSLOCALE <json>` | 缓存 locale，推 `locale` |
| `MENU <id>` / `TRAY <id>` / `TRAYCLICK` | 推对应事件 |
| 空行、无 id 的残缺 CALL、NAV/DROP/… | `ignore`，不写 stdout |

后端启动先写 `READY\n`（`Backend::run`）。

### backend → launcher

| 帧 | 含义 |
|---|---|
| `RET <id> <status> <json>` | status `0` 成功，非 0 失败；json 由 `Protocol::jenc`（`JSON_THROW_ON_ERROR`）。编码失败改为 status 1 的错误字符串 |
| `TITLE <text>` / `SIZE <w> <h>` / `QUIT` | 必须出现在对应 CALL 的 `RET` **之前**（`Response::$frames`） |
| `EVAL@* <esc(js)>` / `EVAL@<win> <esc(js)>` | 推事件：`window.__emit({event,data})` |
| `DLG <id> <op>\t<args>` | 原生对话框；**不发 RET**（launcher 自己完成） |
| `MENUBEGIN` … `MENUEND` | 菜单块，然后 RET |

`Protocol::esc`：`\`、tab、CR、LF 转义。`Protocol::one`：空白压成空格。

## PHP 方法（页面 `tiny.api.call`）

### 空应用 `Gui::defaultDispatcher` / `serve()`

| method | handler | 结果 |
|---|---|---|
| `ping` | Core | `"pong"` |
| `client.hello` | Core | `true` |
| `log` | Core | 写 STDERR，`true` |
| `sysinfo` | Core | runtime/host/cpu/pid/cwd/root/home/os/backend |
| `listDir` / `fs.list` | Core | `{path, entries[{name,isDir}]}`，最多 200；路径须在 AppRoot 内 |
| `theme.get` / `system.locale` / `win.getState` | Core | `State` 缓存，可能为 null |
| `app.root` | Core | 沙箱根字符串 |
| `fs.readText` | Core | 文件文本 |
| `fs.writeText` | Core | 写文本；父目录须已在沙箱内 |
| `fs.exists` | Core | bool（库外或缺失为 false） |
| `fs.stat` | Core | path/isDir/isFile/size/mtime |
| `win.setTitle` | Win | `TITLE` + `true` |
| `win.setSize` | Win | `SIZE w h` + `true` |
| `quit` | Win | `QUIT` + `true` |
| `menu.set` | Menu | 菜单块 + `true` |
| `store.get` / `store.set` / `store.all` | Store | 进程内 KV；`set` 缺/空 key → 错误 RET |
| `dialog.openFile` 等 | Protocol::dialogFrame | 仅 `DLG`，无 RET |

未知 method：`RuntimeException` → `RET` status 1 `unknown method: …`。

### 演示 `Gui::demoDispatcher` / `serveDemo()`（`src/backend.php`）

另注册 `DemoApiHandler`：`api.version`、`api.sum`、`api.sha256`、`api.fib`、`api.now`、`api.echo`。

扩展：`$d->on('x', fn)`、`$d->onPrefix('app.', fn)`、`HandlerInterface`。

## 沙箱

- 根：环境变量 `TYPEPHP_APP_ROOT`，否则 `getcwd()`（`AppRoot::fromEnv`）。
- `resolve`：`realpath` 后必须等于根或位于其下（Windows 大小写不敏感）。
- 相对路径相对沙箱根，不是任意 cwd（与旧版 `listDir` 默认 `getcwd()` 不同）。

## CLI：`gui/bin/tgui`

根 README 记载的用法（以该文件为准）：

| 命令 | 作用 |
|---|---|
| `tgui init` | `tinyjs.json` + `src/frontend/index.html` |
| `tgui dev` | 设 `TYPEPHP_BACKEND` / `TYPEPHP_APP` / `TYPEPHP_CWD` / `TINYJS_ICON`，拉 `launcher --typephp …` |
| `tgui build` | `demo/dist/`：入口 exe=shim、`php.exe`=后端、launcher、DLL、frontend、conf |
| `tgui publish` | zip（失败则 tar.gz） |
| `tgui status` | 状态（以 `gui/bin/tgui` 实现为准） |

## Composer 脚本

| 脚本 | 命令 |
|---|---|
| `test` / `smoke` | `php gui/php/test/smoke.php` |
| `verify` | `python tools/verify-bundle.py` |

POSIX 套件：`test/posix/all.sh`（bash，未挂到 composer）。

## 环境变量（构建/运行）

| 变量 | 必需 | 描述 |
|---|---|---|
| `TPC_HOME` | 编 AOT 时 | tpc 发行包目录 |
| `VCVARS` | Windows 编后端 | vcvars64.bat |
| `TYPEPHP_APP_ROOT` | 否 | fs/listDir 沙箱根 |
| `TYPEPHP_BACKEND` | 否 | 覆盖 shim 路径 |
| `TYPEPHP_APP` | 否 | 覆盖 PHP 后端 |
| `TYPEPHP_CWD` | tgui 会设 | 工作目录 |
| `TINYGUI_LAUNCHER` | 否 | 覆盖 launcher |
| `TYPEPHP_SHELL_LOG` | 否 | shim 日志文件 |
| `TINYJS_ICON` | tgui 会设 | 图标 |

不要把密钥写进文档或仓库。
