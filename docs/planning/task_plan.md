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
> 自检：改完本文件后跑一次 `scripts/check-complete.sh`，它应报 **24 个阶段、24 完成、
> 0 个 in_progress（Phase 21e 已于 2026-09-27 Windows 真机闭环：验收驱动 `test/win/dev-bounce.sh` PASS，
> 无泄漏、零残留；README 单发注记已删）**。数字不对就说明有人在正文里原样写出了字面量（包括这条说明自己 ——
> 本文件整理时连踩两次：第一次是"格式说明"段，第二次是"自检"段）。
> 想手工核数就用 `grep -c '#' task_plan.md`-类思路数阶段标题，别把字面量抄进来。

## Goal（目标）

将之前参考实现 `planb/launcher_bridge.cpp` 真正落地为对 tinyjsapp 真实 `native/launcher-win.cc` 的可编译补丁：让 C++ launcher 改为 spawn 由 aot-compiler 编出的 PHP 后端 `backend.exe`，并通过子进程 stdin/stdout 走 tinyjsapp 的 `CALL <id> <json>` / `RET` / `GOT` / `DLG` 帧协议完成窗口联调。

> **路径已迁移（session 16）**：`planb/` 已不存在。本文件与 `progress.md`、`findings.md` 里的历史条目**保留旧路径不重写**（它们是当时的记录），对照关系见 `progress.md` session 16 的迁移表：参考实现现在是 `experiments/bridge-probe/launcher_bridge.cpp`，后端 `src/backend.php`，shim `shim/backend_shell.cpp`，套件 `test/posix/`，demo `demo/`。

## Current Phase

**Phase 16b-2 已于 2026-09-27 闭环（Apple Container Linux 容器实测）**：tier 4 真 `launcher-linux` 窗口端到端 **PASS**（14 CALL/14 RET、`WINDOW-E2E OK ping=pong in 128ms`、截图+拆除零残留），tier 3 真 `--nano` freestanding 产物 **1,160,624 B（strip 后 987,208 B）、`ldd` 无 libphp、直跑输出 marker**。两个 Key Question 均已回答（见下）。

**Phase 22（2026-09-27，用户选定的下一轮方向）：Linux 打包/dev 方向落地** —— 把 tier-4 那次"手工编排"的证据固化成产品链：`tools/build-linux.sh` + `tgui status/dev/build/publish` 的 Linux 分支 + 容器内端到端验收。**22a/22b/22c/22d 全部完成（Phase 22 闭环）**：构建脚本、dev + 真窗验收、打包布局 + 结构校验 + #25 的 shim 修复、以及打包方向在 Xvfb 下的真出窗直跑（清掉穿线 env、进程 cwd 设为 `/`、仓库 `dist/` 已删的副本仍 14/14 + 109ms marker + 拆除零残留）。

**21e 已于 2026-09-27 在 Windows 真桌面（无 Xvfb）闭环，本文件 24 个阶段全部完成、0 个进行中。**
真机跑 `test/win/dev-bounce.sh` → 7/7 绿：cycle1 13/13 + marker、touch→bounce 换新 pipe 再 13/13、
**两次 bounce 后 launcher/shim/app 仍 1/1/1 无泄漏**、关窗零残留（README 验证表 Windows 开发方向行，
`WINDOW-E2E OK ping=pong in 416ms`，三次弹窗 416/370/415ms，现场见 `evidence/win/`）；顺带修掉只有真机能暴露的 **WebView2 共享 UDF 锁死**（每次 launch
独立 `%TEMP%/tinyjs-typephp-<pid>-<rand>`）与 `build-launcher.sh` 的 tiny.js 路径 + webview 头 staged
缺失（融合后 Windows 构建在干净状态实际已断，现可复现）。

**下一轮没有"排好的下一步"了** —— 新开阶段需要用户选定方向。已选定并做完的一项：
① **补 21e 证据入库** ✅（2026-09-27 闭环）：`test/win/collect-evidence.sh`（完整性守卫：缺 `shim.log`/
`tgui.out`/任一 `tasklist.*.txt` 就 RC=2 拒收半截证据 → 拷成 `evidence/win/21e-*` → 自行推导
`21e-MANIFEST.txt`）在 Windows 机上跑过并 push（`e3171a4`），本机 pull 后**逐条独立复核**：sha256 全对上、
3 个周期各 **13 CALL / 13 RET**、三条管道 19188/16508/37156 无复用、marker **416/370/415ms**、
`[shell] done`×3 + `launcher closed`、`shot.png` 1920×1080 真屏、`tasklist.teardown.txt` 0 字节 = 零残留；
`21e-shim-build.log` 存在且空 ⇒ 驱动 [2/7] 的 g++ 分支零输出 ⇒ **shim `_WIN32` 分支在真机 `-Wall -Wextra`
0 warning 编过**，21a/22c 那笔"Windows 侧没重编"的账一并闭掉。复核还抓出两个错并都修了：收集器
`proc_counts` 按 CSV 引号形态匹配、而驱动 `win_rows()` 已 `tr -d '"'`，导致入库清单把真实 **1/1/1 写成
0/0/0**（改为第一字段等值比较 + "非空却不匹配任何名字 → 打 UNPARSED"护栏，并用 `REGEN=1` 只重算派生块、
保留原始 provenance 头）；README 验证表的 **406ms 与证据不符**（实为 416/370/415ms，已按证据改）。
`evidence/win/21e-MANIFEST.txt` 可随版本演进用 `REGEN=1` 重算，不必回 Windows 机重跑驱动。

①b **把这套流程写成 `test/win/README.md`** ✅（2026-09-27，本轮）：`test/win/` 此前只有两支脚本没有
README（而 `test/posix/` 有），主 README 的目录树也漏了 `test/win/`。补文档时又抓出两个真问题：
**README 第 16 行给的核对命令是错的**（`bash collect-evidence.sh REGEN=1 OUT=…` 把变量当 argv 传，
静默无效 —— 实跑 RC=2 且什么都没写），env 前缀形式才对；**`REGEN=1` 会把上一次自己追加的
`# re-derived` 头当原始 provenance 读回来**，跑两次就累积两个 stamp（改为在第一个 `# re-derived` 处截断）。
据此把"第三方复核"从"REGEN + 人眼看 git diff"改成 **`CHECK=1`**：只重算、只比对派生块、**不写盘**、
RC=1 报 DRIFT 并打出 diff。两条判别力都在本机验过：对真 `evidence/win/` 出 SAME(RC=0) 且工作树零改动，
对临时副本里手动改成 `CALL=9` 的清单出 DRIFT(RC=1)。

剩余候选按代价从低到高：② Linux 真桌面会话验收（容器只有 Xvfb，证不了合成器/WM/托盘/HiDPI）；
③ mac 分发签名（Developer ID + 公证，见 Errors #20；外部卷 `bind()` 挂起见 #21）；
④ `--nano` 单文件聚合入口（Errors #22 的能力边界）；
⑤ demo 页"调用链"文案写死 Windows 措辞（外观遗留，非缺陷）。

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
- **Status:** complete（2026-09-27，容器 `tgl`：Debian 12.15 / aarch64 / 内核 6.18.35 / g++ 12.2.0）

- **路线决策（用户）**：放弃云端 `radeon-cloud`/WSL，本机用 **Apple Container**（brew 公式 `container` 1.4.1）；**OrbStack 被用户明确否决**，相关后台任务与机器已拆除。
- **环境事实（已实测，细节见 findings）**：① ghcr 直连 ~8KB/s → bottle 走 TUNA 镜像装成；② 启动卷满致 brew 写失败 → 获批清 4 个 updater 缓存（~1.7G）；③ `paths.appRoot` 必须留在启动卷，软链到 `/Volumes/data` 会让 apiserver XPC 挂死；④ recommended 内核包 `kata-static-3.32.0-arm64.tar.zst`（696,573,576B）GitHub 直连被掐、xget 镜像掐长连断点续传（且两条 curl 并发写同一文件互相打坏）→ **用户指令：停 curl，改用 unfetch MCP 下载**。unfetch 实测：**32 线程分片会写坏文件**（xget 掐流后分片重发重叠，`done_bytes` 超总量、`zstd -t` 报 corruption）；**threads=1 顺序下载 5m20s 一次成功、校验通过** —— 对该镜像源必须单线程。
- **tier 4 实测 = PASS（2026-09-27）**：`test/posix/tier4-linux-window.sh`（修了两处：ROOT 层级 `../../`；pkg-config 双名探测 `libayatana-appindicator3.0`/`ayatana-appindicator3-0.1`）在容器内一条命令跑完：shim 编译 ✓ → **真 `launcher-linux`（GTK 3.24.38 + webkit2gtk-4.1@2.50.6）编译 ✓** → Xvfb → shim(AF_UNIX 服务端) + launcher(客户端) → **14 CALL / 14 RET、`WINDOW-E2E OK ping=pong in 128ms`**、shot.png（imagemagick 截图 98,337B）、拆除后 shim 随 launcher 退出、socket 清零。Key Question ②就此回答：**同一份 POSIX 分支在真 glibc/Linux 上与 Cygwin/macOS 行为一致**（且 launcher-linux 是 pristine vendor、未打任何补丁）。
- **tier 3 实测（2026-09-27，环境路线修正）**：`php:8.4-cli-bookworm` 镜像 881MB 拉不下（启动卷剩 ~700Mi，ENOSPC）→ 改走 **sury apt 源**（`packages.sury.org/php` bookworm arm64，容器内 https 直接可达）装 PHP 8.4.25；tpc 源码树实为 **v0.9.3**（此前记 0.8.0 有误），其 vendor 里 phpx 是 2.7.0 **无 nano 元数据** → 用 xget+unfetch（threads=1）拉 **phpx v2.9.2**（`extra.typephp-native.abi=80600`）与 **php-nano v1.0.1**（abi 同为 80600，206 个 C 源），替换/放入 `vendor/swoole/` 后经 base64 管道进容器。编译 5 行 `nano_min.php`（与 Windows session 8 同款输入）：`php8.4 tpc.php nano_min.php --nano -o app-nano` → 122 文件全源码编译、`Successfully compiled` + `Auditing Nano runtime dependencies` + `Build successful`。产物 **1,160,624 B（ELF aarch64 PIE，g++ 12.2，-O0）/ strip 后 987,208 B**；**`ldd` 只有 libstdc++/libm/libgcc_s/libc —— 无 libphp、无 php.ini、无扩展 DLL**；直跑输出 `nano-policy-build-ok`、退出码 0。Key Question ①就此回答（数字与边界见下）。
- **tier 3 撞出的真 nano 能力边界（如实登记，见 Errors #22）**：真 nano **拒绝 `require`/`include`**（`NanoSyntaxValidationVisitor` 对 Include_ 一律 fatalError）→ 本仓库 demo 后端 `src/backend.php:29`（require gui 框架）**在 Linux 真 nano 下编不过**；Windows 的 nano-policy 包装编得过恰是"Windows 通过 ≠ 真 nano 通过"（Phase 17 结论）的又一实证。若日后要走 nano 发行，demo 入口需改成单文件聚合或 native project.xml 多源输入。
- **Linux bin 模式无对照数**：Debian/sury 不提供 embed SAPI 开发库，容器里编不出 bin 产物 → "相比 bin 省多少"只能定性：bin 模式需随包分发 libphp8.4.so + php.ini + 扩展闭包（Windows 侧实测 DLL 闭包 15.5MB），nano 模式这些**全部为零**，代价是上面那条语法/函数面限制。

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

### Phase 20: macOS 实机编译运行（2026-09-26 起）
- **Status:** complete

目标：在 Apple Silicon Mac（macOS 26.6.2 / arm64 / Apple clang 21 / PHP 8.5.7）上验证跨平台边界。范围按 README「支持一个新平台」一节的既有结论收窄：**不碰 tpc/MSVC（Windows 专属）**，后端用系统 PHP（shebang 脚本，POSIX 下 shim `execv` 允许）；走**打包方向**（shim 当入口，launcher 用 pristine `launcher-macos.cc` 的 stock `<html> <socket> [title] [WxH]` 契约），dev 方向的 `--typephp` 在 mac 上仍不存在（不静默：这是既有已知限制，非本轮砍掉）。

- **20a** shim POSIX 分支在 macOS 编译（`clang++ -std=c++17`，含 `-Wall -Wextra`）→ `build/`
- **20b** `test/posix/all.sh` 全套在 macOS 实跑（probe/tier1/tier2/launch/stderr），目标 50 PASS / 0 FAIL，证据落 `evidence/kit/`
- **20c** `gen-client.sh` 生成 `tiny_client.h` 后编译 `launcher-macos.cc`（WebKit/Cocoa framework）
- **20d** 端到端：`build/backend_shell`（launch 模式）拉 `launcher-macos` + 真 PHP 后端，WKWebView 窗口出现、CALL/RET 配对、`WINDOW-E2E OK`
- **20e** 结论回写本文件 + `findings.md`/`progress.md`；若 launcher-macos 需要 .app bundle 或 TCC 权限弹窗，如实记录为限制

Phase 20 收尾时明确未做的事项，已升格为 **Phase 21**（见下），不在本轮范围内静默吞掉。

### Phase 21: macOS 收尾四项（自 Phase 20「未做」清单移入）
- **Status:** complete（21a/21b/21c/21d/21e 全部完成；21e 于 2026-09-27 Windows 真机闭环：验收驱动 `test/win/dev-bounce.sh` PASS）

- **21a `tgui` 接 macOS** ✅（2026-09-26 完成）：`gui/bin/tgui` 目前只有 Windows 路径，mac 上靠 `tools/build-macos.sh` 直接编排。最小验收：`tgui status` / `tgui dev` 在 Darwin 上给出**明确指引**（指向 `build-macos.sh --run`）而不是"找不到 launcher-win.exe"式的裸失败；顺手把 `sysinfo` 的 `backend` 字段改成按真实运行时上报（现在系统 PHP 下仍硬编码 "aot-compiler (tpc) AOT native"，findings 已标注为文案性缺陷）。
  - 结果：`tgui status` 在 Darwin 增列 macOS 三件套实际路径 + 指向 `tools/build-macos.sh --run`；`tgui dev` 直接给出同一段指引再 die（不再裸报 launcher-win.exe missing）。`sysinfo.backend` 改为真实上报：shim 在拉后端前读 `app` 文件首 2 字节判型（`#!`→`stock`，`MZ`→`aot`，其余/读不到→`unknown`），经 env `TYPEPHP_APP_KIND` 注入（Windows `SetEnvironmentVariableW` / POSIX `setenv`，子进程继承；与 TINYJS_ICON 同一惯用法），PHP 侧按 Phase 17 规则走 `$_SERVER`→`$_ENV` 链读取。
  - 实测（macOS 实机）：直调后端 `TYPEPHP_APP_KIND=stock` → `"backend":"stock PHP CLI (no AOT)"`；未设 → `"unknown (TYPEPHP_APP_KIND not set)"`；打包 E2E shim 日志 `app_kind=stock`、13 CALL/13 RET、`WINDOW-E2E OK ping=pong in 54ms`，活动帧流里 sysinfo RET 含 `stock PHP CLI (no AOT)`、api.version RET 含 `stock`。回归：smoke 24/24、`test/posix/all.sh` ALL TIERS OK（probe+11/11/14/15，0 FAIL）。
  - 顺带（同类硬编码撒谎，一并改）：`DemoApiHandler.php` 的 `api.version.backend` 从 `'tpc-AOT'` 改为透传 `TYPEPHP_APP_KIND`。
  - 未验证项（如实登记）：Windows 分支的 `_wfopen`/`SetEnvironmentVariableW` 新增段本机无 mingw，只做代码审查（与既有 TINYJS_ICON/_wfopen 用法逐字同构），待下次 Windows 实机构建覆盖；`tgui build` 在 Darwin 的行为**不在 21a 验收内**，未改（仍是裸 die），随 21b/21c 处理。
- **21b `--typephp` 移植进 `launcher-macos.cc`** ✅（2026-09-26 完成）：把 win 侧那 4 个 hunk（集中在 spawn 后端与参数解析）3-way 合过来，mac 上才有**真 dev 方向**（launcher 拉 shim、改后端热重启）。代价与 win 侧同构：`launcher-macos` 不再是 pristine vendor，"与上游逐字节一致"仅相对本仓库。验收 = mac 上 `tgui dev` 出窗 + 后端文件改动触发窗口闪一下 + 13 CALL/13 RET。
  - 结果：`launcher-macos.cc` 按 Hunk A–E 同构移植（AF_UNIX `/tmp/tinyjs-typephp-<pid>.sock`、`posix_spawn`、connect 重试 50×100ms **仅 typephp 模式**、`terminate` 挂 `_exit(0)` 前——win 的 `std::atexit` 在 `_exit` 路径不生效，照抄会失效；主回收仍是 shim 的端点 EOF 链）。`tgui dev` Darwin 化：三件套默认指向 mac 产物、`typephp.{backend,app}` 仅在文件存在时生效、mtime watcher kill+respawn；**Windows 分支逐字保留原行为**（见下：那本来就是单发启动）。
  - 实测（Apple Silicon 实机）：`tgui dev` 出窗 13 CALL/13 RET、`WINDOW-E2E OK ping=pong in 56ms`、`app_kind=stock cwd=<demo>`、`backend":"stock PHP CLI (no AOT)"` 出现在帧流；`touch src/backend.php` → bounce → 新 shim 实例再 13/13；杀 launcher → tgui 退出 `NO_PROCS`、socket 清零；打包方向复验 13/13 + 49ms；`test/posix/all.sh` ALL TIERS OK。证据 `evidence/mac/dev-21b.log`；移植细节记入 `docs/launcher-patch-notes.md`。
  - **本轮撞出的既有缺陷 #19**：现 `tgui dev` 的 Windows 热重启是 fusion 遗留死代码（`watch_loop` 定义在无人调用的 subshell 里 + 主循环无条件 `break`），Phase 7 "touch 触发重启"真机证据属旧 cli.js。README 已改为如实描述（mac 有 bounce、win 单发），win watcher 恢复登记为新未做项（见 21e）。
- **21e（2026-09-27，已完成）Windows watcher 恢复**：把 Darwin 的 mtime-watch + kill/respawn 验到 Windows 上（`stat -c %Y` 或 PowerShell `Get-Item` 取 mtime，Git Bash 无 `stat -f`），并删掉 README"融合后单发启动"注记。验收 = win 上 `tgui dev` + touch 后端文件 → 窗口闪一下 + 13/13 复用。
  - **代码侧已完成**：`gui/bin/tgui` 监视循环去掉 `[ "$OS" = Darwin ]` 门控（win/mac 的 `--typephp` dev 方向共用同一生命周期链：kill launcher → shim EOF 回收 PHP 子进程 → respawn）；`hot_snap` 的 stat 方言改为**现场探测**（BSD `-f '%m %N'` / GNU `-c '%Y %n'`，Git Bash 带 GNU coreutils）。本地验证：`bash -n` 过；假 stat 证明 GNU 探测路径选中且 digest 语义与 BSD 一致；**无头冒烟**（fake launcher）跑通 touch→bounce→respawn→清理零残留。
  - **真机闭环（2026-09-27，Windows 真桌面，无 Xvfb）**：`test/win/dev-bounce.sh` **PASS**（7/7 步绿）。cycle 1：13 CALL / 13 RET、`WINDOW-E2E OK ping=pong`、整 1 launcher、`shot.png` 渲染。bounce（touch `src/backend.php`）：CLI 打 `sources changed — bouncing`，新 pipe（`\\.\pipe\tinyjs-typephp-<pid>` 随新 launcher pid 变）、cycle 2 再 13/13 + marker；**两次 bounce 后 launcher/shim/app 仍 1/1/1 无泄漏**（关键：Windows 无 `dev_reap_shim` 兜底，shim 自杀只靠管道 EOF）；cycle 3 同；关窗零残留。**Play 21e 撞出的两个真机才暴露的缺陷已一并修复**：① WebView2 重发失败——被硬杀的旧 host 留下的 `msedgewebview2.exe` 锁住共享的 per-exe 用户数据目录，下一发 `CreateCoreWebView2Controller` 一直 `ERROR_INVALID_STATE`、最终 `webview_create` 返回 null（原报错 `launcher: failed to create webview`）。修复：launcher 每次 launch 用独立 `%TEMP%/tinyjs-typephp-<pid>-<rand>` UDF（`launcher-win.cc` 新增 `tinyjs_prepare_webview_udf()`，置 `TINY_WEBVIEW_UDF` 环境变量；`gui/host/include/webview/.../win32_edge.hh` 在 `embed()` 里读取，未设则回退原 per-exe 行为）。② `build-launcher.sh` 两处路径缺陷（`$HOST/runtime/tiny.js` 应为 `$ROOT/gui/runtime/tiny.js`；缺 webview 头文件的 staged 步骤）——现已修正，Windows 构建从干净状态可复现。README 的 win 单发注记**已删**，验证表 Windows 开发方向行改为如实描述 bounce。
  - **验收驱动已就位（2026-09-27，`test/win/dev-bounce.sh`）**：在 Windows 机的 Git Bash 里 `bash test/win/dev-bounce.sh` 一条命令跑完 7 步，证据落到 `$WORK`（默认 `/tmp/tpgui-21e`），把 PASS/FAIL 与 `$WORK` 内容贴回来即可闭环。它按 tgui 的**同一套**路径解析（env > `build/runtime/{launcher-win,backend}.exe` + `build/app.exe`，再被 `demo/tinyjs.json` 的 `typephp.app` 覆盖）预检并自动从 `build/` 补装缺失产物；断言集是：cycle 计数按 `[shell] transport=` 头分周期、每周期 ≥13/13 + marker、**每次 bounce 后管道名必须换**（`\\.\pipe\tinyjs-typephp-<pid>` 随 launcher pid 变）、**`launcher/backend/app` 三个进程数在两次 bounce 后仍是 1/1/1**（这条是 21e 的关键：Windows 侧没有 `dev_reap_shim` 兜底，kill 掉 launcher 又不跑 atexit，shim 自杀只能靠管道 EOF，泄漏会逐次累积）、关窗后零残留。附带 `stat -f`/`-c` 方言断言（Git Bash 必须拒绝 BSD 形式，否则 digest 恒等于"watcher 死了"）与 `g++ -Wall -Wextra` 重编 shim 的 `_WIN32` 分支（顺手还掉 22c 那笔"Windows 没重编"的账；无 g++ 时打印 skip 并在末尾复述该缺口）。脚本本身在 mac 上用假 `uname`/`tasklist`/`taskkill`/`stat`/`launcher-win.exe` 做过全流程演练：泄漏场景（伪造 launcher 不响应管道 EOF）判 **FAIL / RC=1**，模拟 EOF 拆除场景判 **PASS / RC=0**（输出 `3 cycles`、`zero residue (launcher=0 shim=0 app=0)`）—— 即断言集**有判别力**，但这**不等于** Windows 通过。演练细节与可复用方法见 findings"21e"节。
- **21c `.app` bundle 封装与分发链** ✅（2026-09-26 完成）：双击体验——Info.plist（含 TCC usage description，源码里 ScreenCaptureKit/getUserMedia 那套权限文案需要它命名）、图标（对应 win 侧 PE stamping 的 macho 等价物）、入口指向 shim+launcher+后端三件套的 bundle 布局；并给 mac 版产物做一个 `verify-bundle.py` 的对应校验（架构/依赖/资源齐全，替代 PE 子系统/DLL 那四项）。
  - 结果：`tgui build` Darwin 分支产出 `dist/<App>.app`——`Contents/MacOS/<App>`（shim 改名**不带点**：`stem_of()` 在第一个 `.` 截断，带点会让 conf 路径错配）、`<App>.conf`（launch 模式，html/app 用 `../Resources/…` 相对路径）、`launcher-macos`、`Resources/app/`（后端 PHP **逐字节镜像**，`__DIR__` require 链原样生效，运行依赖系统 php on PATH）、`Resources/frontend/`、`AppIcon.icns`（`sips`→iconset 10 张定名→`iconutil`；无 icon.png 时 CFBundleIconFile 整键缺席而非悬空引用）、`Info.plist`（plist heredoc，TCC 相机/麦克风/语音三用途串 + LSMinimumSystemVersion 12.0）。构建末尾自动调 `tools/verify-bundle-macos.py`（新）：layout/plistlib/Mach-O 头解析（fat+thin，主机架构硬检）/conf 按 shim 语义复析/exec 位/镜像齐全/icns/sun_path 长度；codesign 仅 `-dvv` **信息报签**不做 `--verify`（见 #20）。
  - 实测（Apple Silicon 实机）：干净重建 **verify PASS / 0 warning**；直跑 bundle 入口（清掉全部 `TYPEPHP_*` env，纯 conf 驱动）窗口正常、**13 CALL / 13 RET**、`WINDOW-E2E OK ping=pong in 51ms`、`app_kind=stock`、进程树 App→(php, launcher-macos) 全走 bundle 内相对路径；杀 launcher（= 关窗）→ shim `launcher closed`/`done`、socket unlink、`NO_PROCS`。`open` 双击等价：/tmp 副本全链路 13/13（79ms）；**本仓库卷 `demo/dist` 上 LaunchServices 实例在 `__bind` 永久挂起**（直跑同二进制正常 → 环境性限制非代码缺陷，见 #21）。
  - 边界（如实登记）：① mac 打包不做 DLL 式自包含，目标机需 php on PATH（verify 明示 warn 级事实 + README 已写）；② 不做 Developer ID/公证，链接器 ad-hoc 签名本机可跑、下载分发会被 Gatekeeper 拦（#20 记录了为什么打包级 ad-hoc 签名反而不可行）；③ 外部卷 LaunchServices `bind()` 挂起未修（发布场景在默认卷，验收已用 /tmp 副本覆盖双击路径）。
- **21d（complete，2026-09-27）Linux 侧剩余**：GTK tier 4 窗口端到端与 tier 3 `--nano` 体积测量**已在 Phase 16b-2 闭环**（tier4 PASS：14/14 帧 + 128ms marker + 截图零残留；tier3：1,160,624B / strip 987,208B、ldd 无 libphp、直跑通过），本条指针作废勿再追踪。

### Phase 22: Linux 打包/dev 方向落地（把 tier-4 的手工证据固化成产品链）
- **Status:** complete

- **动机**：Phase 16b-2/21d 只在容器里用 `test/posix/tier4-linux-window.sh` 手工编排跑通了真窗口（shim 服务端 + 原版 `launcher-linux` 客户端），但 `tgui` 在 Linux 上仍然是"走 Windows 路径然后裸 die"，也没有 `tools/build-linux.sh`。Linux 用户拿不到"一条命令构建 + 一条命令跑 + 一条命令打包"的体验。
- **设计约束（先定，别在实现时改主意）**：① **不给 `launcher-linux.cc` 打 `--typephp` 补丁** —— win 侧 dev 是 launcher 拉 shim，mac 侧 21b 移植了 `--typephp`；Linux 保持 pristine（那是 tier-4 证据成立的前提，也是"分发的 launcher 与上游逐字节一致"这条决策的延伸），dev 方向反过来由 **shim 做 AF_UNIX 服务端 + 原版 launcher 做客户端**，与打包方向同一条生命周期链；② 打包布局沿 win 的目录式（不是 mac 的 .app），entry = shim 改名**且名字不带点**（`stem_of()` 在第一个 `.` 截断），conf 驱动、全部相对路径；③ 验收环境就是现成容器 `tgl`（Debian 12 / aarch64，g++、PHP 8.4.25、GTK3+webkit2gtk-4.1、Xvfb 已就位），不再新增安装项——启动卷只剩 ~500Mi，装东西会重踩 #24。

- **22a `tools/build-linux.sh`** ✅（2026-09-27 完成）：把 tier4 脚本里已验证的两条编译行提炼成正式构建脚本——`build/backend_shell`（POSIX 分支）+ `build/launcher-linux`（GTK3 + webkit2gtk-4.1，appindicator pkg-config 双名探测 + 存在即 `-DTINYJS_APPINDICATOR`），缺依赖时给**点名缺哪个包**的失败信息而非编译器噪声。验收 = 容器内一条命令产出两个可执行 + `file`/`ldd` 摘要。
  - 结果：容器 `tgl` 内一条命令产出 `build/backend_shell`(78,352B) + `build/launcher-linux`(545,496B)，且与 tier-4 当时 `/tmp/tpgui-tier4/` 的两个产物**逐字节相同**（同工具链同 flag 的可复现证据）。`file` 显示 ELF 64-bit LSB pie / ARM aarch64；launcher 链接 171 个共享库（GTK/WebKit/libsoup/appindicator/miniaudio 单头）。appindicator 按 #23 定为**硬依赖**，用假 `pkg-config`（只对 `*appindicator*` 返回 1）验了错误路径：脚本点名 `ayatana-appindicator3-0.1` / `libayatana-appindicator3.0` 两个 pkg-config 名 + Debian 包名并 die，RC=1。
  - 附带修正：`gen-client.sh` 依赖 python3，脚本给了 **php 等价回退**（生成同一 `tiny_client.h`，含同样的 `)TINYJS` 分隔符冲突断言）；WebKit 支持 4.1→4.0 回退（Debian 11/Ubuntu 22.04）；`-lX11 -lXtst` 所需库做存在性检查。Fedora/Arch 包名**未经本机核实**，脚本里明示这点，只有 Debian/Ubuntu 名是实测过的。
- **22b `tgui status` / `tgui dev` 的 Linux 分支** ✅（2026-09-27 完成）：status 报 Linux 三件套实际路径；dev = 起 shim（`TYPEPHP_SHELL_LOG/TYPEPHP_APP/TYPEPHP_CWD` + 显式端点名）→ 拉 `launcher-linux <html> <sock> title WxH ver` → 复用 21e 已 OS 无关化的 mtime watcher（kill launcher → shim 端点 EOF 回收 PHP 子进程 → 两端一起 respawn）。验收 = 容器内 Xvfb 下出窗 + 13/13 + touch 后端 → 重启一轮。
  - 结果：`tgui dev` 在 Linux 走"shim 当端点服务端 + 原版 launcher 当客户端"，`launcher-linux` 一个字节未改（pristine 保住了）；`typephp.{backend,app}` 配置项在 mac/Linux 上统一改成"文件不存在就用平台默认"（原来的 `&& { ... }` 链式判断换成 `cfg_override`，避免空值把 `TP_ENV` 打空）；watcher 直接复用 21e 的 OS 无关循环，Linux 侧只加 `dev_spawn`/`dev_reap_shim` 两个函数。`tgui status` 在 Darwin 段之后加 Linux 段（三件套路径 + "需要 X display"提示）。`tgui build` 在 Linux 明确 die 并指向 22c，不再伪装成 Windows 路径失败。
  - 实测（容器 `tgl`，`test/posix/linux-tgui-window.sh` **PASS**）：cycle 1 `CALL=14 RET=14` + `WINDOW-E2E` marker + `shot.png` 108,958B；`touch demo/src/backend.php` → CLI 记 `sources changed — bouncing` → cycle 2 又 `14/14` + marker（帧日志按 `[shell] transport=` 头分周期）；杀 launcher（= 关窗）→ shim 自行 EOF 退出、`tgui dev` 退出、dev socket 清零。证据 `evidence/linux/22b-{shim.log,tgui.out,shot.png}`。
  - **撞出的既有缺陷（记 #25，修在 22c）**：shim 的 `io_accept` 没有超时——launcher 若在连上之前就死掉（无 X display 时 GTK 立刻退出，正是本轮第一次失败的场景），shim 会永远等在 accept，PHP 后端也白活着。dev 侧已被 `tgui` 的 5s 有界回收兜住（那次 warning 就是这么触发的），但**打包方向里 launcher 由 shim 自己 spawn，没人兜底**，必须让 shim 在 launch 模式下边等 accept 边查 launcher 存活。
- **22c `tgui build` / `publish` 的 Linux 分支** ✅（2026-09-27 完成）：`dist/<name>/` = `<name>`(shim) + `<name>.conf` + `launcher-linux` + `frontend/` + `app/{bin,src,gui/php/src}` 后端镜像（照 mac 的"逐字节镜像仓库相对路径"手法，`require ../gui/php/…` 原样生效）；构建末尾跑结构校验（ELF 头/架构、exec 位、conf 按 shim 语义复析、镜像齐全、`sun_path` 长度）；publish 出 `dist.tar.gz`（容器无 `zip` 时不冒充 zip，见 #11 教训）。**含 #25 的 shim 修法**：launch 模式下等 accept 的同时轮询 launcher 存活，launcher 先死就杀掉 PHP 并退出。
  - **打包布局**：`dist/TypePHP-Demo/` = `TypePHP-Demo`(entry，78,352B) + `TypePHP-Demo.conf` + `launcher-linux`(545,496B) + `frontend/index.html` + `icon.png` + `app/{bin/run-backend.php, src/backend.php, gui/php/src/Tiny/…}`；整目录 872KB，`publish` 出 `dist.tar.gz` 392KB。`name` 里的空格与非 `[A-Za-z0-9._-]` 字符被 `tr` 洗掉，并在**第一个点**处截断（与 shim 的 `stem_of()` 同规则），否则 `<name>.conf` 根本对不上。conf 多写一行 `icon=`：shim 在 launch 模式下把它 `setenv(TINYJS_ICON)` 后再 spawn launcher，而 `launcher-linux` 确实按这个环境变量取窗口图标（源码 1705/5821/6313 行），所以 Linux 侧图标走 conf，不需要 win 的 PE 刻录或 mac 的 icns。
  - **结构校验 `tools/verify-bundle-linux.sh`**（`tgui build` 末尾自动跑，也可单独调）：7 组检查全 PASS —— ELF 魔数 + `e_machine` 与 `uname -m` 比对（entry/launcher 各自 ELF64 aarch64）、三个 exec 位（`app/bin/run-backend.php` 的 exec 位 + `#!` 是**载荷性**的：shim 无 argv `execv` 它，且靠前 2 字节判型为 `stock`）、conf 按 shim 语义复析（stem 规则 + 逐 key 解析 + 相对路径必须落在包内）、后端镜像逐文件 `cmp`（`gui/php/src` 15 个文件一个不缺）、`app.sock` 长度 42/108、`ldd` 依赖全部可解 + 打印目标机要提供的 .so 清单（libgtk-3/libwebkit2gtk-4.1/libayatana-appindicator3…）。
  - **#25 已修**（`shim/backend_shell.cpp`）：launch 模式的 accept 换成 `io_accept_watching()` —— `poll(2)` 监听 fd（100ms 一格）与 `waitpid(launcher, WNOHANG)` 同循环，谁先到谁赢；launcher 先死 → 就地收尸（`launcher_died` 标记，避免调用方对已回收 pid 再 `kill`）、`kill_proc(php)`、`io_close(srv)` + `io_cleanup_endpoint(name)`（失败路径不再留孤儿 socket 文件）后退出。POSIX 专属：Windows 分支原样走阻塞 `ConnectNamedPipe`。顺带给 `io_accept` 补了 `EINTR` 重试（自己的子进程就会送 SIGCHLD，一次信号不该读成"launcher 永远不来了"）。
  - **实测（容器 `tgl`）**：① `tools/build-linux.sh` 重建零 warning，`launcher-linux` 与修 shim **之前逐字节相同**（pristine 前提没破）；② `tgui build` → 校验 PASS、`tgui publish` → `dist.tar.gz`；③ **#25 回归**：`env -u DISPLAY ./TypePHP-Demo` → **0 秒返回 RC=1**，shim 日志 `[shell] launcher exited (status 768) before connecting` + `launcher never connected, aborting`，`app.sock` 不存在、无残留子进程（修法前这个场景是永久挂起，只能靠 `timeout` 拔）；同一份日志顺带证明 conf 解析正确（`html/title=TypePHP Demo/size=1100x760`、`app_kind=stock`、`cwd=<exe_dir>`）。④ **dev 方向回归**：改过 shim 后 `test/posix/linux-tgui-window.sh` 重跑 **PASS**（cycle1 14/14 + marker + shot.png → touch bounce → cycle2 14/14 + marker → 杀窗全链自解）。证据 `evidence/linux/22c-{build.log,publish.log,nodisplay.log,nodisplay.out,dev-shim.log,dev-tgui.out,dev-shot.png}`。
  - 修 shim 过程中被编译器抓到的两件事：先 duplicated 了一份 accept 逻辑 → `-Wunused-function` 提醒该复用 `io_accept` 而不是平行实现；驱动脚本里把注释插在 `A=1 B=2 \` 续行与命令之间 → 赋值变成悬空命令、环境变量静默丢失（一次"看起来是产品坏了"的假失败，实际是 harness 的 shell 语义）。
  - **仍未证明的**：打包方向在**有 X display** 时真出窗（那是 22d 的 ① 项）；Windows/macOS 侧没重编（改动全在 `#ifndef _WIN32` 分支 + POSIX 专属调用点，mac 只做 `clang++ -fsyntax-only`，Windows 未编译验证）。
- **22d 端到端验收 + 回写** ✅（2026-09-27 完成）：容器内 ① 打包直跑（清掉全部 `TYPEPHP_*` env，纯 conf 驱动）≥13/13 + `WINDOW-E2E` marker + 拆除零残留；② `tgui dev` + touch → bounce 复验；③ README 验证表 + 已知限制、findings/progress 回写。**如实登记做不到的部分**：容器里是 Xvfb 无头显示，不是真桌面。
  - **验收驱动脚本 `test/posix/linux-bundle-window.sh`（新增，6 步）实测 PASS（RC=0）**：① 容器工具链在场；② `tgui build` → 结构校验 PASS → **把 `dist/` 打成 tar 解到仓库外**（`/tmp/tpgui-22d/dist/TypePHP-Demo`）后**删掉仓库内 `dist/`**，在 relocation 后的副本上重跑校验 **18 项全 PASS**；③ X 就绪用真 X client（`import -window root`）探测，不是看 socket 文件在不在；④ 直跑入口：`env -u TYPEPHP_APP -u TYPEPHP_CWD -u TYPEPHP_BACKEND -u TYPEPHP_APP_KIND -u TYPEPHP_PIPE_NAME`（只剩日志变量）+ `sh -c 'cd / && exec "$1"'` 把**进程 cwd 设成根目录**，之后断言 `env` 里没有任何 `TYPEPHP_*`/`TINYGUI_*`；⑤ 帧与接线：`CALL=14 RET=14`、`WINDOW-E2E OK ping=pong in 109ms`，日志逐条对上 `launch mode conf=<bundle>/TypePHP-Demo.conf`、`app=<bundle>/app/bin/run-backend.php`、`app_kind=stock`、`transport=unix-socket pipe=<bundle>/app.sock`、`cwd=<bundle>`、`launcher connected`，launcher pid 活着，`shot.png` 112,327B 里是真实渲染出来的 demo 窗口（截图上 `cwd` 显示 `/tmp/tpgui-22d/dist/TypePHP-Demo`，即全部路径都从 conf 与 `<exe_dir>` 推出来，没有一条靠残留 env）；⑥ 拆除：杀 launcher → 入口进程**自行退出**、`app.sock` 被 unlink、`ps` 过滤 zombie 后无残留进程。
  - **这是"自包含"目前能给出的最强证明**：仓库 `dist/` 已删、进程 cwd 是 `/`、穿线 env 全清空，产物仍跑通 —— 与 21c 的 mac 验收同一口径。
  - ② dev + touch bounce 复验在 22c 末已经重跑过（改过 shim 之后的 `linux-tgui-window.sh` PASS），22d 不重复跑，只把结论并到 README 验证表。
  - **回写**：README 打包发布段 + 验证表（Linux 打包 22c/22d 两行）+ 已知限制新增一条"Linux 打包的验收边界与前置条件"（Xvfb 无头 ≠ 真桌面：无合成器/WM/托盘；目标机需 `php` ≥8.1 在 PATH；需验证器打印的那套 GTK3/webkit2gtk-4.1/ayatana/X11+Xtst `.so`；图标走 conf→`TINYJS_ICON`；demo 页里"调用链"文案写死的是 Windows 措辞，属外观遗留非缺陷）。
  - **仍未证明的**：真桌面会话（容器只有 Xvfb）；Windows 侧没重编 shim（改动全在 `#ifndef _WIN32` 分支，Windows 打包方向由 21e/真机测试覆盖）。

## Key Questions

1. **Linux 上"小巧路线"到底多小？** → **已回答（tier 3，2026-09-27）**：`tpc --nano` 的 freestanding 产物**确实不链 libphp**（`ldd` 只有 libstdc++/libm/libgcc_s/libc），5 行程序 1.16MB（strip 后 0.94MB），php.ini/扩展 DLL 闭包全部为零。但真 nano **拒 require/匿名类/Generator/yield**，demo 那套 require 加载框架的后端入口**编不过**——"小巧"是有语法/函数面契约的小巧。详见 Phase 16b-2 结果段与 Errors #22。
2. **同一份 POSIX 分支在真 glibc/Linux 上行为一致吗？** → **已回答（tier 4，2026-09-27）：一致**。真 glibc + AF_UNIX + GTK3/WebKit2GTK 下，pristine `launcher-linux` 与同一 shim/stock PHP 后端跑通同一套帧（14 CALL/14 RET、`WINDOW-E2E OK ping=pong in 128ms`），拆除零残留。Cygwin 证不了的系统调用语义，现在证完了。
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
| 15 | 套件在技能目录里报 `socket never appeared`，in-tree 却全绿 | `$WORK/app.sock` 在技能目录下**恰好 108B** = `sun_path` 上限 → scratch 与 socket 改由 `typephp_default_work`/`typephp_socket_path` 决定位置 |
| 16 | launch 档"端点已被 unlink"的断言在分发侧**恒真** | 断言写死了 `$WORK/app.sock`，而端点名由入口自取（超长回退 `/tmp`）→ 改为从 shim 日志读回 `pipe=` 再断言 |
| 17 | macOS 上打包入口读成 `app.conf`、`execv failed` 且不给路径 | `exe_path()` 只有 `readlink("/proc/self/exe")`，**macOS 无 `/proc`** → 静默回退字面量 `"app"`（Cygwin/Linux 测不到）。修法：`__APPLE__` 分支用 `_NSGetExecutablePath`+`realpath`（语义同 Linux 的解析后物理路径）|
| 18 | Apple Silicon 正向对照"cp 一份系统二进制再跑"被 SIGKILL(137) | AMFI 拒绝字节级拷贝的系统二进制（即使签名原样）→ 常驻假进程改为**现场编译**；且新 clang 隐式函数声明即 error，探针要带 `#include <unistd.h>`（本机 `/usr/bin/sleep` 也不存在，在 `/bin/sleep`）|
| 19 | `tgui dev` 在 Windows 上 touch 后端文件不会重启（README/Phase 7 却说会） | fusion 时把 cli.js 的 watcher 搬成死代码：`watch_loop()` 定义在一次性 subshell 内（无调用者、`$child` 在别处），主循环 `wait` 后**无条件 break**；旧真机证据属被删的 cli.js → mac watcher 落地时如实改掉 README，Windows 恢复列入 21e |
| 20 | macOS 26 上对 .app 做 ad-hoc `codesign` 全线失败（Phase 21c） | 实测三条路都堵：整包 `--force --sign -` 拒绝此布局（Contents/ 下**每个文件**都被封成子组件，连 mode 644 的 App.conf 也算，conf 挪到 Contents 级仍拒）；bundle 内逐二进制 `--force --sign -` 后主执行体带"bundle 式签名"，随后对原始路径 `--verify` 报 `code has no resources but signature indicates they must be present`；先签再拷回只救得了 launcher 救不了主执行体。且被重签过的二进制会**污染后续实验**（同一 dist 里 699424B 的 launcher 让新对照失真）。结论：tgui build **移除打包级签名步骤**，二进制保留链接器 ad-hoc 签名（Phase 20/21b/21c 全靠它跑通）；verify 脚本 codesign 改 `-dvv` 信息报签，不再 `--verify`。分发签名/公证另立工作项 |
| 21 | LaunchServices（`open`）拉起的 bundle 在外部卷（`/Volumes/data`）上永久卡在 `__bind`，同二进制直跑正常 | `sample` 787/787 采样全在 `__bind`，socket 文件未创建、无子进程；拷到 /tmp 的同一 bundle `open` 后 13/13 全通 → 环境性安全层限制（GUI 上下文对非启动卷的 AF_UNIX bind），非代码缺陷。tgui 产物本身无改动；验收以"直跑（开发卷）+ open（默认卷 /tmp 副本）"双路径覆盖，README 已知限制写明发布/双击请在默认启动卷 |
| 22 | tier 3 编译 demo 后端，`--nano` 第一行就 fatal：`` `require` is not supported in nano mode ``（`src/backend.php:29`） | 真 nano 的 `NanoSyntaxValidationVisitor` 对 include/require/匿名类/yield/eval 一律拒绝（Windows nano-policy 只是策略包装、从不报这些）→ 不是 bug 而是**能力边界**：nano 发行需单文件聚合入口或 project.xml 多源输入；本轮改用 5 行 `nano_min.php` 完成体积/ldd 实测 |
| 23 | 容器内编译 pristine `launcher-linux.cc` 报 `g_indicator` 未声明 | vendor 源码自身缺陷：`can_live_hidden()`（约 6921 行）无条件引用只在 `#ifdef TINYJS_APPINDICATOR` 里声明的 `g_indicator`（1677-1679 行）→ **"可选依赖自动禁用"在上游根本不成立**，不定义宏编不过。修法（不改 vendor）：装 `libayatana-appindicator3-dev` 并恒定义该宏；注意 Debian .pc 名是 `ayatana-appindicator3-0.1`（非 Fedora 的 `libayatana-appindicator3.0`），tier4 脚本已做双名探测 |
| 24 | tier 3 环境两次堵死：`php:8.4-cli-bookworm` 镜像 881MB 下载中 ENOSPC；tpc vendor 的 phpx 2.7.0 无 `extra.typephp-native` | 启动卷常年 ~700Mi → 弃大镜像，走 **sury apt**（`packages.sury.org/php` bookworm arm64）秒装 PHP 8.4.25；nano ABI 比对（php-nano vs phpx 均 80600）要求新版 phpx → xget+unfetch(threads=1) 拉 **phpx v2.9.2 / php-nano v1.0.1** 源码包放入 `vendor/swoole/`（不动 composer 元数据，`resolveLocalPackage` 直接命中）|
| 25 | 没有 X display 时 `tgui dev` 打出 `shim still up 5s after the launcher exited — killing it`，打包方向同一场景会永久挂起 | **已修（22c，2026-09-27）**。根因：shim 的 `io_accept` 无超时也不看 launcher 死活 → launcher 在**连上之前**退出（GTK 打不开 display）时 shim 永远等在 accept，PHP 子进程白活；dev 侧只是被 `tgui` 的 5s 有界回收兜住，打包模式下 launcher 由 shim 自己 spawn、无人兜底。修法：launch 模式改走 `io_accept_watching()`（`poll` 监听 fd 与 `waitpid(launcher,WNOHANG)` 同循环，launcher 先死就收尸 + 杀 PHP + 清 socket 文件后退出），POSIX 专属，Windows 分支不变。实测 `env -u DISPLAY ./TypePHP-Demo` → **0s / RC=1**、日志 `launcher exited (status 768) before connecting`、`app.sock` 与子进程零残留（见 `evidence/linux/22c-nodisplay.*`） |

详细根因、复现与修法见 `progress.md` 对应 session 条目与 `findings.md`。

## Notes

- 每个阶段完成后，把它的 Status 行改成 `complete`，并在 `progress.md` 追加一条 session 记录。
- **`phase-status.sh` 只认纯整数阶段号**，所以 `16a`/`16b-1`/`16b-2` 这三个阶段的 Status 需要手工改（或 `sed`）。`check-complete.sh` 不受影响 —— 它只数字面量，不做整数解析。
- 正文里**不要原样写出那两个被统计的字面量**（见开头的格式说明），否则阶段总数会被高估、进度百分比失真 —— 本文件第一次整理时就踩过：因为要"说明格式"而写出了字面量，结果被读成 25/21 而不是 21/20。改完务必用开头那两条 `grep` 自检。
- 每次重大决策前重读本文件（把目标重新拉回注意力窗口）。
- 所有错误都要记进 `Errors Encountered` —— 它们是这个项目最贵的资产。
- 外部内容（网页/API/搜索结果）只写进 `findings.md`，**不要**写进本文件。
- **未跑通的部分必须显式标注**，不要用猜测冒充验证（Phase 16b-2 就是为此单独留着一个 `pending`）。
