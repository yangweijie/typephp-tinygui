# launcher-win.cc — TypePHP/aot-compiler 后端桥接补丁

> 目标：让 C++ launcher 成为入口，启动即 spawn 由 aot-compiler 编出的 PHP 后端
> `backend.exe`，并通过 tinyjsapp 既有的命名管道协议完成窗口联调。
> 设计原则：**复用 100% 现有传输层**（`g_pipe` / `pipe_read_loop` / 全部 `tiny.*` handler），
> 仅在 `run()` 前插入一个 spawn 步骤。原 JS 后端路径不受影响（用 `TYPEPHP_BACKEND` 宏门控）。

## 协议方向（已取证，切勿颠倒）
- launcher → 后端：`CALL <id> <json>`（webview JS 的 `tiny.*` 调用转发）、`GOT`/`NOTIFY*`/`DROP`
- 后端 → launcher：`RET <id> <status> <json>`、`EVAL`/`TITLE`/`SIZE`/`RELOAD`/`QUIT`
- 后端是 `tiny.*` 逻辑真正实现方（服务端）；launcher 是原生 API 封装 + webview 宿主。

## ⚠️ 关键修正：PHP 无法作为命名管道服务端 → 必须加一层 shim

> 实测结论（stock PHP 8.5.11 与本机 aot-compiler 0.9.3 的 libphp 均验证）：
> **PHP 不支持 `pipe://` socket 传输**（`stream_socket_server("pipe://...")` 报
> `Unable to find the socket transport "pipe"`）。因此 PHP 后端**不能直接创建**
> launcher 要连接的命名管道。但 PHP 处理 stdio 完全正常。

**修正架构（已 headless 实测打通，见下文「联调验证」）：**

```
launcher-win.exe ──spawn──> backend.exe (C++ shim / backend_shell)
        │                        │ 创建命名管道服务端 (\\.\pipe\tinyjs-typephp-<pid>)
        │  CALL/RET 帧           │ spawn
        │<======================>│
        │                   stdio 代理 (字节透传)
        │                        └──> app.exe (aot-compiler 编出的 PHP 后端, 走 stdio)
```

- launcher 仍然按原协议连接命名管道 —— **launcher 补丁完全不变**。
- 真正被 spawn 的 `backend.exe` 改由 **C++ shim**（`backend_shell.cpp`）充当：
  它创建命名管道服务端，再以继承 stdio 的方式 spawn 真正的 PHP 后端 `app.exe`，
  并双向透传帧（帧以 `\n` 分隔，原始字节透传即安全）。
- 部署形态：`launcher-win.exe` + `backend.exe`(shim) + `app.exe`(PHP/aot)。
  用 `TYPEPHP_BACKEND` 指向 shim；shim 内部用 `TYPEPHP_APP` 指向 `app.exe`。
- 这样既保留 tinyjsapp 原生命名管道传输（与上游一致、对 launcher 零侵入），
  又绕开了 PHP 不支持命名管道服务端的事实。

## Hunk A — 全局变量（紧跟 `static HANDLE g_pipe = INVALID_HANDLE_VALUE;` 之后）

```cpp
static HANDLE g_pipe = INVALID_HANDLE_VALUE;

// --- TypePHP / aot-compiler backend bridge ---
// In TypePHP mode the launcher is the entry point: it spawns the PHP backend
// (compiled by aot-compiler) as a child, hands it the pipe name, then connects
// to that pipe as a client. All tiny.* handling, the read loop and g_pipe are
// unchanged. Gate everything behind TYPEPHP_BACKEND so the JS backend path is
// unaffected.
static bool g_typephp = false;
static PROCESS_INFORMATION g_backend_proc = {};
static std::string spawn_typephp_backend();
static void terminate_typephp_backend();
```

## Hunk B — `run()` 开头：识别 `--typephp` 并左移 argv

把原来的 `if (argc < 3) {...}` 块与 `g_target = argv[1]; std::string pipe_name = argv[2];`
替换为：

```cpp
static int run(int argc, char **argv) {
  // TypePHP mode: drop the flag and shift argv so the rest parses as
  // <html> [title] [WxH] [version]; the pipe name is generated when we spawn
  // the backend below.
  if (argc >= 2 && std::strcmp(argv[1], "--typephp") == 0) {
    g_typephp = true;
    for (int i = 1; i < argc; i++) argv[i] = argv[i + 1];
    argc--;
  }
  if (argc == 4 && strcmp(argv[1], "--embed-icon") == 0)
    return embed_icon(argv[2], argv[3]);
  if (argc >= 3 && strcmp(argv[1], "--run") == 0)
    return run_hidden();
  if (argc >= 4 && strcmp(argv[1], "--open") == 0)
    return open_mode(argc, argv);
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <html-file-or-url> <pipe-name> [title] [WxH] "
                 "[version]\n       %s --typephp <html> [title] [WxH] [version]\n"
                 "       %s --embed-icon <exe> <png>\n",
                 argv[0], argv[0], argv[0]);
    return 1;
  }
  g_target = argv[1];
  std::string pipe_name = g_typephp ? std::string() : argv[2];
```

## Hunk C — 连接循环前：spawn 后端（插在 `// Connect to the backend's named pipe` 注释之前）

```cpp
  // TypePHP: spawn the PHP backend (aot-compiler binary) and let it create the
  // named pipe server under the name we hand it; then connect as a client.
  if (g_typephp) {
    pipe_name = spawn_typephp_backend();
    if (pipe_name.empty()) {
      std::fprintf(stderr, "launcher: failed to spawn TypePHP backend\n");
      return 1;
    }
  }

  // Connect to the backend's named pipe (it listens before spawning us, but
  // retry briefly to be safe).
  for (int i = 0; i < 50; i++) {
```

## Hunk D — 新增函数（放在 `static int run(` 之前）

```cpp
static std::string spawn_typephp_backend() {
  // Pipe name the backend must create as a server before we connect.
  std::string name =
      "\\\\.\\pipe\\tinyjs-typephp-" + std::to_string(GetCurrentProcessId());
  // Backend binary: env TYPEPHP_BACKEND, else "<launcher_dir>/backend.exe".
  wchar_t buf[MAX_PATH];
  std::wstring exe;
  if (GetEnvironmentVariableW(L"TYPEPHP_BACKEND", buf, MAX_PATH)) {
    exe = buf;
  } else {
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring self(buf, n);
    size_t sl = self.find_last_of(L"\\/");
    exe = (sl == std::wstring::npos ? L"" : self.substr(0, sl + 1)) + L"backend.exe";
  }
  std::wstring cmd = L"\"" + exe + L"\" " + widen(name);
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return "";
  }
  CloseHandle(pi.hThread);
  g_backend_proc = pi;
  return name;
}

static void terminate_typephp_backend() {
  if (g_backend_proc.hProcess) {
    TerminateProcess(g_backend_proc.hProcess, 0);
    CloseHandle(g_backend_proc.hProcess);
    g_backend_proc.hProcess = nullptr;
  }
}
```

## Hunk E — 清理（在 `run()` 末尾的 return 之前调用一次）

```cpp
  terminate_typephp_backend();
  return 0;
```

## 构建要点（用户完整仓库内执行）

### 1) launcher-win.cc 补丁
- 补丁（Hunk A–D）已落地到 `D:/git/web/tinyjsapp-0.42.0/native/launcher-win.cc`
  （原文件备份为同目录 `launcher-win.cc.orig.bak`）。
- **注意**：launcher 补丁不是用宏门控，而是用运行时 `--typephp` 参数 + `g_typephp`
  标志（见 Hunk B）；`TYPEPHP_BACKEND` 是**环境变量**，指向要 spawn 的后端可执行文件
  （默认同目录 `backend.exe`）。
- 完整编译依赖 canonical `webview/webview.h`（WebView2 SDK）+ `tiny_client.h`
  （由 `runtime/tiny.js` 经 `setup.ps1`/`gen-client.sh` 生成）。本机实测：MinGW-w64 g++
  13.2.0 可编；但若用 MSVC 需 Windows SDK 的 WRL 头（`windows.data.xml.dom.h` 等），
  缺之会编译失败（与本次补丁无关，是 tinyjsapp 自身构建要求）。

### 2) shim（backend.exe）—— 取代「PHP 直接服务管道」的旧设想
- 源码：`planb/backend_shell.cpp`，编译：`g++ -std=c++17 -O2 -o backend_shell.exe backend_shell.cpp -ladvapi32`
- 它创建命名管道、spawn 真正的 PHP 后端 `app.exe`（env `TYPEPHP_APP` 指向，默认同目录
  `app.exe`），并代理帧。无 WebView2/WRL 依赖，可独立编译。
- **必须是单线程、按行分帧的代理**：双线程双向 pump 实测在命名管道 `WriteFile` 上会
  永久阻塞（6/31 字节小写也卡死）。协议本身是请求/响应（CALL→RET），单线程顺序
  「读 CALL 行→转发 PHP→读 RET 行→回写 launcher」最稳。
- 诊断：launcher 用 `CREATE_NO_WINDOW` spawn shim，shim 无控制台 → 设
  `TYPEPHP_SHELL_LOG=<file>` 写文件日志（另有 `TYPEPHP_PIPE_NAME` 裸名用于本地测试）。

### 3) PHP 后端（app.exe）—— aot-compiler bin 模式
- 源码：`planb/backend.php`（所有业务逻辑在 `dispatch()`；`main()` 为 aot 入口）。
- 编译：`tpc.exe backend.php -o app.exe`（bin 模式；Windows 上 nano 不可用，见调研报告）。
- stock PHP 本地联调用 `php _run_backend.php`（包装一次 `main()` 调用，供调试）。
- **两个必须遵守的协议点**（否则 launcher 收不到应答）：
  1. 应答必须是 `RET <id> <status> <json>`（status 0=ok），见 launcher `do_reply`
     （launcher-win.cc:4601 `status == 0 ? 0 : 1`）；缺 status 会被 `pipe_read_loop` 丢弃。
  2. 每帧写完必须 `fflush(STDOUT)`：stdout 为管道时是块缓冲，不 flush 会 hang。

### 4) 一键构建 + 运行
- 构建两者：`planb\build_all.bat`（`g++` 编 shim + `tpc` 编 app.exe；用 `TPC_HOME` 覆盖
  tpc 位置，避免被 ambient `PHP_HOME` 带偏）。
- 运行：把 `launcher-win.exe`、`backend.exe`(shim)、`app.exe`(PHP) 放同目录，执行：
  `./launcher-win.exe --typephp index.html "My App" 960x640`
- 或设 `TYPEPHP_BACKEND` 指向 shim、`TYPEPHP_APP` 指向 PHP 后端（shim 默认同目录
  `app.exe`）。

## 联调验证（本机 headless 已打通，真实 aot 后端）
- `planb/spawn_bridge_test.cpp`（内含与补丁逐字一致的 `spawn_typephp_backend()`，模拟
  launcher 侧）→ spawn `planb/backend_shell.exe`（单线程 shim）→ spawn `app.exe`
  （**由 tpc v0.9.3 bin 模式真实编出**，非 stock php）。
- 交换：`CALL 1 {"method":"api.sum","params":{"a":3,"b":4}}` → 经 shim → PHP 处理 →
  `RET 1 0 {"ok":true,"result":7}`，终端打印 `[test] PASS: spawn + connect + CALL/RET
  round trip OK`，exit 0。即：**launcher 侧 spawn + 命名管道 + 帧协议 + 真实 aot 后端全链路 OK**。
- **未在本机验证的部分**：真实 WebView2 窗口渲染需要带显示会话 + WebView2 运行时，
  本沙箱为无头环境，需用户在完整桌面环境跑通窗口联调（`launcher-win.exe --typephp ...`）。

---

## 更新（session 4）：launcher 编译成功 + 真实窗口联调 PASS

### 构建 launcher-win.exe（本机 MinGW-Builds 13.2.0）
- 根因订正：3 个 app 级 WinRT 头确实缺，但**更隐蔽的是本机 WinRT 基础头是空壳**
  （`windows.foundation.h` 无 `IUriRuntimeClass`、`windows.storage.h` 无 `IStorageFile`、
  `windows.ui.core.h` 无 `ICoreWindow`）。因此症状是大量 `'ABI::Windows::*' has not been declared`。
- 解法：`native/winrt-shim/` 放 mingw-w64 上游完整头，用 **`-I`**（不是 `-idirafter`）
  置于本机头之前；再补齐传递依赖头（`windows.storage.fileproperties.h`、
  `windows.storage.search.h`、`windows.devices.geolocation.h`、`windows.ui.input.h`、
  `windows.devices.input.h`、`windows.system.h` 等）。报错 41 → 0。
- 命令：见 `planning/task_plan.md` Phase 5 或技能 `tinyjsapp-typephp-bridge`。

### 补丁修正：`--typephp` 的 argv 处理（重要）
原补丁把整个 argv 左移一格，虽然去掉了 `--typephp` 标志，**但同时也吃掉了一个位置参数槽**，
导致 `title = argv[3]`（拿到的是尺寸串），窗口标题变成 "960x640"。已改为只覆盖标志槽：

```cpp
if (argc >= 2 && std::strcmp(argv[1], "--typephp") == 0) {
  g_typephp = true;
  if (argc >= 3) argv[1] = argv[2];   // 不要整串左移！
}
```
（`--typephp` 模式下 `pipe_name` 被强制为空串，故 `argv[2]` 的残留值不会被读。）

### 联调结果（真实 WebView2 窗口，双向通过）
- 页面 → launcher → 命名管道 → shim → **PHP AOT 后端**：`ping`→`"pong"`、
  `sysinfo`→`{"runtime":"PHP 8.5.11",...,"backend":"aot-compiler (tpc) AOT native"}`、
  `api.fib(40)`→`102334155`、`api.sha256`→`a817a2f2…`、`api.sum(1..100)`→`5050`、
  `listDir D:\Temp`→真实目录项；首帧往返 **257 ms**。
- **后端 → launcher**：点“改标题”→ 后端发 `TITLE TypePHP 已接管标题` → 窗口标题真实改变；
  点“放大”→ 发 `SIZE 1200 800` → 窗口 976×679 → 1216×839。
- 证据：`_shim_win.log`（全部帧）、`_launcher.err`（`launcher: CALL …`）、
  `e2e-window-ok.png`（截图）。

### shim 关键修正：非阻塞双向泵
原“读一帧 launcher → 等一条 RET”的请求/响应模型会被 launcher 的**通知帧**
（`WINSTATE` / `NAV` / `SYS`）卡死（后端对通知帧不回 RET），之后所有 `CALL` 都堆在管道里。
已改为双向 `PeekNamedPipe` 非阻塞轮询泵（各方向独立行重组，无线程）。

---

## 更新（session 5）：协议保真与一键构建
- **后端补 `client.hello`**（launcher 启动必发；真实 bridge.js 实现即 `return true`）。原来返回 `unknown method: client.hello`。
- **通知帧不再写 stderr**：shim 设了 `si.hStdError = hWriteStdout`，后端写 stderr 的内容会被当成帧转给 launcher。现按 bridge.js 语义把通知帧转成
  `EVAL@* window.__emit && window.__emit({"event":..,"data":..})`：
  `WINSTATE <win> <json>`→`window-state`、`SYS theme light|dark`→`theme`、`SYSLOCALE`→`locale`；其余静默忽略。
  转义必须与 bridge.js `esc()` 逐字一致（`\`→`\`，tab/CR/LF→`\t`/`\r`/`\n`）。
- **时序坑（重要）**：`WINSTATE`/`SYS theme` 在页面导航前就到达，推送必然丢失 → 与 bridge.js 同构：后端缓存最近值（`TinyState`），页面用 `theme.get`/`system.locale`/`win.getState` 拉取。
- **一键构建**：`planb/build_launcher.sh`（补头 → 编 launcher → 部署 `backend.exe`/`app.exe`）。
- 实测：`client.hello`→`true`、6 条事件（2 推送 + 3 拉取 + …）、0 unknown method、0 stderr 噪声。截图 `planb/e2e-window-events.png`。

---

## 更新（session 6）：launcher 原生应答帧类（DLG + 菜单）
- **`dialog.*` 走 `DLG <id> <op>\t<args>`，launcher 自己应答、后端不发 RET**（bridge.js 在 handleCall 里对 dialog 短路 `send(...); return;`）。实测确认无 RET 也能继续流动 → 非阻塞泵设计正确。
  - op：`open|openmulti|dir|save|alert|confirm|prompt`；文件类第二参数是 `extList`（去点、小写、正则过滤、逗号连接）
  - `alert`=`[msg,detail,ok]`、`confirm`=`[msg,detail,ok,cancel]`、`prompt`=`[msg,default,ok,cancel]`，所有文本过 `one()`（tab/CR/LF→空格）
- **菜单整块多帧**：`MENUBEGIN` → `MENU <title>` → `ITEM <id>\t<label>\t<key>\t<flags>` / `SEP` / `SUB…SUBEND` → `MENUEND`。flags=`c`+`d`。**没有裸 `MENURESET`**（只有 `MENURESET@<win>`）。
- **`MENU <id>`/`TRAY <id>`/`TRAYCLICK` 通知** → 页面事件 `menu`/`tray`/`trayclick`，让 `tiny.menu.on(fn)` 生效。
- **`TINYJS_TEST_AUTODLG=ok`** 让 launcher 自动点掉 modal `#32770` → 原生对话框非交互可测。
- 实测（真实窗口）：菜单栏「文件/帮助」→ 点项 → `MENU open` → `EVAL@* menu {id:'open'}` → 页面 `tiny.dialog.openFile` → `DLG … open\tpng,jpg,md,txt` → 原生文件对话框 → 返回 `null` 到页面。alert/confirm/prompt 全通（`prompt`→`tiny`）。截图 `planb/e2e-dialogs-menu.png`。

---

## 更新（session 7）：接进 `tinyjs dev` CLI（日常可用）
- **`tinyjs dev --typephp`（或 `TINYJS_TYPEPHP=1`）**：`cli.js` 的 `cmdDev()` 新增分支，**不再 spawn txiki 后端**，而是直接 spawn launcher-win.exe：
  ```
  tjs.spawn([launcher, '--typephp', <html>, cfg.title, cfg.size, cfg.version])
  ```
  进程链变成 `tjs(CLI) → launcher-win.exe → backend.exe(shim) → app.exe(PHP)`。
- **跳过 `generateBuild()`**：TypePHP 项目没有 JS 后端入口（`resolveBackendEntry` 会 `fail`），也不需要 `entry.js`/`bridge.js`/esbuild。分支里只用 `typephpTarget(cfg, devUrl)` 解析要加载的文档：
  `devUrl` > `cfg.url` > `tjs.cwd + '/' + (frontend.dir ?? 'src/frontend') + '/index.html'`。
- **配置**（`tinyjs.json`，路径为项目相对）：
  ```json
  { "name": "TypePHP Demo", "size": "1100x760", "version": "0.1.0",
    "typephp": { "backend": "backend/backend.exe", "app": "backend/app.exe" } }
  ```
  省略时走 launcher/shim 的默认值 `<launcher 目录>/backend.exe`、`<shim 目录>/app.exe`。
- **热更新**：
  - `src/**`（排除 `frontend*`）变更 → 重启后端（kill launcher → atexit/管道断开让 shim 回收 PHP → 重新 spawn）。日志 `restarting backend`。
  - `src/frontend/**` 变更 → 同样整窗重载。正常 dev 路径靠 app 进程内的 `tjs.watch` + `app.reload()` 原地热重载；TypePHP 链路里**没有 JS 进程**，CLI 对 launcher 唯一的杠杆就是它的生命周期，所以这里退化为重启窗口（日志 `reloading window`）。devUrl / url 型 app 跳过（文档不归我们管）。
- **新发现的坑：launcher 启动时 `SetCurrentDirectoryW(GetTempPathW())`**（原有设计，注释写明"不能把 cwd 钉在 app 目录，会阻塞自动更新换目录"；`launcher-win.cc:7803-7808`，orig.bak 里也有）。
  后果：shim / PHP 继承到 `getcwd() == D:\Temp`，PHP 后端所有相对路径失效。
  **修复**：CLI 设 `TYPEPHP_CWD = tjs.cwd`，shim 把它作为 `CreateProcessW(..., lpCurrentDirectory)`。语义上与 JS 后端一致（JS 后端由 CLI spawn，cwd 就是项目目录）。
- **实测（真窗口）**：`tinyjs dev --typephp` 于 `demo-app/`
  - 窗口标题 `TypePHP Demo`、原生菜单栏「文件/帮助」、`sysinfo.cwd = D:\git\php\typephp-gui\planb\demo-app`、fib(40)=102334155、目录浏览读到 `backend/ src/ tinyjs.json`（真实 FS，证明 cwd 修复生效）。
  - `touch src/backend.php` → `restarting backend`，launcher/backend/app PID 全换新、仍各 1 个（**无进程泄漏**）。
  - `touch src/frontend/index.html` → `reloading window`，同上。
  - 关窗（WM_CLOSE）→ launcher 退出 → `shim: launcher closed` → shim `done` → CLI 退出；`tasklist` 无残留。
  - 截图 `planb/e2e-dev-cli.png`、`planb/e2e-dev-cli-reload.png`。
- **待办**：`tinyjs build` 对 TypePHP 尚未支持（`generateBuild` 仍要求 JS 后端入口），发布链需要类似的分支（产出 launcher + shim + PHP exe 的组合包）。
- **分发坑（重要）：`app.exe` 并非自包含**。tpc `bin` 产物是 174KB exe，但动态依赖
  `php8ts.dll`(13.5MB) / `phpx.dll` / `libmpdec{,++}-4.0.1.dll` / `gmp-10.dll` / `mpfr-6.dll`
  = **15.5MB**（tpc v0.9.3），外加 MSVC 运行时（`MSVCP140`/`VCRUNTIME140*`）。
  本机之所以"看起来能跑"，是因为 PATH 上有 tpc（而且还是 **v0.9.0**，版本不匹配）。
  修法：把这 6 个 DLL 拷到 `app.exe` 同目录（Windows 对非 KnownDLL 优先查 exe 所在目录），
  已固化进 `demo-app/build.bat` 步骤 [3/4]；闭包用 `objdump -p` 递归解析（`scripts/deps-dlls.py`）。
  已实测：剥离 PATH 里的 tpc 后 `tinyjs dev --typephp` 依旧全链路 PASS（截图 `e2e-dev-cli-cleanpath.png`）。
- **demo 项目自包含**：`planb/demo-app/build.bat` 一条命令重建 shim + PHP exe + DLL + 校验 launcher。
