# Findings — launcher-win.cc 集成调研

## 环境扫描（2026-09-25）
- 规划文件此前不存在，已新建 task_plan.md / findings.md / progress.md。
- tinyjsapp 未克隆到本地任何路径。
- 真实 `launcher-win.cc` 已抓取：`/D/Temp/tj_native_launcher-win.cc`（306KB，来自 github tarwin/tinyjsapp main 分支，经 xget 代理）。
- 本机 `webview.h` 来源：仅 `HelgeSverre-libui-sdk`、`mysql-scheme-sync`、`phptool2`（pebview fork）、`wails@v1.16.9` 的 fork。**没有 tinyjsapp 依赖的 canonical `webview/webview.h`**。
- aot-compiler 发行包：`D:/git/php/tpc_v0.9.3_windows_x64`（含 php.exe/phpx/tpc 源码可跑）。

## tinyjsapp 架构（来自之前 WebFetch + 源码取证）
- launcher（C++）实现 100% `tiny.*` 原生 API（窗口/菜单/托盘/对话框/音频/钥匙串/TouchID/OCR/录屏/通知），MIT 许可。
- JS 后端只应答换行分隔协议：`CALL <id> <json>` / `RET <id> <json>` / `GOT <id> <json>` / `DLG ...`；传输层为 unix socket（mac/linux）/ named pipe（Windows）。
- 之前 `planb/launcher_bridge.cpp` 是参考实现（独立说明 stdio 桥接思路），并非直接对 306KB launcher 的补丁。

## 关键发现：真实协议方向与架构（已取证 launcher-win.cc）
- **后端(txiki.js / 我们的 PHP)是服务端，launcher 是客户端**。launcher 在 `run()` 中 `g_pipe = CreateFileW(pipe_name)`（7769）连接后端创建的命名管道；`std::thread(pipe_read_loop).detach()`（7959）启动帧读取。
- **协议方向**（阅读 `pipe_read_loop` 6905 与写点 4680/7582）：
  - launcher → 后端：`CALL <id> <json>`（webview JS 的 `tiny.*` 调用被转发）、`GOT <qid> <json>`（异步事件结果）、`NOTIFYCLICK`/`NOTIFYACTION`/`DROP` 等。
  - 后端 → launcher：`RET <id> <status> <json>`（对 CALL 的回复，由 `do_reply` 解析 JS promise）、`EVAL`/`TITLE`/`SIZE`/`RELOAD`/`QUIT` 等控制指令（应用到 webview）。
- **结论**：后端才是 `tiny.*` 逻辑真正实现方（服务端）；launcher 只是原生 API 封装 + webview 宿主 + 协议转发。
- **因此最小风险集成**：launcher 启动时先 spawn `backend.exe <管道名>`（后端以该名建管道服务端），再以客户端连接——`g_pipe`/`pipe_read_loop`/所有 handler **原样复用**，只需加一个 spawn 步骤。这比此前 `launcher_bridge.cpp` 假设的"launcher 当父进程走 stdio"更贴合真实仓库且侵入最小。
- **环境限制**：tinyjsapp 完整仓库 clone 被 xget 429 限流（多次失败）；本机无 canonical `webview/webview.h`、无 `tiny_client.h`、无构建系统 → 无法在此完整编译 launcher。可验证项：① 独立编译 launcher 新增的 spawn 逻辑（MSVC，无需 webview）；② 用 aot-compiler 构建 PHP 后端（bin 模式）并跑通 `pipe://` 命名管道协议（以 PHP 客户端模拟 launcher）。

## 待确认 / 风险
- ~~aot-compiler bin 模式 PHP 是否支持 `stream_socket_server("pipe://...")` 命名管道~~
  **已实测否定**：PHP 8.5.11 与 aot-compiler 0.9.3 的 libphp 均不支持 `pipe://`
  socket 传输（报 `Unable to find the socket transport "pipe"`）。因此 **PHP 后端不能
  直接作为命名管道服务端**。→ 采用 **C++ shim** 架构：launcher spawn `backend.exe`(shim)，
  shim 建命名管道 + 以继承 stdio spawn `app.exe`(PHP/aot)，双向字节透传帧。launcher 补丁
  完全不变；shim 源码 `planb/backend_shell.cpp`，已 headless 联调打通。
- 真实窗口渲染需 WebView2 运行时 + 有显示会话；本机 headless → 已用 spawn+协议握手+
  `window.create` CALL/RET 往返冒烟证明链路 OK，**真实窗口渲染交用户在完整环境验证**。
- 完整编译 launcher 需 Windows SDK WRL 头（`<windows.data.xml.dom.h>` 等）；MinGW g++ 13.2.0
  可编译但缺该头会失败——此为 tinyjsapp 自身构建要求，与本次补丁无关。

## 真实 aot 后端联调发现（session 3）
- **协议帧格式（已取证 launcher-win.cc）**：launcher 的 `do_reply`（~4601）解析
  `RET <id> <status> <json>`，`status == 0` 视为成功。后端必须输出 3 段；只写
  `RET <id> <json>` 会被 `pipe_read_loop`（~6965）直接丢弃（`sp2==npos → continue`）。
- **stdout 必须逐帧 flush**：PHP（含 aot bin 模式）stdout 为管道时是块缓冲（4KB），
  不加 `fflush(STDOUT)` 则小帧不实时送达 → 对端读阻塞（表现为 hang）。
- **命名管道代理用单线程**：双线程双向 pump 在 Win32 命名管道 `WriteFile` 上会永久阻塞
  （实测 6/31 字节小写卡死，对端读到 EOF/`ERROR_BROKEN_PIPE`）。改为单线程按行分帧
  （request→forward→read RET→reply）后稳定。协议本身是请求/响应，天然适合单线程。
- **后端启动 banner**：PHP 后端启动即输出 `READY\n`；launcher 的 read loop 会忽略未知帧，
  故无害；测试端也需同样忽略（不能一见非 RET 就断）。
- **spawn 上下文**：launcher 用 `CREATE_NO_WINDOW` + `bInheritHandles=FALSE` spawn 后端，
  故 shim 无控制台、stdout 无效 → 诊断走文件日志（`TYPEPHP_SHELL_LOG`）。
## launcher-win.exe 构建位置与阻塞点（session 4）
- **预期输出路径**：`D:/git/web/tinyjsapp-0.42.0/native/launcher-win.exe`（与源码同目录；
  `cli.js` 构建时拷成 `<app>/dist/launcher.exe`，即 `TOOL_DIR + 'native/launcher-win.exe'`）。
  目前**尚未生成**（本机未成功编译）。
- **构建方式**：仓库内 `powershell -ExecutionPolicy Bypass -File setup.ps1` —— 自动 winget 装
  WinLibs MinGW、下载 WebView2 SDK 头、由 `runtime/tiny.js` 生成 `native/tiny_client.h`，再用
  `g++ -std=c++17 -O2 -static -Inative/include -Inative -o native/launcher-win.exe
  native/launcher-win.cc -mwindows -lole32 ...` 编译。
- **本机阻塞点**：launcher-win.cc 无条件 `#include <windows.data.xml.dom.h>` /
  `<windows.ui.notifications.h>` / `<windows.security.credentials.ui.h>`（WinRT/WRL，用于
  toast + Windows Hello）。本机 MinGW-Builds 13.2.0 只有**部分** WinRT 头
  （`windows.foundation.h`/`windows.ui.core.h`/`windows.security.credentials.h` 有，上述三个**缺**）→
  编译报 `No such file or directory`。用 MSVC SDK 的同名头（`D:/Windows Kits/10/Include/10.0.19041.0/winrt`，
  本机 SDK 在 **D 盘**）喂 g++ 不兼容：SDK 头含 `_uuidof`/MIDL 扩展 → 大量报错。
  → 需 WinLibs 版 MinGW（或包含这 3 头的 mingw-w64）。
- **WebView2 头已备**：`native/include/WebView2.h`（从 nuget v3 解出）+ `native/tiny_client.h`（本地生成）。

- **shell 反斜杠陷阱**：Git Bash 会吞掉 argv 与环境变量值里的反斜杠
  （`\\.\pipe\x` → `\.\pipe\x`），导致 `CreateNamedPipeW` 报 123。真实链路（launcher 内部
  生成管道名）不受影响；手工测试改用裸名 env（`TYPEPHP_PIPE_NAME`）由 shim 补前缀。

## Phase 13-15 关键发现（session 7-8）

### launcher 会改工作目录（新坑）
`launcher-win.cc` 启动时执行 `SetCurrentDirectoryW(GetTempPathW())`（约 7803-7808，
`orig.bak:7743` 亦有），注释说明是**故意**的：不能把 cwd 钉在 app 目录，否则目录句柄
会阻塞自动更新换目录。后果：它 spawn 的 shim/PHP 继承到 `getcwd()==%TEMP%`，
PHP 后端所有相对路径失效。→ CLI 注入 `TYPEPHP_CWD`，shim 用作 `CreateProcessW` 的
`lpCurrentDirectory`。（JS 后端没这问题，因为它是被 CLI 直接 spawn 的。）

### tpc `bin` 产物不是自包含二进制
`app.exe`(174KB) 动态依赖 `php8ts.dll`(13.5MB)/`phpx.dll`/`libmpdec{,++}-4.0.1.dll`/
`gmp-10.dll`/`mpfr-6.dll` ＝ 15.5MB + MSVC 运行时。必须把这 6 个 DLL 放到 exe 同目录
（Windows 对非 KnownDLL 优先搜索 exe 所在目录），否则会静默加载 PATH 上任意版本的
`php8ts.dll`（本机就踩了 v0.9.0 vs v0.9.3）。闭包用递归 `objdump -p` 解析。

### nano（Windows）实测：能编译但严格更差
见 `aot-compiler-nano-fix.md` 复测表。要点：
- `NanoBuildBackend::forHost()` 硬编码 `Windows → WINDOWS_DLL` → 链接指令与 bin **逐字相同**，
  依赖完全相同，体积仅差 1.5%。
- nano 产物 teardown **必 SIGSEGV(139)**，5 行程序即复现 → nano-policy 路径固有缺陷。
- `NativeSourceProjectBuilder.php:28-31` 编译器自己就抛
  "php-nano does not target Windows; use TypePHP --nano with the full PHP/PHPX DLL runtime"。

### 两个禁用清单（写 nano 后端前必读）
`CompilerBase` 在**编译期**对禁用函数 `fatalError`，但有两个清单：
- `NANO_POLICY_UNSUPPORTED_FUNCTIONS`（exec/popen/proc_*/shell_exec/system）→ **Windows** `--nano`
- `NANO_UNSUPPORTED_FUNCTIONS`（多出 `getenv`/`putenv`/`gethostname`/`gethostby*`/`dns_*`/
  `fsockopen`/`stream_socket_*`/`stream_select`/`parse_str`/`header`/…）→ 仅 `isNanoMode()`
  （真正 nano，POSIX/WASI）。源码注释："Windows Nano uses the complete PHP/PHPX DLL set.
  Only the common policy above applies; php-nano's smaller host surface is Unix/WASI."
- 所以：Windows nano 能编过的代码，真 nano 可能编不过。`planb/backend.php:262,266`
  （`sysinfo` 里的 `gethostname()`/`getenv()`）就是这样的两行。

### 结论：shim 不能省（否掉"POSIX 免 shim"假设）
`vendor/swoole/php-nano/SUPPORTED.md`：
- "PHP Nano exposes local filesystem access through its **file-only** PHP stream layer …
  It does not expose network, process, shell, socket, remote-stream, or dynamic-loader APIs.
  **Socket capability remains absent even on POSIX hosts.**"
- "**Windows deliberately uses the complete PHP/PHPX DLL runtime instead of php-nano.**"
- 支持目标："host-native Linux; `wasm32-wasip2`"；Native 契约可覆盖 macOS/Android NDK/Apple SDK。
`REMOVED.md`：移除 "socket transports, remote and user-defined stream wrappers, sockets, DNS,
processes, shell execution, signals, or dynamic library loading"。

→ 任何平台、任何模式下，PHP 都无法服务 launcher 的连接（Windows 缺 `pipe://` transport；
nano 无 socket API；POSIX bin 能服务 socket 但链接 libphp 已不小巧）。**shim 跨平台必需**，
Linux 的收益只是"shim + 真 freestanding nano（无 libphp）"的体积。

### POSIX 侧的事实（供 Phase 16 用）
- tinyjsapp 非 Windows 传输 = `AF_UNIX`：`native/launcher-linux.cc:6981,7071`；
  `runtime/bridge.js` → `tjs.listen('pipe', sockPath)`。
- POSIX shim 的移植量很小：把 `CreateNamedPipeW`/`ConnectNamedPipe`/`PeekNamedPipe` 换成
  `socket(AF_UNIX)`/`bind`/`listen`/`accept` + `select`/`recv` 轮询即可，泵逻辑不变。
- 真 nano 下 `backend.php` 需去掉 `getenv`/`gethostname`（仅 `sysinfo`，2 行）。

## Phase 18 发现（session 9）：打包版不需要 launcher 补丁
- **方向反转的价值**：`--typephp` 让 launcher 当父进程（dev 需要，因为 CLI 得有东西可 spawn）。
  但**打包版**可以走回上游**原生方向**：入口自己建命名管道 → spawn **原版** launcher
  `<html> <pipe> <title> <WxH> <ver>`。于是分发的 `launcher.exe` 是未修改的上游二进制。
- 实现：shim 加 `--launch` 模式（`argc==1` 默认启用；dev 路径总会传管道名，故不冲突）。
  **同一个二进制**兼任 dev 的 shim 和打包版的入口 → 双向帧泵只有一份实现，无重复维护。
- 坑：spawn launcher 必须 `bInheritHandles=FALSE`，否则 launcher 持有 shim 的
  child-stdio 管道端 → PHP 永远读不到 EOF。
- 配置用**行式 key=value**（`<exe_dir>/<exe_stem>.conf`）而非 JSON：C++ 侧零解析依赖。
  键：`html/title/size/version/icon/app/launcher`；相对路径按 exe 目录解析。
- 退出时也要 `TerminateProcess` launcher —— 若 PHP 先死，否则会留一个空窗口。
- 分发目录 ≈18MB：`<name>.exe`(shim) + `launcher.exe`(1.87MB) + `app.exe`(174KB)
  + 6 个 PHP DLL(15.5MB) + `frontend/` + `<name>.conf`。**体积瓶颈就是那 6 个 DLL**，
  与 nano 无关（见 session 8）。
- 两条路径必须都回归：`tinyjs dev --typephp`（argv>1，走 dev）与 `dist/<name>.exe`（argv=1，走 launch）。

## Phase 16/17 准备发现（session 10）

### 禁用清单的精确内容（读编译器源码得来，写 nano 后端前必读）
`aot-compiler/src/CompilerBase.php`：
- `NANO_UNSUPPORTED_FUNCTIONS`（:256-308）—— **只在 `isNanoMode()` 时生效**（真 nano，POSIX/WASI）：
  `dl, exec, passthru, popen, proc_*, shell_exec, system, getenv, putenv, set_time_limit,`
  `parse_str, fsockopen, pfsockopen, stream_select, stream_get_*filters/transports,`
  `stream_filter_register, stream_bucket_*, stream_socket_*, gethostby*, gethostname,`
  `dns_*, header*, http_response_code, mail, openlog, closelog, syslog`
- `NANO_POLICY_UNSUPPORTED_FUNCTIONS`（:311-323）—— **Windows `--nano` 也套用**：只有 exec 家族
  （`exec/passthru/pcntl_exec/popen/proc_*/shell_exec/system`）
- 前缀黑名单：policy 只有 `proc_`；真 nano 另有 **`pcntl_` / `posix_` / `socket_` / `ftp_` / `opcache_`**
- **`php_uname` 两份清单都不在、也不匹配任何前缀** → 是 `gethostname` 的合规替代（`php_uname('m')` 本来就在用）
- 判定在 `CompilerBase::assertNanoFunctionSupported()`（:929-959），是 **AST 级**检查，且开头有
  `if (!$this->isNanoPolicyMode()) return;` 与 `if (!$this->isNanoMode()) return;` 两级早退
  —— 这解释了"Windows 编得过、真 nano 编不过"。注释里出现同名文字不会触发。
- 附带证据：`socket_` 前缀被禁 ⇒ 真 nano 中 `socket_create/connect/...` 根本不存在。这是
  "nano 无 socket 能力"的**第二条独立证据**（第一条是 `swoole/php-nano` 的 SUPPORTED.md）。

### 本机没有可用的 POSIX 编译器（Phase 16 的硬限制）
- MinGW g++ 13.2.0（`/c/ProgramData/mingw64`）**没有 `fork`/`execv`**，也无 `sys/un.h`
- MSYS2（`/d/msys64`）只装了 mingw64 / ucrt64 / clang64 工具链；**`usr/bin` 里没有 g++**，
  `usr/include/sys/un.h` 也不存在 → 拿不到"msys/POSIX"那套 gcc
- Docker Desktop 只剩安装日志与 `AppData/Local/Docker/{backend,frontend,launcher}.lock`，**没有 `docker` CLI**
- WSL 只有一个 `docker-desktop` 工具发行版且处于 Stopped（无 g++）
→ **POSIX 分支无法本地编译**。本地能保证的上限是"Windows 侧零回归 + POSIX 分支靠人工审阅"，
  真正的编译/运行验证必须在远端一次做完。

### 跨平台 shim 的设计决策（`planb/backend_shell.cpp`）
- 抽象边界选在 **`io_t`（HANDLE / fd）+ 一组原语**（`io_open_endpoint`/`io_accept`/`io_read_avail`/
  `io_write_all`/`io_cleanup_endpoint`/`spawn_proc`/`kill_proc`），而不是 `#ifdef` 整个函数体 ——
  帧泵、行重组、conf 解析、路径处理全部**零分支共享**。
- `io_read_avail` 的 POSIX 版**不必区分 socket 与 pipe**：`poll(fd,0)` 报可读 → `read()` 保证不阻塞；
  `read()==0` 即 EOF；`EAGAIN/EINTR` → 当作"暂无数据"。避开了 "socket 用 `recv(MSG_PEEK)`、
  pipe 用 `ioctl(FIONREAD)`" 的分裂写法。
- **Windows 与 POSIX 的句柄继承语义正好相反**：Windows 要显式
  `SetHandleInformation(HANDLE_FLAG_INHERIT)`；POSIX 要**默认 `FD_CLOEXEC`、由 `dup2` 自动清掉**目标
  fd 的标志。两侧都容易写错，且错了在 Windows 上表现为"PHP 立刻 EOF"、在 POSIX 上表现为"子进程
  继承了不该继承的 fd，对端永远等不到 EOF"。
- **`spawn_proc(exe, args, IO_BAD, IO_BAD, cwd)` 表示"不接 stdio"** → Windows 走
  `bInheritHandles=FALSE + CREATE_NO_WINDOW`，POSIX 靠 CLOEXEC 天然达成同一效果。一个函数覆盖
  "带 stdio spawn PHP" 与 "不带 stdio spawn launcher" 两种需求，无需两份实现。
- 退出时要 `if (ep != srv) io_close(srv);`：Windows 上 `ConnectNamedPipe` 后是**同一个** handle，
  POSIX 上 `accept` 返回的是**新 fd**。
- socket 路径对齐 `runtime/bridge.js`：POSIX 是**文件系统路径**（`<workDir>/app.sock`），
  所以 bind 前要 `unlink` 陈旧文件（崩溃实例留下的会挡住 listen），退出再 unlink。
  `sun_path` 约 108B，路径过长回退 `/tmp/tinyjs-typephp-<pid>.sock`。

### e2e 抓到的真 bug（详见 task_plan 关键 bug #8）
跨平台重构时把**子进程 stdin 的管道方向写反了**。现象学值得记：`L->P` 方向**完全没有输出**
（父进程拿的是读端，`WriteFile` 直接失败），而 `P->L` 方向照常发出 `READY` —— **只看到 `READY`
很容易误判"链路是通的"**。完整症状链：`launcher connected` → `P->L: READY` → `backend closed`
→ 窗口根本不出现。编译器 `-Wall` 零警告。

### Phase 17 复核结果
- 取值不变：`host` 由 `gethostname()`=`DESKTOP-KO73F8K` 改为 `php_uname('n')`=**同值**；
  `home` 由 `getenv('USERPROFILE')` 改为 `$_SERVER['USERPROFILE']`=**同值** `C:\Users\Administrator`。
- 复审计正则（可复用）：
  `grep -nE "\b(dl|exec|passthru|popen|proc_[a-z_]*|shell_exec|system|getenv|putenv|set_time_limit|`
  `parse_str|fsockopen|pfsockopen|stream_[a-z_]*|gethostby[a-z]*|gethostname|dns_[a-z_]*|header[a-z_]*|`
  `http_response_code|mail|openlog|closelog|syslog|pcntl_[a-z_]*|posix_[a-z_]*|socket_[a-z_]*|ftp_[a-z_]*|`
  `opcache_[a-z_]*)\s*\(" backend.php` → **0 命中**。
  注意：注释里若写成 `getenv()`（带括号）会被这个正则误报，注释里请写 `getenv` 不带括号。

## Phase 16b：阻塞 + 把验证做成"一条命令"（session 11）

### ⛔ 阻塞：`radeon-cloud` ssh 别名未配置
`rc doctor -y` 的结果：
```
[FAIL] ssh alias 'radeon-cloud' defined: no Host block for 'radeon-cloud' resolves
       (checked with `ssh -G radeon-cloud`)
```
本机**没有配置该别名** → 远端 Ubuntu 盒子不可达 → **Phase 16b（Linux 实测）无法执行**。
这是**用户侧前置条件**：需要从 AMD Radeon Cloud 控制台拿 HostName / User / Port 写进 ssh config
（`radeon-cloud` 技能里有官方指引）。不猜测、不代填 —— 那是凭据配置，不是我能推出来的东西。

同时确认"在本机想办法搞到 POSIX 编译器"这条路全部堵死（见 session 10）：
MinGW 无 `fork/execv`；MSYS2 只装了 mingw/ucrt/clang 工具链（无 msys g++、无 `sys/un.h`）；
Docker Desktop 只有安装日志、无 `docker` CLI；WSL 只有一个 stopped 的 `docker-desktop` 工具发行版。
另外实测 **Windows 版 Python 没有 `socket.AF_UNIX`**，所以连"用 Python 模拟 AF_UNIX 端点来跑 C++ shim"
都做不到。

### 交付：`planb/posix-test/`（把 Phase 16b 压缩成一条命令）
别名一配好即可 `run.sh`，不需要 GTK/webkit、不需要显示、不需要 PHP AOT 工具链 —— 隔离出的正是
唯一的真实风险：**AF_UNIX 端点 + poll/read 泵**。

验证 5 件事：
1. POSIX 分支 **能用 `-Wall -Wextra` 编译**（Windows 完全无法检查的那一半）；
2. `socket(AF_UNIX)+bind+listen` 真的产出监听 socket，且 shim 在日志里自报 `transport=unix-socket`；
3. **泵无耦合**：mock launcher 把 `WINSTATE`/`SYS`（后端永不回 `RET`）与 `CALL` **交错**发送 ——
   请求/响应耦合的代理会在这里死等；这正是 Windows 侧换轮询泵之前的那个死锁；
4. 帧序：后端 `EVAL@*` 窗口帧先于同一 CALL 的 `RET`；启动 `READY` banner 能穿过泵；
5. 收尾：客户端关闭后 shim 自己发现、退出码 0、日志有 `launcher closed`、并 **unlink socket 文件**
   （残留的 socket 会挡住下次 `bind()`）。

分四档渐进：① mock 后端（默认，零依赖）② 真 PHP 客户端 ③ AOT `--nano` 二进制 + 量体积
④ 真 `launcher-linux`（需 libgtk-3-dev + libwebkit2gtk-4.1-dev + xvfb-run）。
**第 ③ 档才是回答"小巧路线"的那一次测量** —— Windows 的 `--nano` 只是策略包装（导入完全相同、
只小 1.5%、且 teardown 必 SIGSEGV），只有在 Linux 上 freestanding 运行时才可能真正省掉 libphp。

### fixture 自测抓到的真问题（值得单独记）
- **Windows 版 Python 没有 `socket.AF_UNIX`** → 本机无法模拟 AF_UNIX 端点。
- 但可以用"**假 socket + 真 `mock_launcher`**"验证 fixture 的协议一致性：monkeypatch
  `socket.socket` 成一个走 `mock_backend.py` stdio 的对象，再 `runpy` 执行真的 `mock_launcher.py`
  → oracle 的解析/断言逻辑被真实执行，且不需要 AF_UNIX。全平台可跑。
- 这个自测**立刻抓到一个真 bug**：`mock_backend` 用 text-mode `sys.stdout` 写帧，Windows 上 `\n`
  被翻译成 `\r\n` → `mock_launcher` 拿到 `'READY\r'`，判 FAIL、退出 1。**修法**：改用
  `sys.stdout.buffer` 写原始字节，帧流变成平台无关（真实 AOT 后端也是写裸 `\n`）。
  假 socket 里同时补上 shim 的 CRLF→LF 归一化（shim 的泵会 pop 掉行尾 `\r`），这样 oracle 保持严格
  而不管后端用哪种换行模式。
- 附带修掉一个自测自身的 hang：oracle 早退时不会 `close()`，后端就永远阻塞在 `readline()`，
  → 解释器退出时挂住（实测 `timeout 60` 触发、退出 124）。修法：无论成败都显式收尾子进程
  （关 stdin → `wait(3s)` → `kill`）。
- **教训：测试自身的 oracle 也要被测。** 否则远端跑挂一次，既浪费一轮往返、又把人往错误方向带
  （会去怀疑 shim 而不是 fixture）。

### `run.sh` 必须拒绝非 POSIX 主机
Windows 上 shim 会走 `_WIN32` 分支**编译成功**，然后服务的是**命名管道**，于是所有 AF_UNIX 断言
都会以错误的理由失败。已在脚本开头用 `case "$(uname -s)"` 拦掉，打印正确的 `rc push`/`rc exec`
命令并以 `2` 退出（实测 MINGW64 下确实干净拒绝）。

## Phase 19 发现（session 12）：`tinyjs publish --typephp` 里两个"构建机错觉"

### PE 子系统：为什么 shell 里测不出这个 bug
`objdump -p` 对比（同一台机器编出的两个 exe）：

| 文件 | Subsystem |
|---|---|
| `dist/<name>.exe`（入口 = g++ 编的 shim） | `00000003 (Windows CUI)` |
| `dist/launcher.exe`（上游 launcher，`-mwindows`） | `00000002 (Windows GUI)` |

- MinGW g++ 的**默认**是 CUI：不写 `-mwindows` 就是 console 子系统。于是双击会挂一个黑框窗口
  全程不消失；而**从 shell / 从 `tinyjs dev` 启动时完全看不到**（父进程已有控制台，或者根本没窗口）。
  → 这条只有"检查产物字节"或"真去双击"才抓得到，跑多少遍 e2e 都看不见。
- 修法只动一个字段：PE 里 `OptionalHeader.Subsystem` 是 `uint16`，偏移 `peOff + 24 + 68`
  （`peOff` = DOS 头 `0x3C` 处的 PE 签名偏移；24 = 标准字段 + 签名，68 = Subsystem 在 optional
  header 内的位置）。3→2 即可，文件大小、校验和、节表全不动。
- 上游 `cli.js` 对自己的 Windows 入口也做这件事（~1185-1197）→ 这是**这门手艺的既有做法**，不是 hack。
- **顺序敏感**：`--embed-icon` 实现是**重写整个 PE**，所以子系统修的必须是构建函数的**最后一步**。

### `--embed-icon`（launcher 自带的一个好用工具）
`launcher-win.exe --embed-icon <target.exe> <icon.png>`：把 PNG 转成 PE 图标资源刻进任意 PE。
- **不要求目标是 launcher**，也**不要求 `-mwindows`** —— 就是个通用的 PE 图标 stamping 器。
- 副作用：binutils/`objdump` 之后**解析不了**被改过的 PE（资源目录不在它预期的位置），但二进制照常运行。
- 语义分工（容易搞混）：`.conf` 的 `icon=` → 入口把它当 `TINYJS_ICON` 传给 launcher → 管
  **运行时窗口 + 任务栏**图标；**Explorer 只读 exe 的 PE 资源** → 必须 stamping，光有 `.conf` 不够。

### GNU tar ≠ bsdtar：`-a` 的 zip 能力差异
- `tar -a -cf out.zip ...` 靠后缀"自动选格式"，但**只有 bsdtar（libarchive）实现了 zip 写入**；
  **GNU tar 的 `-a` 遇到 `.zip` 会静默退回未压缩 POSIX tar**，且**退出码 0、无任何警告**。
- 本机 PATH 上 `tar` 解析到 **GNU tar 1.35（来自 Git Bash）**；能用的 bsdtar 是 Windows 自带的
  **`%SystemRoot%\System32\tar.exe`（3.7.7）** —— 优先钉死绝对路径，不要依赖 PATH 顺序。
- 检验只需前两字节：真 zip = `PK`（`50 4B`）。已做成 `assertRealZip()`，在 `manifest.json`
  记 sha256 **之前**调用（否则会给一个坏文件背书）。压缩后 **18.6MB → 7.35MB**。

### `verify-bundle.py` 的两个设计选择
- **入口靠 `conf`↔`exe` 的配对关系定位**，不是"列表里唯一的 exe"：`dist/` 里同时有
  `app.exe`/`launcher.exe`，早先按 exe 列表猜结果"找到 2 个"直接判失败。
- **图标用 `ExtractIconExW(path, -1, None, None, 0)` 数**（返回值 = 图标个数），而不是自己去解资源目录 ——
  用的是 Explorer 实际会问的那个 API，等价于"真相"而非"我的假设"。

### 交付前的"构建机错觉"清单（值得每类打包都照抄一遍）
1. **DLL 齐全**：`app.exe` 非静态链 PHP → 构建机上 PATH 有 PHP 运行时所以**照样跑通**，
   到干净机器必死。→ 缺 DLL 要**警告出声**，不能只看构建机绿。
2. **子系统**：只 grep 代码看不出来，必须读产物字节。
3. **图标资源**：`.conf` 有 `icon=` 不代表 Explorer 有图标。
4. **压缩格式**：扩展名不对就等于没压缩，且工具会沉默地照做。
5. **launcher 未改动**：与 stock 比 sha256 —— 这是"分发方向不需要 launcher 补丁"这条设计的**可验证形式**。

## Phase 16b-1 发现（session 13）：Cygwin 就是可用的 POSIX 目标

### 结论先行：Cygwin 3.5.3 不是"半个 Windows"，它是真 POSIX 目标
`echo | g++ -dM -E -` 的结果（**这是判断的全部依据**）：

| 宏 | Cygwin g++ | MinGW g++ |
|---|---|---|
| `__CYGWIN__` | ✅ 定义 | ❌ |
| `__unix` / `__unix__` | ✅ 定义 | ❌ |
| `_WIN32` | ❌ **不定义** | ✅ 定义 |

`_WIN32` 不定义 → `backend_shell.cpp` 自动走 POSIX 分支，不需要任何特殊处理。加上
`sys/un.h`、`poll.h` 都在，且运行时提供 `fork`/`execv`/`AF_UNIX`，整套 POSIX 验证就能在
本机闭环，**不需要 Linux 机器、不需要云环境**。

### 先验证原语，再指责 shim（`host_probe.c`）
一个 20 行的探针把"这台机器到底支不支持"变成可打印的事实，而不是猜测。它在 Cygwin 上输出
`PROBE: ALL PRIMITIVES PRESENT`，逐项：
- `AF_UNIX bind+listen` OK，`sun_path = 108`（Cygwin 的 `sizeof(sockaddr_un) = 110`）
- `fork+execv+dup2` 子进程 + 继承 stdio OK
- **`accept()` 返回“新 fd”（≠ 监听 fd）** —— 这正是 POSIX 与 Windows 的关键差异：Windows
  的 `ConnectNamedPipe` 返回**同一个** handle，所以 `if (ep != srv) io_close(srv)` 这种
  "两平台都要对"的写法只能靠实跑验证
- `poll(fd,0)` 报可读后 `read()` 不阻塞、`read()==0` 即 EOF（socket 与 pipe 同一套代码）
- `signal(SIGPIPE, SIG_IGN)`、`waitpid` 回收都 OK

**踩坑记录**：第一版 `host_probe.c` 里 `accept()` 用 `alarm(5)` 兜底 —— 若 `SIGALRM` 触发会**直接杀进程**（退出码 142）而不是返回错误，看起来像"探针崩了"。改成"轮询 + 每次失败退避"更可控。

### `-std=c++17` + libc 可见性：一个被编译器替我们掩盖的编译错误（bug #12）
POSIX 分支**从未编译成功过**，但症状只在 Cygwin 上出现：

```
error: 'readlink' was not declared in this scope      (exe_path)
error: 'kill' was not declared in this scope          (kill_proc)
error: 'setenv' was not declared in this scope        (TINYJS_ICON)
```

三个都是"未声明"而不是"找不到头"，说明**头文件在、声明被隐藏了**。根因链：
1. `-std=c++17` → 编译器定义 `__STRICT_ANSI__`；
2. libc 据此把 POSIX 声明关进可见性宏（`_POSIX_C_SOURCE`/`_DEFAULT_SOURCE`/`_GNU_SOURCE`）之后；
3. **glibc 上 g++ 驱动会为 C++ 自动注入 `_GNU_SOURCE`** → Linux 上一直能编；
4. **Cygwin/newlib 的 g++ 不注入** → 立刻暴露。

所以这**不只是 Cygwin 问题**，而是"依赖编译器隐式行为"的脆弱性。修法选了最稳的一种：源码自带
```cpp
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
```
且**必须放在所有 `#include` 之前** —— 可见性宏只有在第一个头文件被处理前生效，放在后面等于没写。
`-D_GNU_SOURCE`、`-D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L`、`-D_XOPEN_SOURCE=700` 实测都能让
Cygwin 编过；选 `_GNU_SOURCE` 是因为它与 glibc 上"本来就被注入"的行为**逐字一致**，从而对 Linux
是零行为变化（可验证：Windows 重编后体积 126117B 与改动前完全相同）。

**教训**：平台 A 能编过，可能只是编译器替 A 做了平台 B 没做的事。跨平台代码里，凡是
`fork/kill/readlink/setenv/gethostname` 这类符号，都值得问一句"它是靠哪个宏才可见的"。

### Cygwin 的 CPython `AF_UNIX` 与原生 `AF_UNIX` 不互通（bug #13）
这是本轮最有欺骗性的发现，靠**四象限矩阵**才定位（每格单独跑，不靠推测）：

| 服务端 | 客户端 | 结果 |
|---|---|---|
| C（Cygwin g++） | C（Cygwin g++） | `accept()` **OK** |
| C | **Cygwin Python 3.9** | 客户端 `connect()` **返回成功**，服务端 `accept()` 报 **`ECONNABORTED(113)`** |
| **Cygwin Python** | C | Python 端 `accept()` 报"成功"却读到**无关的 16 字节垃圾**；C 端反而 `ECONNREFUSED` |
| Cygwin Python | Cygwin Python | 正常 |

两个方向都坏，而且坏法不同 —— 看起来像是**两套互不相干的 AF_UNIX 实现**（Python 侧可能走了
另一条伪 socket 路径）。危害在于症状是"C 端说连接中止、客户端却说连上了"，**太容易被误判成
shim 的 bug**（而 shim 完全无辜）。

→ 处置：kit 的客户端改用 **C**（`mock_launcher.c`）。这不仅是绕开 Python，还是**更保真**的选择：
真 launcher 就是 C++（`launcher-linux.cc`），用的就是同一套 libc socket 调用。
`mock_launcher.py` 保留但降级为 `selftest_fixtures.py` 用的**协议 oracle**（它跑的是假 socket，
不需要真 AF_UNIX，因此不受此坑影响）。

### 打包入口（launch 模式）在 POSIX 上此前从未跑过 —— 现在跑通了
dev 模式是"launcher 当父进程"；**打包模式反过来**：shim 是入口（`argc==1`），读
`<exe_dir>/<exe_stem>.conf`、自建端点、spawn 后端、再 spawn **原版 launcher**，参数顺序是
`launcher <html> <endpoint> [title] [WxH] [version]`。这条路径（也就是 Linux 用户真正会运行的那条）
此前只在 Windows 上验证过。用 `MOCK_LAUNCHER_ARGV=launcher` 让 mock launcher 接受同样的 argv
布局即可覆盖，无需 GTK。

两个实现细节值得记：
- **该模式下 launcher 的 stdout 是 `/dev/null`**（shim 不给 stdio，等价于 Windows 的
  `bInheritHandles=FALSE`），所以 mock launcher 把收到的 argv **当成一帧发回**，让 shim 的日志
  成为断言来源 —— 于是"conf → shim 的 argv → 线上帧 → 日志"整条链都有证据，而不是"看起来对"。
- **shim 控制的参数不能加 flag**，所以 argv 布局用**环境变量**切换（env 会随 exec 继承给子进程）。
- 顺带确认 Cygwin 有 `/proc/self/exe`，所以 `exe_path()` 的 `readlink` 实现可用（conf 能被找到即是证据）。

### 空洞断言：负向结论必须有正向对照（复用 session 11 的教训）
`launch-mode.sh` 的"无孤儿子进程"断言初版是这样写的：
```bash
ps -ef | grep -F "$WORK/" | grep -v grep | wc -l    # 期望 0
```
它**通过了** —— 但通过的原因是当时根本没有进程在跑（我想当然的"对照"是 `connect()` 到不存在的
socket，**瞬间就退出了**）。这类"永远为真"的断言语义上等于没测。

修法两步：① 用**一个确实存活**的同名进程做正向对照，先证明匹配器看得见它，再证明归零；
② 换匹配方式 —— 实测 **Cygwin 的 `ps -ef` 打印解析后的绝对路径，且忽略 `argv[0]`**
（`exec -a fake_name sleep 5` 不会让 `ps` 显示假名），所以按**二进制名**匹配，而不是按调用形式。

### Cygwin 的 PHP：7.4 是陷阱
`planb/backend.php` 用了 `str_starts_with` / `str_contains`（PHP 8.0+），而 Cygwin 自带的 PHP 是
**7.4.33** → 语法级别就跑不了。tier 2 因此要显式给 `PHP_EXE`；`tier2.sh` 会先校验
`PHP_VERSION_ID >= 80000` 再动手，避免把"PHP 版本不对"误判成"泵有问题"。

**（session 14 补）** 现在 `tier2.sh` 会**自动探测**：依次试 `php`（Cygwin 上是 7.4，被版本检查
挡掉）→ tpc 发行版的 `php.exe`（8.5.11，通过），所以裸跑 `./tier2.sh` 就能用。之前的版本直接
报"set PHP_EXE"退出，等于把脚本自己知道的信息藏起来让人手填。

### Cygwin 能证明什么、不能证明什么（引用时必须带上）
**能**：POSIX 分支**编译合规**（`-Wall -Wextra` 零警告）、AF_UNIX 端点、`poll/read` 无耦合泵、
`fork+dup2+execv` spawn（含**真 PHP 8.5** 后端）、**打包入口路径**、收尾无孤儿/socket 已 unlink、
**stdio 三通道隔离**。
**不能**：Cygwin 是**内核之上的 POSIX 仿真层**，证明的是**代码路径**而非 glibc/Linux 的系统调用
语义；也**不能**产出可发行的 Linux 二进制；更**不能**替代 tier 3 的 `--nano` freestanding 体积
测量（那必须在 Linux 上用 Linux 版 tpc 跑）。

---

## Phase 16b-1 续（session 14）：stdio 三通道分离 —— 以及"给测试加正向对照"的第二次实践

### 现象：平时看不出问题，因为它**被静默丢弃**
`spawn_proc` 原本把子进程 stderr **并进 stdout**（`si.hStdError = child_out`），理由是"别丢掉
输出"。但 **stdout 就是帧通道** —— 于是后端每写一行诊断，帧流里就多一行**畸形帧**。之所以从来
没暴露，是因为 **launcher 对不认识的帧是直接丢弃**（协议设计如此），所以它只是"脏"，不致命。

### 真正的风险不在"脏"，在**版本相关的错误路由**
实测同一段代码在两个 PHP 上行为不同：

| PHP | notice/warning 默认去向 | 与帧通道的关系 |
|---|---|---|
| 8.5.11（tpc 发行版 / 本机） | **stderr** | 被并进来 → 变成帧 |
| 7.4.33（Cygwin 自带） | **stdout** | **本来就在帧里** |

也就是说：**同一份后端，在 PHP 7 上"本来就脏"，在 PHP 8 上"被合并弄脏"**，而且在哪里炸取决于
notice 恰好落在哪两个帧之间 —— 这种 bug 不可能靠读过源码发现，只能靠**构造一个会被它咬到的
测试**。结论：不要依赖"我们知道诊断现在走哪个通道"。

### 修法：stderr 单独一条管道，只进日志
- `spawn_proc()` 增加第三个通道参数 `child_err`：Windows `si.hStdError = child_err`（注释写死
  `NEVER child_out`）；POSIX `dup2(child_err, 2)`（`child_err` 未给时才回退到 `child_out`）。
- `main()` 建第三条管道，父进程保留读端 `hReadStderr`，spawn 后关掉子端 `cStderr`。
- 新增 `drain_stderr()`：非阻塞读 + **按行重组**（半行缓到 `\n` 才落日志，并对无换行的残行加
  8KB 上限，避免后端永远不换行时缓冲无限增长）。日志行形如
  `[shell] backend stderr: <行内容>`。
- 在 `kill_proc(php)` **之后**再排空一次：写端虽已消失，**管道缓冲里还剩着后端临死前写的内容**，
  不捞就丢了。最后 `io_close(hReadStderr)`。

### 排空不是"卫生习惯"，是**机械必需**
匿名管道缓冲约 **64KB**。没人读 → 写满 → 写者 `write()` **永久阻塞**。所以一个话多的后端
（比如在循环里打个 notice）会在**协议中途把自己卡死**，而且症状是"后端不再应答"，看起来像
后端逻辑 bug。**任何"子进程有 stderr 我们不管"的设计，都必须先回答"谁在读它"。**

### 诱饵做成了 `RET` 而不是散文 —— 为了让失败**指向正确的调用**
`mock_backend_noisy.py` 在**被回答的同一个 id** 上往 stderr 写 `RET <id> 0 {"from":"stderr",…}`。
这比"一行垃圾文本"强得多，因为客户端等的是**前缀匹配**：一旦合并，它会**把诱饵当成该 id 的
真实答复**，于是真实 `RET` 晚一拍到达，报错指向**下一个**调用 —— 一个会把人带偏的失败信息。
另外还写一条**没有换行的半行**（分两次写、中间 flush），专门压 `drain_stderr()` 的重组逻辑。

### 关键一节：正向对照让"通过"变得有意义
只跑"诱饵在 stderr、客户端全绿"是**没有信息量**的 —— 它同样成立的原因可能是"诱饵根本没写
出来"。所以 `stderr-channel.sh` 有三跑：

| 跑 | 诱饵写到 | 期望（脚本断言的） |
|---|---|---|
| A | stderr | 客户端全绿；**`P->L:` 里 0 条诱饵**；`[shell] backend stderr:` 里 N 条 |
| C | stderr，但后端是**真 `backend.php`** | `log` 分支（页面 API `tiny.log(msg)`）的行只出现在日志 |
| B | **stdout**（正向对照） | 客户端**必须失败**，且 shim 日志里 forwarded 诱饵 **≥1** |

B 的断言刻意**落在 shim 日志上**（`forwarded` 计数 `0 → 1`），而不是落在客户端报错的措辞上 ——
这样"对照成立"不依赖客户端怎么措辞。计数用 `≥1` 而不是 `==N`：客户端一发现不对就退出，后面
的 CALL 根本没发出去，所以只会产生前置那几个诱饵（实测 1 条就够定案，因为 A 跑的是 0）。

**这是"给负向断言加正向对照"的第二次实践**（第一次是 session 13 的孤儿断言）。规律很清楚：
> 凡是"断言某事**没有**发生"的检查，都要先证明**如果它发生了你能看见**。否则那条断言
> 无论被测系统是坏是好，都会亮绿灯。

### Windows 侧的零回归，以及一个顺带可见的副作用
- `-Wall -Wextra` 干净，体积 126117 → 127227 B（+1110，与新增代码相符；`_GNU_SOURCE` 那段在
  Windows 上被 `#if !defined(_WIN32)` 挡住，本来就不进二进制）。
- `tinyjs build --typephp` 全链（tpc+MSVC 钩子 → 图标 stamping → GUI 子系统补丁）重跑；
  `verify-bundle.py` **0 failure / 0 warning**；打包版与 dev 反向路径**各 13 CALL/13 RET**、
  371ms / 417ms、`WM_CLOSE` 后 `launcher closed`→`closing`→`done`、**零残留**。
- **副作用（正向）**：页面标记 `WINDOW-E2E OK ping=pong in 371ms` 来自 `tiny.log()`，实测现在
  落在 `[shell] backend stderr: [php-backend] "WINDOW-E2E OK …"` —— 而**在旧 shim 下它是
  `P->L:` 的一条伪造帧**。同一个事实，两行日志的归属完全不同，这正是本次改动的意义所在。

### 一个资产只有在"它被分发到的位置"跑起来才算验过
把更新后的 shim + 整份 `posix-test/` 同步进技能后，我**从技能目录**就地跑了一遍 `all.sh` ——
立刻暴露两个只有按"分发形态"运行才看得见的问题：

1. **kit 不带 `backend.php`**，而 `tier2.sh` / `stderr-channel.sh` 默认去 `../backend.php` 找。
   在被测后端是**用户自己的**这一前提下，那个路径只是**默认值**而非承诺 —— 旧行为是拿一个
   用户从没选过的路径**报错**（在技能目录里表现为 tier2 exit 2、stderr 探针 2 FAIL）。
   改为：缺失即 **SKIP 并 exit 2** 并提示 `BACKEND_PHP=/path/to/backend.php`（exit 2 的约定
   与 tier2.sh 一致，`all.sh` 会把它报成"至少一层跳过了自己"而不是"全绿"）。
2. **`launch-mode.sh` / `tier2.sh` 把 `$HERE/.work` 写死**，无视 `WORK=` 覆盖 → 会往源码 /
   技能目录里吐临时产物。改为遵守 `WORK`。实测复跑后技能目录**不再留 `.work`**。

**教训**：以前验的是"我刚写的那份源码能不能跑"，这次验的是"**我打算发出去的那份东西能不能跑**"。
两者不等价 —— 相对路径、默认值、写盘位置这些只有在分发形态下才显形。

---

## 计划文件的"计数契约"（session 15）：为什么进度可能一直是假的

### 问题：写给人看的进度，工具读不出来
`task_plan.md` 一直用 `- [x] Phase N: …` 复选框记进度 —— 人一眼就懂。但 planning-with-files 的
`scripts/check-complete.sh` 不认识复选框，它只做两次**子串计数**：

| 脚本读什么 | 含义 |
|---|---|
| `grep -c "### Phase"` | 阶段**总数** |
| `grep -cF "**Status:** complete"` | **已完成**阶段数 |

于是实测输出是 **`Task in progress (0/0 phases complete)`** —— 21 个阶段全部完成的事实，
在机器眼里是"0 个阶段"。

### 推论：任何一个字面出现在正文里，统计都会虚高
脚本是**纯子串匹配、不解析结构**，所以字面量出现在**任何位置**都算数 —— 包括格式说明段、
Notes、示例行。第一版改写时连踩两次：

| 我写了什么（本意是"说明格式"） | 被算成 |
|---|---|
| 说明段里写出「三井号 Phase N 标题」 | 阶段总数 +1 |
| 说明段里写出「粗体 Status 行 + complete」 | 完成数 +1 |
| 自检段里写出 `grep -c "…"` 模式 | 阶段总数 +1、完成数 +1 |
| 结果 | `21/20` 被读成 **25/21**，再"更正"一次变 **22/22** |

**正确做法**：用**不含字面量**的措辞描述格式（「三级标题」「粗体 Status 行」），
自检改成**跑脚本看读数**（"应报 21 阶段 / 20 完成 / 1 pending"），而不是在正文里写 grep 模式。

### 另一个契约细节：`phase-status.sh` 只认纯整数阶段号
它的校验是 `case "$PHASE_NUM" in *[!0-9]*) 报错` → `16a`/`16b-1` 这类**会被拒绝**。
所以决定：**保留历史编号不重编号**（`16a`/`16b-1`/`16b-2` 被三份文档 + 技能全面交叉引用，
改号会让历史记录全部失效），这三个阶段的 Status 手工改；`check-complete.sh` 不受影响。

### 旧式布局（计划文件在项目根）仍受支持 —— 但本仓已经不这么放了
`resolve-plan-dir.sh` 在没有 `.planning/` 时**输出为空**，但下游脚本都会回退到 `./task_plan.md`，
实测 `check-complete.sh` 能正确读到根目录的计划。所以不必为了用这套工具去建 `.planning/`。

**本仓现状（session 16 起）**：三份文件已从仓库根移到 `docs/planning/` —— 根目录此前"不像一个
PHP 项目"，而这三份是最后几个一眼看不出归属的非工程文件。所以那套工具脚本要**在 `docs/planning/`
里跑**（它们的回退是相对 cwd 的 `./task_plan.md`），不是从仓库根跑。

### 已推翻：本项目现在是 git 仓（session 15 的结论已过期）
session 15 记的是 `git status` → `fatal: not a git repository`，所以当时只能用
**文件 mtime + 证据日志里的 sha256** 交叉验证。session 16 先做了外部 `tar` 备份再 `git init`，
现在 `git diff --stat` 已可用。（那条替代手段仍然值得保留：**每个证据日志都该把自己被测源码的
hash 写在头部** —— `cygwin-all.log` 一直这么做，所以即使没有 git 也能判断证据有没有过期。）

## 分布形态的测试套件：发布出去的副本不许弄脏自己（session 16）

### 起点：一次"整齐"的重排，把两个 bug 藏进了更短的路径里
把仓库从"什么都在 `planb/`"重排为 `src/ bin/ shim/ patches/ tools/ demo/ test/ docs/
experiments/ evidence/ build/` 之后，in-tree 全绿（51 PASS / 0 FAIL）。但这不是结论 ——
**同一份 kit 被同步进了技能目录**（它会随技能一起被分发），从**那里**跑，结果立刻变脸：
`TIER1_RC=1`、`STDERR_RC=1`。三个 bug 全部**只在更长的路径下显形**：

| # | 症状 | 根因 |
|---|---|---|
| 1 | `[FAIL] socket never appeared` + `socket path too long (108)` | `$WORK/app.sock` 在技能目录下**恰好 108 字节** = `sun_path` 上限。in-tree 只是碰巧短。 |
| 2 | `ld: cannot open output file …/host_probe.exe: No such file or directory` | `all.sh` 把 probe 编进 `$WORK/` 时没人建过它；各 tier 自己会建，所以只有第 0 步中招。 |
| 3 | 一次 standalone 跑留下 **9 个空临时目录** | `all.sh` 已 `export WORK` 给子进程共享，但子脚本仍各调一次"求默认值"的函数，**先造目录再发现用不上**。 |

**可复用结论**：`sun_path` 这类**长度上限**是典型的"本地短、分发地长"陷阱。凡是被复制出去
运行的东西，scratch 目录要么由环境显式给定，要么**由它自己挑一个短而可抛弃的位置** ——
不要沿用调用方的相对路径。这也是 `typephp_default_work` 存在的全部理由。

### 比 bug 更值得记：一条**无条件通过**的断言
launch 模式（packaged 入口）下，端点名是**入口自己**取的：`<exe_dir>/app.sock`，
超长才回退 `/tmp/tinyjs-typephp-<pid>.sock`。`launch-mode.sh` 却断言"`$WORK/app.sock` 已被
unlink"。于是在**回退触发时**（＝正好是被分发的那一侧），它断言的是一份**从未存在过的文件**，
于是**无条件通过**。它只会在另一侧正确地亮灯 —— 与"零残留进程"那条孤儿断言（session 13）
是同一类错误：**断言某一侧的状态，却不去确认那一侧确实被触达**。

修法不是"放宽断言"，而是**把被测对象的事实读回来**：从 shim 自己的日志行
`[shell] transport=unix-socket pipe=<name> app=<...> cwd=<...>` 取出真实端点名，断言它，
并打印走了哪条形式（derived / `/tmp` fallback）。**顺带白拿一条覆盖**：两条分支现在都有实测
——derived 在 in-tree，fallback 用 `WORK=/tmp/dddd…(120 个 d)/lw` 逼出来。

### 与 session 14 的规矩合并：一句话
**一个资产只有在它被分发到的位置跑起来，才算验过。** session 14 靠它发现了两个
"kit 假设了不该假设的路径"的问题；session 16 又靠它发现了三个，外加一条假通过 ——
其中最有价值的那个（sun_path）**恰好是"in-tree 全绿"最容易掩盖的那种**：路径长度不是代码
属性，是**部署属性**，所以它永远不会在开发目录里失败。

### 收尾的工程习惯：让"同步是否一致"永远可判
因为发布物不许弄脏自己，in-tree 的证据日志写 `evidence/kit/`、standalone 的写自己的临时
scratch 并把路径打印出来。这样"把 kit 同步进技能后 `diff -rq` 两边"这句话**永远成立**，
不会被残留文件变成幽灵差异 —— 而幽灵差异会掩盖真差异，这正是这份资产最需要的一种可判性。

### 融合 CLI 与旧 cli.js `build` 的功能对齐清单（session 17）

换掉一个构建工具时，**它隐含做的事**最容易丢。旧 `tinyjs build --typephp` 的完整职责，融合
`tgui build` 必须逐项对齐（本次就是漏了后两项才出的回归）：

| 职责 | 旧 cli.js | 融合 tgui build |
|---|---|---|
| 组装 dist（入口/launcher/后端/DLL/frontend/conf） | ✓ | ✓（布局改为：入口 `<App>.exe`=shim、后端 `php.exe` 分名、8 DLL） |
| DLL 集 | 6 个 PHP 运行时 | **8 个**：6 PHP + 2 MinGW（libgcc/libstdc++，launcher 与 shim 都依赖） |
| 图标刻进入口 PE 资源（`launcher --embed-icon`） | ✓ `embedIcon()` | ✓（接回） |
| PE `Subsystem` console→GUI（双击不挂黑框，bug #10） | ✓ `forceGuiSubsystem()`，**最后一步** | ✓（php 内联改 `peOff+24+68`，接回，顺序不变） |
| publish 压包 | zip（钉 bsdtar 验魔数） | zip 优先，回退 tar.gz |

下游工具盘点：`tools/verify-bundle.py` 是"产物布局"的镜像——**布局一变它必须同步变**，否则
校验器对正确产物误报、对缺项漏报（本次它还在查 `app.exe` + 6 DLL）。

## macOS（Apple Silicon）实机结论（Phase 20，2026-09-26）

- **shim 的 POSIX 分支在 macOS 有一个真跨平台缺口（bug #17）**：`exe_path()` 只有
  `readlink("/proc/self/exe")` 一条路，**macOS 没有 `/proc`** → 静默回退成字面量 `"app"`，
  于是打包入口找不到 `<stem>.conf`（读成 `app.conf`）、`launcher=` 解析成 `launcher.exe`、
  `execv` 失败——而日志只打 `[shell] execv failed`，不给路径。修法：`__APPLE__` 分支用
  `_NSGetExecutablePath` + `realpath`（dyld 提供，无额外依赖），语义与 Linux 的
  `/proc/self/exe` 一致（都返回解析后的物理路径）。Cygwin/Linux 测不到这条，因为只有 macOS
  既无 `/proc` 又各有自己的 API。
- **`realpath` 语义差异会在测试里放大**：macOS 上 `/tmp → /private/tmp` 是符号链接，
  入口回读的 `pipe=`/`html=` 全是物理路径。测试比对前先 `cd "$WORK" && pwd -P` 归一化，
  否则拿到两个"都对但字符串不同"的路径。这是测试夹具的事，不是 shim 的。
- **Apple Silicon 上"cp 一份系统二进制再跑"必被 AMFI SIGKILL**（rc=137，即使字节级一致、
  签名原样保留）。凡是想造一个"常驻假进程"做正向对照的测试，必须**现场编译**而不是
  `cp /bin/sleep`；且新 clang 把隐式函数声明当错误，探针源码要带 `#include <unistd.h>`。
  （本机 `/usr/bin/sleep` 都不存在，在 `/bin/sleep`。）
- **`launcher-macos.cc`（9108 行，WKWebView/Cocoa）可以零源码改动编出来**，要点：
  ① 必须 `-x objective-c++`（文件叫 `.cc`，clang 默认按纯 C++ 编，`@interface` 全炸）；
  ② **必须 MRC、禁止 `-fobjc-arc`**——源码里满屏 `release`/`autorelease` 和裸 `void*`↔`id`
     转换（开 ARC 后这些直接是 error，bridged cast 强制检查）；
  ③ `#include "webview.h"` 是 deprecated 转发头 → 需要新版 header-only webview 库整套
     （`api.h`/`c_api_impl.hh`/`detail/**`，69 个文件），上游 tinyjsapp 随仓库带在
     `native/include/webview/`，直接拉它的 archive 最稳；
  ④ `-mmacos-version-min=12.0` + 22 个 framework（ScreenCaptureKit 自动弱链），
     只剩 availability 警告。产物 684KB，`otool -L` 里 SCK 是 weak。
- **打包方向（入口=shim，拉起 stock launcher `<html> <endpoint> …`）在 macOS 真窗口全绿**：
  13 CALL / 13 RET、`WINDOW-E2E OK ping=pong in 48ms`、stderr 隔离同样成立
  （E2E 标记出现在 `[shell] backend stderr:` 行）。这补上了 Phase 16b-2 里"tier 4 窗口
  端到端"的 macOS 对应物（Linux 的 GTK 版仍未做）。**dev 方向（`--typephp`）依旧 Windows 独有。**
- **系统 PHP 后端在 mac 上直接当 `app=` 用**：`bin/run-backend.php` 加 shebang
  `#!/usr/bin/env php` 后即可被 shim 无 argv `execv`（POSIX 上脚本可执行，Windows 必须真 exe
  ——README 既有结论原样兑现）。顺带发现该文件早已失效（require 指到不存在的 `bin/backend.php`、
  还调 fusion 前就删掉的 `main()`），属陈旧回归而非新问题。
- `sysinfo` 返回的 `backend` 字段是**硬编码演示文案**（"aot-compiler (tpc) AOT native"），
  系统 PHP 下也照打不误——看 `runtime` 字段（真实 `PHP 8.5.7`）才对得上号。**21a 已修**：
  判型事实由 shim 供给（读 `app` 首 2 字节：`#!`→stock / `MZ`→aot），经 env
  `TYPEPHP_APP_KIND` 注入子进程（`CreateProcessW` 传 `nullptr` env 即继承、POSIX
  fork+execv 同理），PHP 侧 `$_SERVER`→`$_ENV` 链读取；同一机制顺带纠正了
  `api.version.backend` 的 `'tpc-AOT'` 硬编码。放弃过的方案：用 `PHP_BINARY` 名启发式判型
  ——打包态 tpc 后端本就伪装成 `php.exe`，会假阳性。
- 本机 GitHub 加速域：**`xget.xi-xu.me` 已被 429 限流**，用户自有镜像换到
  **`xget.fnthink.top`**（路径形态不变：`/gh/<owner>/<repo>/raw|archive/...`），仓库内
  README 与 build-launcher.sh 已同步替换。

## Phase 21b 移植中发现（2026-09-26）

- **`launcher-macos.cc` 的 `main` 以 `_exit(0)` 收尾 → win 侧 `std::atexit(terminate_...)`
  的移植方式在这里根本不会执行。** 清理必须显式挂在 `_exit` 前。且 mac 上它只是兜底：
  主回收路径是 **shim 的端点 EOF**（launcher 死 → socket 关闭 → `launcher closed` →
  `kill_proc(php)`），这条链 POSIX launch tier 已单独证明，实测 bounce 时旧 shim 逐字打出
  `launcher closed`+`done`。
- **`--typephp` 的 argv 归一化必须"拷贝不左移"**（win 侧 session 4 的教训在 mac 二次验证）：
  `sock_path = g_typephp ? "" : argv[2]`，argv[2] 里的重复 html 永不被读。
- **connect 重试只给 typephp 模式**（50×100ms）：stock `<html> <socket>` 客户端契约保持
  上游单次 connect + 原报错，避免"顺带改进"污染 pristine 方向。
- **陈旧 AF_UNIX 文件不用 launcher 管**：shim `io_open_endpoint` bind 前自己 `unlink`
  （backend_shell.cpp:346-348 注释即 bridge.js 同构）。
- **既有缺陷 #19：融合后的 `tgui dev` 在 Windows 上没有热重启。** `watch_loop` 是定义在一次性
  subshell 里的死代码、主循环 `wait` 后无条件 `break`；README/Phase 7 的"touch 触发重启"证据
  属于被 fusion 删掉的 cli.js。教训：**移植验收做全之前，README 的行为描述要按当前代码核一遍**
  ——本轮 21b 验收（mac 上 touch 触发 bounce）正是撞上这一点的契机。

## Phase 21c — macOS .app bundle：签名实测、命名坑与 LaunchServices 卷限制

- **打包级 ad-hoc 签名在 macOS 26 上不可行（实测三条路，bug #20）**：
  1. 整包 `codesign --force --sign -` 拒绝本布局——`Contents/` 下**每个文件**都被封成子组件，
     连 mode 644 的 `App.conf` 也算；把 conf 挪到 `Contents/` 级仍拒。
  2. 在 bundle 内逐二进制 `--force --sign -`：主执行体得到"bundle 式签名"，之后**对原始路径
     `--verify` 反而报** `code has no resources but signature indicates they must be present`。
  3. 先签再拷回：救得了 launcher，救不了主执行体。
  附带坑：一旦有二进制被重签过（本轮 dist 里 699424B 的 launcher），它会污染后续对照实验——
  清理办法是 `rm -rf dist` 干净重建，别在 tainted dist 上做二次签名实验。
  **结论**：tgui build 不做签名步骤；链接器自带的 ad-hoc 签名足以本机运行（Phase 20/21b/21c
  全部用它跑通）。verify 脚本对签名只做 `codesign -dvv` **信息报签**，不做 `--verify`——后者在
  bundle 上下文里的报错不说明可运行性。Developer ID + 公证是独立分发议题。
- **bundle 入口必须取无点名（`stem_of` 语义）**：shim 的 launch 模式 conf 路径 =
  `exe_dir + stem_of(exe) + ".conf"`，而 `stem_of()` 在**第一个** `.` 截断——入口叫 `App.exe`
  会去找 `App.conf`？反过来叫 `TypePHP.Demo` 就会错配。现固定叫 `App`（`App.conf` 同目录），
  这条约束同时写进了 tgui 注释和 verify 脚本。
- **后端镜像 = 逐字节拷贝，不做改写**：`Resources/app/` 下保持 `bin/run-backend.php`、
  `src/backend.php`、`gui/php/…` 相对结构，`__DIR__` require 链原样生效；conf 里
  `app=../Resources/app/bin/run-backend.php`（相对 `Contents/MacOS`，即 shim 的 base）。
  代价：目标机 PATH 要有 php（shebang 脚本），win 式 DLL 自包含在 mac 不做。
- **LaunchServices × 外部卷 = AF_UNIX `bind()` 永久挂起（bug #21）**：`open` 拉起的 bundle 在
  仓库卷 `/Volumes/data` 上卡在 `__bind`（sample 787/787），同二进制直跑同路径完全正常；
  同一 bundle 拷到 /tmp 后 `open` 全链路 13/13。判定为 GUI 上下文对非启动卷的安全层限制，
  不是 shim/launcher 代码问题。验收因此走**双路径**：开发卷直跑 + 默认卷 `open`。
- **iconset 要 10 个精确文件名**（`icon_16x16.png` … `icon_512x512@2x.png`），`iconutil` 对
  缺名/错名直接失败；`CFBundleIconFile` 不能悬空——无 icon.png 时整个键缺席（tgui 用
  `ICON_PLIST` 变量拼接实现），否则 verify 硬检会拦下"plist 指了个不存在的 icns"。

## Phase 21d — Linux 环境（Apple Container）与 unfetch 下载实测（2026-09-27）

- **Apple Container 可行，但有三条硬约束**（每条都是本机实测撞出来的）：
  1. **`paths.appRoot` 必须留在启动卷**。把 `~/Library/Application Support/com.apple.container/`
     软链到 `/Volumes/data` → apiserver 起不来（`XPC connection error: Connection invalid`），
     且 `brew services` 会显示假"已启动"。恢复默认目录 + `container system stop/start` 即好。
     → 容器镜像/VM 磁盘全部计在启动卷头上，本机启动卷只剩 ~1.7G，**发行版要挑 slim**。
  2. ghcr 直连限速 ~8KB/s 与 GitHub release 掐长连是同类环境问题：brew 走
     `HOMEBREW_BOTTLE_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles` 解决；
     内核包走 xget 镜像解决可达性。
  3. `container system kernel set --recommended` 内置下载器**没有代理/镜像钩子**，直连 GitHub 必死；
     但 `--tar <本地文件> --binary <归档成员> --arch arm64 --force` 完全离线可用。
     kata-static 归档内核成员：`./opt/kata/share/kata-containers/vmlinux-6.18.35-197`。
     注意：**`--tar` 读不了 `.tar.zst`**（`unable to open the archive, code -30`，libarchive FATAL），
     需先 `zstd -d` 成 plain tar 再传（实测装成：`kernels/vmlinux-6.18.35-197` + `default.kernel-arm64` 软链）。
- **unfetch MCP 分片线程数是正确性参数，不只是速度参数**：对会掐长连的镜像源（xget），
  `threads=32` 时断流分片重发互相重叠写，产出文件大小"恰好等于总量"但内部损坏
  （`done_bytes` 统计也失真：冲到 956MB > `total_bytes` 696,573,576）；
  **`threads=1` 同一条 URL 5m20s、retry_count=0、`zstd -t` 通过**。
  → 以后用 unfetch 下大包的默认动作：先 1 线程拿一遍，`zstd -t`/`tar -t` 校验后再谈提速。
- **unfetch 工具面**（15 个）：`add_task`（url 必填；`save_dir`/`filename`/`threads`/`expected_md5`
  可选，**支持校验和 → 下可信源时应该带上**）、`wait_for_task`（阻塞、默认 30min 超时）、
  `get_task`/`list_tasks`/`pause`/`resume`/`remove`/trash 系/`get_config`（默认 `download_dir=~/Downloads`、
  `http_threads=32`、`auto_retry=true`）/`set_config`。

## Phase 21d/16b-2 — tier 4 + tier 3 实测结果与环境路线（2026-09-27）

### tier 4（真 launcher-linux 窗口端到端）= PASS
- 容器 `tgl`（Debian 12.15 / aarch64 / kata 内核 6.18.35 / g++ 12.2.0 / GTK 3.24.38 /
  webkit2gtk-4.1@2.50.6 / PHP 8.2.33 跑 stock 后端）。`test/posix/tier4-linux-window.sh`
  一条命令：shim 编译 → **pristine `launcher-linux` 编译** → Xvfb → shim(AF_UNIX 服务端) +
  launcher(客户端) → 断言。结果：**14 CALL / 14 RET、`WINDOW-E2E OK ping=pong in 128ms`、
  shot.png 98,337B、shim 随 launcher 退出、socket 清零、TIER4_RC=0**。
- 帧计数 14/14（mac/win 当时为 13/13）；脚本断言是 ≥13/≥13，方法名未逐帧核对（差异原因未追查，不影响验收语义）。
- **上游缺陷（vendor，不改）**：`launcher-linux.cc` 的 `can_live_hidden()`（约 6921 行）无条件引用
  只在 `#ifdef TINYJS_APPINDICATOR` 内声明的 `g_indicator`（1677-1679 行）→ **不定义该宏根本编不过**，
  脚本注释里"auto disabled"的假设不成立。构建必须带 appindicator dev 包。
  Debian/Ubuntu 的 pkg-config 名是 `ayatana-appindicator3-0.1`（不是 Fedora/Arch 的
  `libayatana-appindicator3.0`）→ tier4 脚本已双名探测。

### tier 3（真 --nano freestanding 体积）数字
- 输入：5 行 `nano_min.php`（与 Windows session 8 同款：`function main(){ echo "nano-policy-build-ok\n"; }`）。
- 工具链：tpc 源码树 **v0.9.3**（不是 0.8.0，`tpc.php --version` 实证）+ **php-nano v1.0.1**
  （206 个 C/C++ 源、abi=80600）+ **phpx v2.9.2**（abi=80600）；宿主 PHP **8.4.25**（sury）。
- `php8.4 tpc.php nano_min.php --nano -o app-nano`：122 文件全源码编译，`Auditing Nano runtime
  dependencies` 过，`Build successful`。
- 产物：**1,160,624 B**（ELF aarch64 PIE、glibc、-O0、未 strip）；strip 后 **987,208 B**。
- **`ldd` 只有 libstdc++ / libm / libgcc_s / libc** —— 无 libphp、无 phpx.so、无 ini/扩展闭包。
- 直跑：输出 `nano-policy-build-ok`、RC=0。**Key Question ① 就此闭环。**
- 边界（同轮实测）：真 nano 对 `require` 直接 fatalError → demo 后端 `src/backend.php:29` 编不过；
  "小巧路线"当前只适用于单文件（或 project.xml 聚合）入口。

### 环境路线踩坑（都绕过了）
- **PHP≥8.4 进容器的成本排序**：`php:8.4-cli-bookworm` 镜像 81 blobs/881MB → 启动卷（appRoot 固定
  在启动卷）剩 ~700Mi，拉一半 ENOSPC；**sury apt（packages.sury.org/php，bookworm arm64）秒装**，
  且容器内 https 可达、签名校验过。→ 给"只要一个新 PHP 二进制"的场景，优先 apt 源而非发行镜像。
- composer.json 把 `swoole/php-nano` 放在 **require-dev** → `composer install`（无 dev）永远不装它，
  vendor 里没有属正常；nano 构建时按 `ComposerNativePackage::resolveLocalPackage` 的
  `vendor/swoole/<pkg>` 候选路径**手工放源码包即可命中**，不需要动 installed.json。
- 宿主 vendor 的 phpx 是 v2.7.0，**没有 `extra.typephp-native`**（2.9.x 才有）→ nano ABI 比对
  要求同步换 phpx 源码树，否则 `load('swoole/phpx')` 直接抛错。
- xget 镜像下 GitHub archive（`/gh/<org>/<repo>/archive/refs/tags/<tag>.tar.gz`）单文件很小
  （php-nano 3.5MB、phpx 0.7MB），unfetch threads=1 秒级完成、`gzip -t` 全过。

## Phase 22a — Linux 构建的可复现性与硬依赖面（2026-09-27）

- **同一工具链 + 同一 flag 的编译是逐字节可复现的**：`tools/build-linux.sh`（提炼自 tier-4 脚本）在
  `/work/repo` 新目录里产出的 `backend_shell`(78,352B) 与 `launcher-linux`(545,496B)，与 tier-4 当时
  `/tmp/tpgui-tier4/` 下的两份产物 `cmp` 全同。含义：**编译输入没有隐藏项**（无时间戳/路径内嵌），
  所以"脚本提炼改了什么"可以用字节差来判定——以后 Linux 构建若与既有证据不一致，差值必然来自 flag 或源码。
- **Linux 构建的真实依赖面**（容器 `tgl` 实测，Debian 12 / aarch64）：`gtk+-3.0`、`webkit2gtk-4.1`、
  `ayatana-appindicator3-0.1`（**硬依赖**，见 Errors #23）、`libX11`/`libXtst`（链接期，`TINYJS_X11` 未定义也照样链）、
  `miniaudio.h`（仓库内单头 vendored）、`python3` **或** `php`（只为生成 `tiny_client.h`）。
  `TINYJS_PIPEWIRE` 刻意不定义：那样走的是 `#ifndef` 回退截屏路径，正是我们要编进去的那条。
- launcher-linux 链接 **171** 个共享库（GTK/WebKit/libsoup/appindicator 闭包）。这是 Linux 分发的现实体积来源：
  不同于 win 的"8 个 DLL 随包"，Linux 走**系统库**路线，产物只 ~0.55MB，但目标机必须有同一套 GTK/WebKit 运行时。

## Phase 22b — 驱动"真 CLI"而不是手工编排时撞到的六个环境陷阱（2026-09-27）

`test/posix/tier4-linux-window.sh` 证明的是协议；`test/posix/linux-tgui-window.sh` 要证明的是
`tgui` 本身能用。改成驱动 CLI 之后，第一次跑就全红，根因全部在**测试环境语义**而不是被测代码：

1. **bash 的输出重定向到文件是块缓冲的**：`tgui` 的 `printf` 在 `> file` 下不会逐行落盘，
   所以"日志里还没出现 `sources changed`"是假阴性。→ 起 CLI 时套 `stdbuf -oL -eL`。
   （对用户同样成立：`tgui dev > dev.log &` 然后 `tail -f` 会看不到实时输出。）
2. **非交互 shell 没有 job control**：后台任务的 PGID 等于**脚本自己**的 PGID，于是
   `kill -TERM -$!` 把整条 `container exec` 一起打死，表现为"命令没有任何输出、退出码 0 都拿不到"。
   → 必须 `setsid` 真执行（`stdbuf setsid …` 这种顺序是无效的：setsid 必须是 exec 链的第一环）。
3. **`pkill -f <路径>` 会自匹配**：外层命令行的字符串里含同一个路径 → 打死自己（同上，静默无输出）。
   → 要么 `pkill -x <comm>`，要么写 `shel[l]` 这种字符类断法。
4. **僵尸会冒充活进程**：`pgrep -f launcher-linux` 把 `[launcher-linux] <defunct>`（ppid=1，容器
   init 不收尸）也算进去，`kill` 对僵尸无效 → "杀了 launcher 但链子还在跑"的假象。
   → 断言一律过 `ps -o pid=,stat=,comm=` 并过滤 `^Z`。
5. **"X socket 文件在"≠"X 能用"**：Xvfb 被 kill 后 `/tmp/.X11-unix/X99` 与 `/tmp/.X99-lock` 都可能残留，
   GTK 只报 `could not open display ':99'`。→ 就绪判据换成真 client 探测（`import -window root`），
   探不到才清锁重启。
6. **`WINDOW-E2E` 每个周期在 shim 日志里出现 2 行**（一次是 `L->P: CALL` 帧，一次是
   `backend stderr:` 回显 —— #14 把 stderr 只送进日志，正是它让这行看起来像"两个周期"）。
   → 周期数按 `[shell] transport=` 头计，帧断言按周期分段（awk 切段），否则 touch 测试会空洞通过。

顺带确认的实现事实：**dev 模式下 shim 的 `io_accept` 没有超时**，launcher 若在连上之前退出，
shim 会永久等待（Errors #25）；`tgui` 的有界回收（5s 后再杀）第一次跑就真实触发了这条路径，
说明那个兜底不是过度设计。打包模式由 shim 自己 spawn launcher，没人兜底 → 修在 22c（见下节）。

## Phase 22c — 打包方向的结构可校验性，与"等 accept"这件事的正确做法

**1. `stem_of()` 的第一点截断不只影响 mac，Linux 目录布局同样受影响。**
entry 文件名里只要有点，shim 就去找 `<点前>.conf`。所以 `tgui build` 的 Linux 分支在
`name` → 文件名的换算上做两件事：不在 `[A-Za-z0-9._-]` 里的字符全部 `tr` 成 `-`（空格也得洗，
`"TypePHP Demo"` 正是 demo 的默认 name），然后在第一个点处截断并**照这个结果命名目录与 entry**，
让"目录名 = entry 名 = conf 词干"恒等。这不是防御性代码，是 conf 查找的机械后果。

**2. 后端镜像的 exec 位与 `#!` 是协议的一部分，不是装饰。**
shim `execv` 后端时**不带任何 argv**，因此：a) 没有 exec 位 → spawn 失败；b) 没有 shebang →
`execv` 直接 `ENOEXEC`；c) 首 2 字节还决定 `TYPEPHP_APP_KIND`（`#!`=stock / `MZ`=aot）。
校验器把这三件事写成独立检查项，任何一条坏了都能一眼定位到具体文件。

**3. `conf icon=` 在 Linux 上真的有效**（此前只在 win/mac 上讨论过图标）。链路是：shim 在 launch
模式里把 conf 的 `icon` 解析成绝对路径 → `setenv("TINYJS_ICON")` → spawn 的 `launcher-linux`
继承 → launcher 在 1705/5821/6313 行按这个环境变量取窗口图标。也就是说 Linux 既不需要 win 的
PE 资源刻录，也不需要 mac 的 `iconutil`，一个 PNG + 一行 conf 就够。

**4. Linux 分发的真实门槛是"动态依赖清单"，不是体积。**
`ldd launcher-linux` 有 171 个共享库，其中 GTK3/WebKit2GTK-4.1/ayatana-appindicator3/X11+Xtst
是目标机必须提供的；校验器把这份清单直接打出来（而不是只报"可能需要 GTK"）。同时 `tgui build`
结尾明写三条目标机要求（stock php on PATH、GTK+WebKit、X display）。体积侧：entry 78KB +
launcher 545KB + 镜像 ≈ 872KB，tar.gz 392KB —— 与 mac 的 bundle 同量级。

**5. 修 #25 时"新写一个函数"要顺手让旧函数继续被使用。**
第一版 `io_accept_watching()` 平行复制了 accept + `FD_CLOEXEC` 逻辑，`-Wunused-function` 立刻
抓到（`io_accept` 零调用者）。收敛成：watcher 只做 `poll` + `waitpid`，`POLLIN` 一到就
`return io_accept(srv)`；`EINTR` 重试放进 `io_accept` 自己（shim 有子进程，SIGCHLD 打断 accept 是
常态事件，不该被读成"launcher 永远不来了"）。两个收获：只有一份 accept 实现；accept 的健壮性
修在了正确的那一层。Windows 分支保持阻塞 `ConnectNamedPipe` 不变 —— 这条改动的语义依赖
`waitpid`，不可移植，且 Windows 打包方向没有观察到该挂起。

**6. shell 的 env 前缀与续行符之间不能插注释。**
`A=1 B=2 \` 换行后紧跟 `# 注释` → bash 把赋值当成一条**独立命令**执行（只影响那次临时环境，
随即结束），下一行的真实命令则**完全没有**这两个变量。症状极像产品坏了：`tgui dev` 正常出窗、
帧也齐，只是 shim 日志写到了默认 `/tmp/tinyjs-typephp-dev-<pid>.log`，于是驱动脚本报
"0 cycles"。规则：注释放在整条赋值前缀之前，或干脆别用续行。

**7. 校验器不等于端到端。**
`verify-bundle-linux.sh` 证的是"shim 会去解析的东西都在且解析得到"，出窗仍属 22d。
把它当构建末尾的 gate（`tgui build` 里 FAIL 即 die），是因为布局类错误没必要等到跑窗口才发现。

## Phase 22d — 打包方向的"自包含"怎么才能被证明（2026-09-27）

**1. 唯一有意义的自包含证明是"把产物从它的语境里拔掉还能跑"。**
22d 驱动同时拔掉四样东西：① `tgui build` 后把 `dist/` 打 tar **解到仓库外**（`/tmp/tpgui-22d/dist/`）
并**删掉仓库内的 `dist/`**；② 在 relocation 后的副本上**重跑**校验器（18 项 PASS），证校验器没有
偷依赖源仓库路径；③ 启动时 `env -u` 掉全部穿线变量（`TYPEPHP_APP/CWD/BACKEND/APP_KIND/PIPE_NAME`），
并在 spawn 后断言 `env` 里不再有 `TYPEPHP_*`/`TINYGUI_*`；④ 用
`sh -c 'cd / && exec "$1"' _ "$ENTRY"` 把**进程 cwd 设成根目录**。结果仍是 14 CALL / 14 RET +
`WINDOW-E2E OK ping=pong in 109ms`，且后端自己报 `cwd=<bundle 目录>` —— 说明所有路径都是从
conf + `<exe_dir>` 推出的，任何一处残留 env 或相对路径依赖都会让这个值变样。

**2. "X 就绪"必须用真 X client 探测，不能看 socket 文件。**
`/tmp/.X11-unix/X99` 存在只说明曾经有 server 绑过，不说明它还活着。驱动里用
`import -window root` 作探针，失败才清掉 lock/socket 重新起 Xvfb —— 否则会把上一轮死掉的
Xvfb 当成"显示已就绪"，然后在 GTK 退出上浪费一次调试周期（这正是 #25 那个挂起的触发场景）。

**3. 验收脚本里"杀 launcher 后入口必须自行退出"是生命周期契约的一部分，不是收尾杂务。**
22d 的拆除步序（杀 launcher → `kill -0` 轮询入口自退 → `app.sock` 已被 unlink → `ps` 状态过滤
`^Z` 后无残留）与 win/mac 打包验收同口径。注意两点：`wait` 一个非子进程会永远阻塞，所以用
`kill -0` 轮询；zombie 仍能被 `pgrep` 命中且不吃 `kill`，必须按 `ps` 的 state 列过滤，否则
"零残留"永远判假。

**4. 验收结论要区分"结构可分发"与"用户体验"。**
Xvfb 无头能证明帧协议、conf 驱动、进程生命周期、截图取到真实渲染内容；但**证不了**合成器、
窗口管理器、托盘/通知区、HiDPI 缩放、字体渲染与壁纸。因此 README 的验证表里 Linux 打包行的
结论后面直接跟着"Xvfb 无头，非真桌面"，driver 的最后一条 PASS 消息也带着这句 —— 让证据自己
说明边界，而不是靠读者记得住限制。


---

## 21e — 没有目标平台执行通道时，怎么验收目标平台脚本（2026-09-27）

`test/win/dev-bounce.sh` 要在 Windows 的 Git Bash 里跑，本机没有 Windows 通道。可行的替代是
**在本机造 fake-Windows 工装**：把 `uname`、`tasklist`、`taskkill` 做成 PATH 前置的伪造命令，
用 python3 精确模拟 GNU `stat` 的方言行为（`-f '%m'` 退出码 1、`-c '%Y %n'` 正常），再伪造一个
launcher 吐出完整帧周期写进 shim 日志。这样能验证的是**脚本自身**：断言有判别力（人为让进程泄漏
→ FAIL/RC=1；模拟管道 EOF 拆除 → PASS/RC=0）、路径解析不空跑、`set -u` 下不炸。

**1. 工装挖出的都是真 bug，不是形式问题。**
本轮暴露 4 个：`awk` 的贪婪 `sub(/.*pipe=/, "")` 会把行尾剩余内容一并吞进"管道名"，导致"每次
bounce 管道名不同"这条断言恒真；`APP` 路径硬编码后与 `tgui` 的真实解析序（env → `build/runtime/*`
→ 依赖 php 在 PATH 的 `tinyjs.json` 覆盖）漂移，脚本会在 CLI 根本没用到的路径上报缺失。
**在假平台上跑通，是低成本发现"断言写歪了"的唯一手段。**

**2. 复制被测 CLI 的路径解析逻辑时，必须连它的门控顺序一起复制。**
`tgui` 先 `[ -f "$app" ]` 判缺再应用 `tinyjs.json` 覆盖，所以驱动必须先回填 `build/app.exe`
才能进入 json 分支；只看"最终用哪个文件"而忽略"判断发生的顺序"，会得到一个永远在错误分支里
自证的脚本。

**3. 承重断言要选在"设计缺口"上。**
Windows 侧 `dev_reap_shim()` 是 Linux-only（`[ "$OS" = Linux ] || return 0`），拆除全靠管道 EOF
链，而 `spawn_typephp_backend()` 没有 job object、`std::atexit` 在 `_exit` 路径不生效。因此
21e 的核心不是"窗口闪一下"，而是**两次 bounce 后 launcher/backend/app 进程数仍是 1/1/1**，
以及每次 bounce 的管道名必须换新。前者能漏，后者能证明没复用旧链。
