# 任务计划：把 launcher_bridge 真正并入 tinyjsapp 的 launcher-win.cc 做窗口联调

> **格式说明（机器可读契约）**：`scripts/check-complete.sh` 靠两个**字面量**统计进度 ——
> ① 数「三级标题 + 空格 + Phase」出现几次 = 阶段总数；② 数「粗体 Status 行 + complete」
> 出现几次 = 已完成数。所以每个阶段都必须写成**三级标题**、并在其下给一行**粗体 Status 行**，
> 取值只能是三个状态词之一（完成 / 进行中 / 未开始，按契约用英文）。此前本文件用 `- [x]`
> 复选框写，脚本读出 **0/0**，等于完全没有机器可读的进度。
> **注意**：这两个**字面量本身不能出现在正文里**（包括本说明段和 Notes）—— 会被算成
> 额外的阶段或额外的完成数。描述格式时请改用「三级标题」「粗体 Status 行」这类说法，
> 不要原样写出来。**阶段编号沿用历史标识（`16a`/`16b-1`/`16b-2`），不要为了整齐重新编号**
> —— `progress.md`、`findings.md`、技能文档全都按这套编号交叉引用。
>
> 自检：改完本文件后跑一次 `scripts/check-complete.sh`，它应报 **21 个阶段、20 完成、
> 1 个 pending**。数字不对就说明有人在正文里原样写出了字面量（包括这条说明自己 ——
> 本文件整理时连踩两次：第一次是"格式说明"段，第二次是"自检"段）。
> 想手工核数就用 `grep -c '#' task_plan.md`-类思路数阶段标题，别把字面量抄进来。

## Goal（目标）

将之前参考实现 `planb/launcher_bridge.cpp` 真正落地为对 tinyjsapp 真实 `native/launcher-win.cc` 的可编译补丁：让 C++ launcher 改为 spawn 由 aot-compiler 编出的 PHP 后端 `backend.exe`，并通过子进程 stdin/stdout 走 tinyjsapp 的 `CALL <id> <json>` / `RET` / `GOT` / `DLG` 帧协议完成窗口联调。

## Current Phase

**Phase 16b-2** —— 唯一 `pending` 的阶段（其余 20 个全部 `complete`）。它只包含**必须在 Linux 上跑**的两项：`--nano` freestanding 体积测量（tier 3）与真 `launcher-linux` 窗口端到端（tier 4）。**它不阻塞任何其他工作**，本地可验证的部分已于 Phase 16b-1 全部闭环。

## 关键约束（已探明）

- 真实 launcher-win.cc 已抓取在 `native/launcher-win.cc`（306KB），含全部 `tiny.*` 原生 API。
- tinyjsapp 用 canonical `webview/webview.h`（本机只有 pebview/wails 的 fork，非原版）→ 完整构建需原版 webview 依赖。
- Windows 上 aot-compiler 编出的后端是 bin 模式（链接 PHP DLL），非 nano 小巧。
- ~~本机可能无显示器/WebView2 运行时 → "窗口联调"可能只能做到 headless 冒烟~~ **（已推翻）**：本机有 WebView2 148.0.3967.54 + 交互式会话，**真实窗口渲染已实测通过**（Phase 10 起）。
- **磁盘很紧**：`C:` 81G 总 / **2.8G 可用（97%）**；`D:` 852G / **6.8G 可用（100%）** → 任何"装个 Linux 发行版"的方案（WSL 导入等）都属破坏性操作，需用户明确同意。

## Phases

### Phase 1: 获取 tinyjsapp 完整仓库
- **Status:** complete

用户下载 `D:/git/web/tinyjsapp-0.42.0`；`webview/webview.h` 已随仓库，`WebView2.h` 从 nuget 补齐。

### Phase 2: 分析真实 launcher-win.cc
- **Status:** complete

定位 spawn / IPC / 帧协议，确定集成点（spawn 于 7822 前、连接于 7766→移位、`g_pipe` 于 91）。

### Phase 3: 桥接设计（修正为 shim 架构）
- **Status:** complete

**修正为 shim 架构**（PHP 不支持 `pipe://` 服务端）：launcher spawn shim → shim 建管道 + 继承 stdio spawn PHP 后端。

### Phase 4: 在 launcher-win.cc 落地补丁
- **Status:** complete

Hunk A–D，`--typephp` + `g_typephp` 运行时开关，保留原 JS 后端路径。

### Phase 5: 构建 launcher-win.exe
- **Status:** complete

**launcher-win.exe 已成功编译（1.87MB, rc=0）**。关键修复：本机 MinGW-Builds 13.2.0 的 WinRT *基础*头是空壳（`windows.storage.h` 0 个 `IStorageFile`、`windows.foundation.h` 0 个 `IUriRuntimeClass`、`windows.ui.core.h` 0 个 `ICoreWindow`），且缺 3 个 app 级头。解法：`native/winrt-shim/` 放 mingw-w64 上游完整头，并用 **`-I`（不是 `-idirafter`）** 使其优先于本机空壳头；再自动补齐 8 个传递依赖头（fileproperties/search/geolocation/ui.input/devices.input/system 等）→ 报错 41→0。

### Phase 6: 集成冒烟测试
- **Status:** complete

headless 下 launcher spawn→命名管道→shim→PHP→`CALL/RET` 往返 PASS。

### Phase 7: 交付物
- **Status:** complete

补丁(已落地)+`launcher-win-typephp.patch`+`backend_shell.cpp`+`spawn_bridge_test.cpp`+更新后的 `launcher_typephp_patch.md`。

### Phase 8: 用真实 aot-compiler 后端跑通全链路
- **Status:** complete

用 aot-compiler(tpc v0.9.3, bin 模式) 把 `backend.php` 编成真实 `app.exe`，替换 stock php，跑通「launcher→命名管道→shim→aot 后端→`RET 1 0 {...}`」全链路（PASS）。过程中修了两个真 bug：①backend.php 的 RET 缺 status 字段（launcher 期望 `RET <id> <status> <json>`）；②每帧后未 `fflush` 导致块缓冲 hang。

### Phase 9: 固化部署脚本
- **Status:** complete

`build_all.bat`（g++ 编 shim + tpc 编 app.exe，强制 tpc v0.9.3 避免 ambient PHP_HOME）；shim 改为**单线程行帧代理**（双线程版在命名管道写死锁）。

### Phase 10: 真实窗口联调
- **Status:** complete

**本机有 WebView2 148 + 交互式会话**。写 `www/index.html` 自测页 + `grab.py`（纯 ctypes GDI 截屏 + 手写 PNG）。双向全通：① 页面→launcher→管道→shim→PHP AOT 后端（ping/sysinfo/fib40/sha256/sum/listDir 全部 RET 正确）；② 后端发 `TITLE`/`SIZE` 帧→launcher 真实改标题/改尺寸。

### Phase 11: 协议保真 + 一键可复现构建
- **Status:** complete

① 后端补齐 `client.hello`（原来是 unknown method）→ 返回 true；② 通知帧不再写 stderr，改为按 bridge.js 语义转成 `EVAL@* window.__emit({event,data})` 推给页面；③ 加 `TinyState` 缓存最近 theme/locale/winstate，页面用 `theme.get`/`system.locale`/`win.getState` 拉取（**因为 WINSTATE/SYS 在页面导航前就到达，推送必然错过**——与 bridge.js 同构）；④ 新增一键脚本 `planb/build_launcher.sh`（自动补齐 winrt-shim 头 + WebView2.h + tiny_client.h + 编译 + 部署 sidecar）。实测：`client.hello`→true、`EVAL@*` 事件 6 条（含 `minimized:true/false` 真实转换）、0 个 unknown method、0 条 stderr 噪声。
（注：②的"不写 stderr"是**当时的正确做法**——那时 stderr 就是帧通道；Phase 16b-1 之后 stderr 已独立，见 bug #14。）

### Phase 12: launcher 原生应答的帧类（DLG / 菜单）全覆盖
- **Status:** complete

① `dialog.*` 走 `DLG <id> <op>\t<args>`，**launcher 自己应答、后端不发 RET**（同 bridge.js 短路逻辑）；② `menu.set` 发整块 `MENUBEGIN…MENU/ITEM/SEP/SUB…MENUEND`，launcher 画出原生 Win32 菜单栏；③ `MENU <id>`/`TRAY`/`TRAYCLICK` 通知转成 `menu`/`tray`/`trayclick` 页面事件。用 `TINYJS_TEST_AUTODLG=ok` 自动应答 modal 对话框，从而实现**非交互**验证原生 UI。实测：菜单栏显示「文件 / 帮助」；点菜单 →`MENU open` 通知→`EVAL` 事件→页面→`DLG open\tpng,jpg,md,txt`→原生文件对话框→返回值 `null` 回到页面；alert/confirm/prompt/openFile 四类全部走通（`prompt` 返回默认值 `tiny`）。单次会话共覆盖 **8 类帧**：CALL/RET/EVAL/WINSTATE/MENU/ITEM/DLG/SIZE。

### Phase 13: 接进 `tinyjs dev` CLI（"日常可用"）
- **Status:** complete

`cli.js` 的 `cmdDev()` 新增 `--typephp` / `TINYJS_TYPEPHP=1` 分支：跳过 `generateBuild()`（TypePHP 项目无 JS 后端入口），直接 spawn `launcher-win.exe --typephp <html> <title> <WxH> <ver>`；进程链 `tjs(CLI)→launcher→shim→PHP`。修掉新发现的 launcher `SetCurrentDirectoryW(GetTempPathW())` 坑（PHP 后端 `getcwd()` 变 temp）→ CLI 注入 `TYPEPHP_CWD`，shim 用作 `lpCurrentDirectory`。热更新：`src/**`→重启后端、`src/frontend/**`→整窗重载，均无进程泄漏。实测 13 CALL/13 RET 配对、关窗后零残留。

### Phase 14: 分发依赖修正
- **Status:** complete

查出 tpc `bin` 产物**非自包含**：174KB exe 动态依赖 `php8ts.dll`(13.5MB)+`phpx.dll`+`libmpdec*`+`gmp`/`mpfr` = **15.5MB** + MSVC 运行时。本机"能跑"是因为 PATH 上有 tpc（且是 v0.9.0，版本不匹配）。已把 6 个 DLL 固化进 `demo-app/build.bat`（拷到 exe 同目录）；剥离 PATH 后全链路复测 PASS。

### Phase 15: nano 修复后能否走小巧路线 —— 实测否定 + 能力矩阵闭合
- **Status:** complete

用修复分支源码 tpc 编 nano/bin 两版对比：体积仅差 1.5%、依赖完全相同、链接指令逐字相同（`NanoBuildBackend::forHost('Windows')` 硬编码 `WINDOWS_DLL`）；nano 产物 teardown **必 SIGSEGV(139)**（5 行程序即复现，与本后端无关）。进一步用 `swoole/php-nano` 权威文档 + `CompilerBase` 源码否掉"POSIX 免 shim"假设：**nano 在任何平台都无 socket 能力**（`stream_socket_server` 在 `NANO_UNSUPPORTED_FUNCTIONS`，编译期 fatalError），`SUPPORTED.md` 明言 "Socket capability remains absent even on POSIX hosts"、"Windows deliberately uses the complete PHP/PHPX DLL runtime instead of php-nano"。→ **shim 跨平台必需**；Linux 的收益是"shim + 真 freestanding nano"的体积（无 libphp），不是免 shim。

### Phase 16a: shim 跨平台化（AF_UNIX 分支）
- **Status:** complete

`planb/backend_shell.cpp` 重构为**单文件双平台**：平台层收敛成 `io_t`（Windows HANDLE / POSIX fd）+ 一组原语（`io_open_endpoint` / `io_accept` / `io_read_avail` / `io_write_all` / `io_cleanup_endpoint` / `spawn_proc` / `kill_proc`），**帧泵只有一份实现**。要点：① POSIX 用 `socket(AF_UNIX)+bind+listen+accept`，socket 路径对齐 `runtime/bridge.js` 的 `<workDir>/app.sock` 约定，bind 前 unlink 陈旧文件、退出再 unlink（`sun_path` ≈108B，过长回退 `/tmp/tinyjs-typephp-<pid>.sock`）；② `io_read_avail` 的 POSIX 侧用 `poll(fd,0)` + 阻塞 `read` —— poll 报可读即保证 read 不阻塞，`read()==0` 即 EOF，对 socket 和 pipe **同一套代码**适用；③ 子进程 `fork+dup2+execv`，所有自建 fd 一律 `FD_CLOEXEC`（dup2 会自动清掉目标 fd 的标志）→ 等价于 Windows 侧 spawn launcher 的 `bInheritHandles=FALSE`，launcher 子进程不会持有 PHP 的 stdio 管道端；④ `signal(SIGPIPE, SIG_IGN)`，对端消失不炸进程；⑤ 退出 `SIGTERM` →(50×10ms)→ `SIGKILL` + `waitpid`。

### Phase 16b-1: POSIX 分支本地实跑（Cygwin）—— 不再依赖云环境
- **Status:** complete

用户提示"cygwin 里编译出来的是 POSIX，我没什么云环境"→ 实测 Cygwin 3.5.3 + g++ 11.4.0 就是**真 POSIX 目标**：`g++ -dM -E` 显示它定义 `__CYGWIN__`/`__unix` 而**不定义 `_WIN32`** → shim 走 POSIX 分支；且 `sys/un.h`/`poll.h` 齐全、`fork`/`execv`/`AF_UNIX` 全部可用（`planb/posix-test/host_probe.c` 逐项验证并打印 `PROBE: ALL PRIMITIVES PRESENT`，其中 `accept()` 返回**新 fd**，与 Windows 命名管道"同一个 handle"相反）。

- **实测结果：50 PASS / 0 FAIL**（`posix-test/cygwin-all.log`，由新增的 `posix-test/all.sh` 一条命令生成）。五件事全部本地跑通：
  ① **host probe** 逐项确认原语齐全（`PROBE: ALL PRIMITIVES PRESENT`）；
  ② **tier 1**（mock 后端）**11/11**，含 25 CALL 压力；
  ③ **tier 2**（**真 PHP 8.5.11** 后端，经 Cygwin shebang）**11/11**，12 CALL → 12 RET → **24 EVAL**（真后端把 `WINSTATE`/`SYS theme` 转成 `EVAL@*` 推送、`ping` 回 `"pong"`）；
  ④ **launch 模式（=打包入口路径，`argc==1` + `<name>.conf`）13/13**；
  ⑤ **stderr 通道隔离 15/15**（新增 `stderr-channel.sh`，含正向对照，见下）。
- **stdio 三通道分离（本轮加固，bug #14）**：原先 shim 把子进程 stderr **并进 stdout**（`si.hStdError = hWriteStdout`），而 stdout 就是帧通道 —— 于是后端任何一行诊断都会变成**协议垃圾**，且 PHP 的错误路由**随版本变化**（8.5 走 stderr、Cygwin 的 7.4 走 **stdout**，两者都已实测）→ 同一份代码在不同 PHP 上表现不同。改为 **stdin/stdout 走帧、stderr 单独第三条管道**：shim 只把它排空并写进自己的日志（`[shell] backend stderr: …`），**永不转发**。
  - 排空是**机械必需**，不只是卫生问题：没人读的管道 ~64KB 就写满，随后写者**永久阻塞**，话多的后端会在协议中途把自己卡死。
  - 实现要点：新 lambda `drain_stderr()` 做**按行重组**（半行要等到 `\n` 才落地，并给无换行的残行加 8KB 上限防泄漏；每次最多自旋 64×1KB 以便一次吞掉突发）；`kill_proc(php)` **之后**再排空一次（best-effort，Windows 上写端消失后 `PeekNamedPipe` 可能直接报管道已断，所以主机制是每 tick 的排空，不是这一次）；`done:` 处 `io_close(hReadStderr)`。
  - **验证方式是"带正向对照的对抗测试"**（新增 `posix-test/stderr-channel.sh` + `mock_backend_noisy.py`）：让后端在被回答的**同一个 id** 上往 stderr 写一条**与真实应答无法区分**的诱饵 `RET <id> 0 …`，外加一条**半行**；要求客户端仍然全绿、且诱饵只出现在 shim 日志里（`0 forwarded`）。然后把 `NOISY_CHANNEL=stdout` 一翻，同一个诱饵进入帧通道 → 客户端**必须失败**、shim 日志必须变成 `1 forwarded`。没有这个对照，"客户端过了"完全可能只是"诱饵根本没写出来"—— 与那个空洞的孤儿断言同一个坑。第三跑换成**真 `backend.php`**（它唯一写 stderr 的地方就是 `log` 分支，即页面 API `tiny.log(msg)`），确认真实 PHP 诊断也走日志而非协议。
  - **Windows 侧零回归实测**：`-Wall -Wextra` 干净；`tinyjs build --typephp` 全链重跑（tpc+MSVC 钩子、图标、子系统补丁）；打包版双击 **13 CALL/13 RET**、页面标记 `WINDOW-E2E OK ping=pong in 386ms`、且该标记现在落在 `[shell] backend stderr:` 行（**旧 shim 下它是 `P->L:` 的伪造帧**）；`WM_CLOSE` → `launcher closed`→`closing`→`done`、**零残留**；dev 反向路径（`tinyjs dev --typephp`）同样 **13/13**、417ms、零残留；`verify-bundle.py` **0 failure / 0 warning**（含 `launcher.exe` 与上游逐字节一致）。
- **修掉一个会让 Linux 也踩的真 bug（#12）**：POSIX 分支**从来编不过** —— `-std=c++17` 定义 `__STRICT_ANSI__`，libc 随即隐藏 POSIX 声明；glibc 上 g++ 驱动会**自动注入 `_GNU_SOURCE`** 所以看不出来，Cygwin/newlib **不注入**，于是 `readlink()`/`kill()`/`setenv()` 全部"未声明"。修法：在**所有 `#include` 之前**自带 `#define _GNU_SOURCE`（可见性宏放在任何头之后即失效），`mock_launcher.c` 同样处理。
- **发现 Cygwin 特有的 AF_UNIX 互操作陷阱（#13）**：CPython 的 `AF_UNIX` 与 Cygwin 原生 `AF_UNIX` **不在同一平面** —— C 服务端 + Python 客户端 → `accept()` 报 `ECONNABORTED(113)`（而客户端 `connect()` 竟然成功）；Python 服务端 + C 客户端 → Python 端 accept "成功"却读到**无关的垃圾字节**、C 端收到 `ECONNREFUSED`。→ 客户端必须用 C。因此新增 **`mock_launcher.c`**（真 launcher 本来就是 C++，反而更保真）；`mock_launcher.py` 退为 `selftest_fixtures.py` 的**跨平台协议 oracle**。
- 顺带落地：`all.sh`（一条命令跑完全部层次并汇成一份证据日志）、`launch-mode.sh`（打包入口路径：conf 解析 / `app=`·`launcher=` 按 exe 目录解析 / 交给 launcher 的 argv **顺序** / 无 stdio spawn / 不留孤儿子进程）、`tier2.sh`（一条命令跑真 PHP，并**自动探测**可用解释器 —— Cygwin 的 `php` 是 7.4，所以会继续走到 tpc 发行版的 8.x）、`stderr-channel.sh`、`host_probe.c`。
- **把 kit 当成交付物来验（本轮新增的习惯）**：从**技能目录**（`scripts/posix-test/`）就地跑了一遍这套脚本，立刻暴露两个只有在"按它被分发的方式"运行时才看得见的问题 —— ① kit 不带 `backend.php`，而 `tier2.sh`/`stderr-channel.sh` 默认去 `../backend.php` 找它，于是**报出一个用户从没选过的路径错误**（现在改为：缺失即**跳过并 exit 2**，并提示用 `BACKEND_PHP=` 指路）；② `launch-mode.sh`/`tier2.sh` 把 `$HERE/.work` **写死**，无视 `WORK=` 覆盖 → 会把临时产物吐进源码/技能目录（已改为遵守 `WORK`）。**教训：一个资产只有在"它被分发到的位置"跑起来才算验过。**
- **教训（与 session 11 的"测试自己的 oracle"同源）**：孤儿进程断言的初版是**空洞的** —— 它"通过"只是因为当时根本没有进程在跑。现在加了**正向对照**（先用一个存活的同名进程证明匹配器看得见它，再证明归零）。另外 Cygwin 的 `ps -ef` 打印**解析后的绝对路径**且忽略 `argv[0]`（`exec -a` 骗不过它）。

### Phase 16b-2: Linux 独有的剩余部分（Cygwin 替代不了的那两块）
- **Status:** pending

- **tier 3 —— `--nano` freestanding 体积测量**：这是"小巧路线"唯一的真实答案，必须在 **Linux** 上跑 `tpc --nano`（Windows 的 `--nano` 只是策略包装：导入逐字相同、只小 1.5%、teardown 必 SIGSEGV；Cygwin 也无法承载 Linux ELF，更不能当发行物）。命令见 `planb/posix-test/README.md` 的 tier 3 段，配好后一条命令可得 `ls -l` + `ldd`。
- **tier 4 —— 真 `launcher-linux` 窗口端到端**：需 `libgtk-3-dev` + `libwebkit2gtk-4.1-dev` + `xvfb-run`。
- 两项都**不再阻塞**别的进度：云端别名（`radeon-cloud`）缺失只影响这两项，tiers 1/2 + launch 模式 + stderr 探针本地已闭环。
- **阻塞点（需用户决策）**：拿到 Linux 用户态的三条路 —— ① 用户已有的 `radeon-cloud` 远端（`rc` 别名缺失时需先配）；② 任意 ssh 可达的 Linux 机器；③ 本地 WSL 导入发行版，但 **C: 仅剩 2.8G（97% 已用）**，属破坏性操作，**未经同意不做**。

### Phase 17: `backend.php` 去 `getenv`/`gethostname`（nano 编译合规）
- **Status:** complete

`sysinfo` 里 `gethostname()` → **`php_uname('n')`**，`getenv('USERPROFILE')?:getenv('HOME')` → **`$_SERVER/$_ENV` 超全局链**。① 用编译器源码核验：`php_uname` 不在 `NANO_UNSUPPORTED_FUNCTIONS`/`NANO_POLICY_UNSUPPORTED_FUNCTIONS`，也不匹配任何禁用前缀（`pcntl_`/`posix_`/`socket_`/`ftp_`/`opcache_`）；② 顺序**必须 `$_SERVER` 优先** —— PHP CLI 的 `variables_order` 默认不含 E，实测 `$_ENV` 为空而 `$_SERVER['USERPROFILE']` 有值；③ 全文件对两份禁用清单复审计 = **0 命中**；④ Windows 重建 + 两条 e2e 通过，取值不变（`host=DESKTOP-KO73F8K`、`home=C:\Users\Administrator`）。
- 注：禁用清单**只在 `isNanoMode()` 时**才生效（`CompilerBase::assertNanoFunctionSupported` 里有 `if (!$this->isNanoMode()) return;` 早退），所以 Windows `--nano` 从来编得过这两行 —— 这正是本轮改动的动机：**Windows 通过 ≠ 真 nano 通过**。

### Phase 18: `tinyjs build --typephp` 打包链
- **Status:** complete

`cli.js` 新增 `cmdBuildTypephp()` + `TYPEPHP_RUNTIME_DLLS`。关键设计：**打包版不需要 `--typephp` 补丁** —— 让 shim 兼任入口（新增 `--launch` 模式，无参数时默认启用），走上游原生的 Plan A 方向（入口建管道 → spawn **原版** launcher `<html> <pipe> <title> <WxH> <ver>`），故分发的 `launcher.exe` 保持未修改。产出：`<name>.exe`(入口/shim) + `launcher.exe`(原版) + `app.exe`(PHP) + 6 个 PHP DLL + `frontend/` + `<name>.conf`（行式 key=value，C++ 侧无需 JSON 解析器）= **18MB**。支持 `tinyjs.json` 的 `typephp.{build,app,dlls}`（`build` 是 shell 钩子，与 `frontend.build` 同构）。实测：一条命令完成 shim+PHP+DLL+组装；产物双击运行 13 CALL/13 RET、cwd/标题/尺寸正确、关窗零残留；**dev 路径回归无变化**。

### Phase 19: `tinyjs publish --typephp`（可分发 zip + 清单）
- **Status:** complete

`cmdPublish()` 本来就调 `cmdBuild()`，而 `cmdBuild()` 已在 `typephpEnabled()` 时短路到 `cmdBuildTypephp()` —— 所以**打包/清单几乎白送**，真正要补的是「产物是否可分发」：
- **修掉一个真·出货级 bug：入口是 console 子系统**。tpc 的 shim 由项目自带的 build hook 编译，g++ 默认产出 **CUI** 二进制 → **双击** `dist/<name>.exe` 会**全程挂一个黑框控制台窗口**。新增 `forceGuiSubsystem()`：读 PE 头把 `Subsystem` 3(console)→2(GUI)，只改一个 16 位字段，其余字节不动（上游 Windows 构建对自己的入口也这么做）。**放在函数最后执行**，因为下面的图标嵌入会整体重写 PE。
- **图标 stamping**：`.conf` 里的 `icon=` 只管**运行时**窗口/任务栏图标（入口当 `TINYJS_ICON` 传给 launcher）；**Explorer 读的是 exe 的 PE 资源**，所以新增 `embedIcon()` 用 `launcher-win.exe --embed-icon` 把图标刻进**入口**。**故意不刻 `dist/launcher.exe`** —— 那是「分发版 launcher 与上游逐字节一致」这条设计红线（运行时图标已由 .conf 覆盖）。
- **发布前校验** `assertTypephpBundle()`：缺 entry/launcher/app.exe/conf/frontend 直接 fail；缺 6 个 PHP DLL 时**大声警告**（app.exe 不是静态链 PHP，缺 DLL 在构建机上因为 PATH 有 PHP 运行时照样能跑、到干净机器必死）。
- 产出：`dist/publish/<name>-<version>-win.zip`（**7.35MB**）+ `manifest.json`（`win:{url,sha256}` + `notes`），sha256 实测与文件一致。
- 实测：zip 解压到干净目录 → `verify-bundle.py` 全绿 → **解压出来的应用直接跑通 13 CALL/13 RET**、0 错误、关窗零残留。截图 `planb/e2e-shipped.png`。
- 新增工具 `planb/verify-bundle.py`：客观校验入口子系统/图标资源/launcher 是否原版/DLL 完整性/conf+frontend（用 `ExtractIconExW` 数图标，而不是猜资源目录）。

## Key Questions

1. **Linux 上"小巧路线"到底多小？** `tpc --nano` 的 freestanding 产物是否真的不链 libphp（`ldd` 可证）、体积相比 bin 模式省多少？→ **未回答**，必须 Linux（Phase 16b-2 / tier 3）。这是整个方案里唯一还悬着的技术问题。
2. **同一份 POSIX 分支在真 glibc/Linux 上行为一致吗？** Cygwin 只能证明**代码路径**，不能证明系统调用语义；`launcher-linux` 的 GTK/WebKit2GTK 窗口能不能跑通同一套帧？→ **未回答**（Phase 16b-2 / tier 4）。
3. **shim 能不能省掉？** → **已回答：不能**。真 nano 在任何平台都没有 socket 能力（编译期 fatalError），bin 模式的 libphp 才能直接 `listen` 但那样就不小了。shim 是跨平台必需。
4. **stderr 该走哪条通道？** → **已回答**：独立第三条管道只进 shim 日志（bug #14）。因为 PHP 的错误路由随版本变化，不能假设。

## Decisions Made（决策）

| Decision | Rationale |
|---|---|
| shim 架构（而非让 PHP 直接 serve 端点） | PHP 无 `pipe://`；真 nano 编译期就没有 socket API。故 shim 跨平台必需（Phase 15 用编译器源码 + 官方 `SUPPORTED.md` 双向核实） |
| 单线程非阻塞轮询泵（而非请求/响应耦合） | launcher 会发**通知帧**（WINSTATE/NAV/SYS），后端不回 RET → 耦合泵必然死锁（bug #2） |
| 打包版不给 launcher 打补丁，改让 shim 兼任入口 | 让分发的 `launcher.exe` 与上游**逐字节一致**（可校验、可升级），方向反过来用上游原生的 Plan A |
| backend.php 只用 nano 允许的函数集 | Windows `--nano` 只是策略包装、从不报错，所以"本机编得过"不能证明真 nano 编得过（Phase 17 动机） |
| 优先真实仓库 + 真实编译；不可得则交付"精确补丁 + 构建说明" | 明确标注未跑通的部分，不用猜测冒充验证 |
| 不删除原 JS 后端路径 | 新增 `TYPEPHP_BACKEND` 编译宏门控，便于对比与回退 |
| stderr 独立管道、只进日志 | PHP 错误路由随版本变化；且不排空的管道会阻塞写者（bug #14） |
| 保留历史阶段编号（`16a`/`16b-1`/`16b-2`），不为整齐重编号 | 所有历史文档/技能都按这套编号交叉引用，重编号会让旧记录失效 |
| 断言负向结论时必须配正向对照 | 两次踩坑（孤儿断言、stderr 诱饵）都证明"没发生"的断言极易空洞通过 |

## Errors Encountered（关键 bug）

| # | 一句话症状 | 根因 → 修法 |
|---|---|---|
| 1 | 标题显示成尺寸串 | argv 整体左移吞掉一个位置槽 → 只覆盖 flag 槽 |
| 2 | 后端收不到任何 CALL，窗口不出现 | 请求/响应耦合泵被通知帧卡死 → 双向非阻塞轮询 |
| 3 | tpc 报 "All execution code must be within a function" | 顶层 `main();` → 删掉，tpc 自动调用 `main` |
| 4 | 相对路径全部失效 | launcher 启动即 chdir 到 temp → 注入 `TYPEPHP_CWD` |
| 5 | 只在有 PATH 的机器上能跑 | tpc bin 产物非自包含 → 6 个 DLL 随 exe 分发 |
| 6 | 双击不进入打包模式 | 无参启动必须 `argc==1` 即打包模式 |
| 7 | PHP 永远读不到 EOF | spawn launcher 时继承了 stdio 管道端 → `bInheritHandles=FALSE` |
| 8 | 窗口根本不出现，编译却零警告 | 跨平台重构把 stdin 管道方向写反 → 显式命名 `r1/w1/r2/w2` |
| 9 | env 回退链拿不到值 | PHP CLI `variables_order` 不含 E → `$_SERVER` 优先 |
| 10 | 双击挂一个黑框控制台 | 入口是 CUI 子系统 → 改 PE `Subsystem` 3→2，且必须是最后一步 |
| 11 | 分发的 `.zip` 其实是 tar | GNU tar 的 `-a` 不写 zip → 钉死 bsdtar + `assertRealZip()` 验魔数 |
| 12 | POSIX 分支从来编不过 | `__STRICT_ANSI__` 隐藏 POSIX 声明，glibc 隐式注入 `_GNU_SOURCE` 而 newlib 不注入 → 源码自带 `#define _GNU_SOURCE`，且必须在所有 `#include` 之前 |
| 13 | Cygwin 上"连上了但服务端说连接中止" | CPython `AF_UNIX` 与原生 `AF_UNIX` 不互通 → 客户端改用 C |
| 14 | PHP 的诊断变成帧流里的畸形帧 | stderr 被并进 stdout（=帧通道）→ stderr 独立第三条管道，只进日志 |

详细根因、复现与修法见 `progress.md` 对应 session 条目与 `findings.md`。

## Notes

- 每个阶段完成后，把它的 Status 行改成 `complete`，并在 `progress.md` 追加一条 session 记录。
- **`phase-status.sh` 只认纯整数阶段号**，所以 `16a`/`16b-1`/`16b-2` 这三个阶段的 Status 需要手工改（或 `sed`）。`check-complete.sh` 不受影响 —— 它只数字面量，不做整数解析。
- 正文里**不要原样写出那两个被统计的字面量**（见开头的格式说明），否则阶段总数会被高估、进度百分比失真 —— 本文件第一次整理时就踩过：因为要"说明格式"而写出了字面量，结果被读成 25/21 而不是 21/20。改完务必用开头那两条 `grep` 自检。
- 每次重大决策前重读本文件（把目标重新拉回注意力窗口）。
- 所有错误都要记进 `Errors Encountered` —— 它们是这个项目最贵的资产。
- 外部内容（网页/API/搜索结果）只写进 `findings.md`，**不要**写进本文件。
- **未跑通的部分必须显式标注**，不要用猜测冒充验证（Phase 16b-2 就是为此单独留着一个 `pending`）。
