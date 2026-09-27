# 进度日志 — launcher-win.cc 集成

## 2026-09-25 session 1
- 16:51 用户通过 planning-with-files 技能要求：把 launcher_bridge.cpp 真正并入 launcher-win.cc 做窗口联调。
- 环境扫描：tinyjsapp 未克隆；launcher-win.cc 已在 /D/Temp；webview 仅有 fork 版。
- 新建规划三件套（task_plan.md / findings.md / progress.md）。
- 下一步：后台克隆 tinyjsapp + 前台分析 launcher 真实 spawn/IPC/协议代码。

## 2026-09-25 session 2（用户下载 tinyjsapp-0.42.0 完整源码到 D:/git/web/tinyjsapp-0.42.0）
- 拿到完整仓库：launcher-win.cc(306KB)、runtime(tiny.js/bridge.js)、native/include(webview.h+miniaudio)、setup.ps1(MinGW g++ 构建 + 下载 WebView2.h + 生成 tiny_client.h)。
- **真实补丁已落地到 `D:/git/web/tinyjsapp-0.42.0/native/launcher-win.cc`**（原文件备份 `launcher-win.cc.orig.bak`）。四段 Hunk A–D 全部应用并 `diff -u` 校验一致：① 全局变量 g_typephp/g_backend_proc + 前向声明；② `run()` 前识别 `--typephp` 并左移 argv；③ 连接循环前 spawn 后端；④ 新增 `spawn_typephp_backend()`/`terminate_typephp_backend()`（含 atexit 清理）。
- **关键修正（实测）**：PHP 8.5.11 与 aot-compiler 0.9.3 的 libphp **均不支持 `pipe://` 命名管道服务端**（`stream_socket_server("pipe://...")` 报错）。原设想"PHP 后端直接建管道"不可行。改为 **C++ shim 架构**：launcher spawn `backend.exe`(shim) → shim 建命名管道 + 继承 stdio spawn `app.exe`(PHP/aot) → 双向字节透传。launcher 补丁零改动。
- **headless 端到端实测打通**：`planb/spawn_bridge_test.cpp`(含与补丁逐字一致的 spawn 逻辑) + `planb/backend_shell.cpp`(shim) + `php _run_backend.php` 联跑，launcher 侧 spawn→连接管道→`CALL window.create`→经 shim→PHP 回 `RET`，打印 `[test] PASS`，exit 0。
- 补齐构建依赖：`setup.ps1` 缺失的 `native/include/WebView2.h`(从 nuget v3 下载 1.0.2903.40 提取) 与 `native/tiny_client.h`(本地由 runtime/tiny.js 生成) 均已生成，`-fsyntax-only` 仅因缺 Windows SDK WRL 头(`windows.data.xml.dom.h`)未能全量编译——此为该 launcher 自身的构建要求，与补丁无关。
- 产物：补丁源码(已改) + `planb/backend_shell.cpp` + `planb/spawn_bridge_test.cpp` + `planb/_run_backend.php` + 更新 `planb/launcher_typephp_patch.md`(含 shim 架构与构建步骤)。
- 下一步/未竟：真实 WebView2 窗口渲染需用户在带显示会话+WebView2 运行时验证；aot-compiler 把 backend.php 编成 app.exe 需在用户环境跑 `tpc.exe backend.php -o app.exe` 验证。

## 2026-09-25 session 3（用真实 aot-compiler 后端跑通全链路）
- **纠正 session 2 的误判**：那次「全链 PASS」其实是 `dummy_backend.exe`（`spawn_bridge_test` 硬编码覆盖了 TYPEPHP_BACKEND，回复里的 "echo" 露馅）。真 shim 从未被端到端跑过。已修测试改用环境变量。
- **用 tpc v0.9.3 编出真实 `app.exe`**（bin 模式，MSVC via `build_app.bat`/`build_all.bat`）并替换 stock php。修了 backend.php 两个真 bug：
  1. **RET 缺 status**：launcher `do_reply`（launcher-win.cc:4601）期望 `RET <id> <status> <json>`（status 0=ok）；原后端输出 `RET <id> <json>` → 被 launcher 解析丢弃。已修为 `RET <id> 0/1 <json>`。
  2. **未 flush 导致 hang**：stdout 为管道时 C stdio 块缓冲，小帧不送达 → 对端读阻塞。已在 backend.php 加 `emit()`（每帧后 `fflush(STDOUT)`）。
- **shim 死锁根因**：`backend_shell.cpp` 原用双线程（launcher→php / php→launcher）双向 pump，实测在命名管道 `WriteFile` 上**永久阻塞**（6/31 字节小写也卡，且此时对端读到 EOF/`ERROR_BROKEN_PIPE`），与缓冲无关。改为**单线程、按行分帧代理**（读 CALL 行→转发→读 RET 行→回写）后彻底解决。
- **headless 全链路 PASS（真实 aot 后端）**：`spawn_bridge_test`(模拟 launcher) → spawn `backend_shell.exe`(单线程 shim) → spawn `app.exe`(tpc v0.9.3)；交换 `CALL 1 {"method":"api.sum","params":{"a":3,"b":4}}` → `RET 1 0 {"ok":true,"result":7}`，`[test] PASS` exit 0。
- 部署脚本 `planb/build_all.bat`：`g++` 编 shim + `tpc` 编 app.exe；注意本机 ambient `PHP_HOME` 指向 v0.9.0，已用 `TPC_HOME` 强制 v0.9.3。
- 调试要点（沉淀）：launcher 用 `CREATE_NO_WINDOW`+`bInheritHandles=FALSE` spawn shim → shim 无控制台、stdout 丢弃 → shim 诊断改用 env `TYPEPHP_SHELL_LOG` 写文件；Git Bash 会吞 argv/环境变量里的反斜杠（`\\.\pipe\` 变 `\.\pipe\`）→ 手工测试用裸名 env `TYPEPHP_PIPE_NAME` 由 shim 自己拼前缀。
- 仍未验证：真实 WebView2 窗口渲染（需带显示会话 + WebView2 运行时）。

## 2026-09-25 session 4（真实窗口联调 PASS —— launcher 编译成功 + 双向帧打通）
- **launcher-win.exe 编译成功**（1.87MB, PE32+ GUI, rc=0）。破局点：MinGW-Builds 13.2.0 的 WinRT *基础*头是空壳 → 把 mingw-w64 上游完整头放 `native/winrt-shim/` 并用 **`-I`** 置于本机系统头之前（`-idirafter` 会让空壳头胜出，是上一轮 41 个报错的主因）；随后脚本化自动补齐传递依赖头（windows.storage.fileproperties / windows.storage.search / windows.devices.geolocation / windows.ui.input / windows.devices.input / windows.system 等），报错 41 → 0。构建命令：`g++ -std=c++17 -O2 -static -Inative/winrt-shim -Inative/include -Inative -o native/launcher-win.exe native/launcher-win.cc -mwindows -lole32 -loleaut32 -lshell32 -lshlwapi -luser32 -ladvapi32 -lversion -lgdi32 -lgdiplus -lcomdlg32 -lwinmm -ldwmapi -luuid -lcrypt32`
- 环境确认：WebView2 Runtime **148.0.3967.54 已装**，SessionId=1 + explorer 运行 → 可做真实窗口。Cygwin 无用（其 mingw sys-root 只有 zlib/openssl，无 WinRT 头；其 g++ 是 Cygwin 原生非交叉编译器）。
- **重写 `backend.php` 对齐真实 tinyjsapp 契约**：`CALL <id> ["<payload>","<origin>"]`（payload 是 JSON 字符串），返回 `RET <id> <status> <json>`；窗口类命令（win.setTitle/win.setSize/quit）**先发 `TITLE`/`SIZE`/`QUIT` 帧再 RET**。实现 ping/sysinfo/listDir/win.setTitle/win.setSize/quit/store.*/api.{version,sum,sha256,fib,now}。
- **修 bug 2：launcher argv off-by-one** —— `--typephp` 原左移整串 argv，使 `title = argv[3]`（尺寸串）。改为只覆盖 flag 槽 `argv[1]=argv[2]`；窗口标题现为 "TypePHP Demo"（正确）。
- **修 bug 3：shim 死锁** —— 单线程“读一帧→等 RET”模型会被 launcher 的**通知帧**（WINSTATE/NAV/SYS）卡死（后端不回 RET），后续 CALL 永远读不到。症状：页面 probe `typeof __invoke=function` 但后端零 CALL。改为**双向 PeekNamedPipe 非阻塞轮询泵**（各方向独立 partial 行重组，Sleep(1) 空闲节拍，无线程）。
- **修 bug 4：tpc 拒绝顶层裸语句** —— 删掉 `main();`（tpc 自动调用名为 `main` 的入口函数）。tpc v0.9.3 重新编出 app.exe（108032B）。
- **真实窗口联调 PASS（双向）**：`www/index.html` 自测页 + `grab.py`（ctypes GDI 截屏 + 纯 zlib 手写 PNG，规避 Add-Type/Pillow 皆不可用）。证据见 `_shim_win.log` + `_launcher.err` + `e2e-window-ok.png`：
  - 页面→后端：ping→"pong"、sysinfo→`{"runtime":"PHP 8.5.11",...,"backend":"aot-compiler (tpc) AOT native"}`、api.fib(40)→102334155、api.sha256→a817a2f2…、api.sum(1..100)→5050、listDir D:\Temp→真实目录项；首帧往返 257ms。
  - 后端→launcher：点“改标题”→ 后端发 `TITLE TypePHP 已接管标题` → 窗口标题真的变了；点“放大”→ 发 `SIZE 1200 800` → 窗口从 976x679 变 1216x839。
- 诊断技巧沉淀：launcher 是 `-mwindows` GUI 进程，用 shell `2>file` 重定向 **能**收到 `TINYJS_LAUNCHER_DEBUG=1` 的 stderr（`launcher: CALL …`）；shim 因无控制台用 `TYPEPHP_SHELL_LOG` 写文件；`Add-Type` 被安全策略禁止 → 截屏改用 ctypes。

## 2026-09-25 session 5（协议保真 + 一键可复现构建）
- **后端补 `client.hello`**：launcher 启动时必发 `client.hello`（bridge.js 的 `API_ALWAYS` 之一，真实实现就是 `return true`）。之前返回 `unknown method: client.hello`。现返回 true。
- **通知帧改走 EVAL 推送，不再写 stderr**：shim 把子进程 stderr 并进 stdout（`si.hStdError = hWriteStdout`），所以后端写 stderr 的"note:"会被转成帧发给 launcher（无害但脏）。现按 bridge.js 语义解析通知帧并转成 `EVAL@* window.__emit && window.__emit({"event":..,"data":..})`：
  - `WINSTATE <win> <json>` → event `window-state`（data 含 `win`）
  - `SYS theme light|dark` → event `theme {dark}`
  - `SYSLOCALE <json>` → event `locale`
  - 其余（NAV/MENU/TRAY/DROP/HOTKEY/GOT/…）静默忽略
  - 转义必须与 bridge.js 的 `esc()` 逐字一致（`\`→`\`、tab/CR/LF→`\t`/`\r`/`\n`），launcher 的 `wire_unescape` 是其逆运算。
- **发现并解决的时序问题（重要）**：`WINSTATE` / `SYS theme` 在页面 **导航之前**就到达（日志顺序：WINSTATE → SYS theme → NAV start → NAV commit → client.hello），此时页面还没注册处理函数 → 推送**必然丢失**。真实 bridge.js 正是为此缓存 `lastTheme`/`lastLocale`。已对齐：PHP 侧加 `TinyState` 静态类缓存，页面用 `theme.get` / `system.locale` / `win.getState` 拉取初始值；推送只用于后续变化。
- **一键构建脚本 `planb/build_launcher.sh`**：自动补齐 23 个 winrt-shim 头（多镜像回退 xget→raw.githubusercontent→jsdelivr）、按需下 WebView2.h（nuget）与生成 tiny_client.h（python 包 raw string）、用 `-I native/winrt-shim` 编译 launcher、并部署 `backend.exe`/`app.exe` 到 native/。已实测跑通。
- **实测（AOT app.exe + 真实窗口）**：`client.hello`→`RET 0 true`；`theme.get`→`{"dark":false}`；`win.getState`→完整状态；`系统 locale`→`null`（本机 launcher 未发 SYSLOCALE）；**0 个 unknown method、0 条 stderr 噪声**。窗口事件面板显示 6 条：2 条 `[推送]`（含 minimize/restore 的 `minimized:true`→`false`）+ 3 条 `[拉取]`。截图 `planb/e2e-window-events.png`。
- **踩坑备忘**：`backend.php` 里**不能**有顶层 `main();`（tpc 要求所有执行代码在函数内，入口函数名 `main` 由 tpc 自动调用）。因此用 **stock PHP** 手工测试时必须经 `php _run_backend.php`（包装器里 `require` + `main();`），直接 `php backend.php` 会静默无输出。
- 事件触发技巧：`winstate.py` 用 `ShowWindow(SW_MINIMIZE/SW_RESTORE)` 制造真实 WINSTATE 转换，从而验证 EVAL 推送通路，且不修改任何用户设置。

## 2026-09-25 session 6（launcher 原生应答帧类：DLG + 菜单全通）
- **`DLG` 帧 = launcher 自己应答、后端不发 RET**。这是最容易写错的一类：bridge.js 在 `handleCall` 里对 dialog 方法**短路**——`send('DLG …')` 后直接 `return`，页面 promise 由 launcher 的 `route_ret` 解析。后端若照常回 RET 就会双解析；若 shim 按"等 RET"实现就会永久卡死。实测确认：`DLG` 发出后无 RET，后续 CALL/事件照常流动 → 非阻塞泵设计正确。
  - 帧格式：`DLG <id> <op>\t<args...>`；op ∈ `open|openmulti|dir|save|alert|confirm|prompt`
  - `alert`: `[msg, detail, ok]`；`confirm`: `[msg, detail, ok, cancel]`；`prompt`: `[msg, default, ok, cancel]`
  - 文件类：`[open, extList]`，`extList` 必须同 bridge.js：去点、小写、`^[a-z0-9][a-z0-9+._-]*$` 过滤、逗号连接（实测 `["png","jpg","md","txt"]`→`png,jpg,md,txt`）
  - 文本字段一律过 `one()`（tab/CR/LF→空格），因为帧是换行分隔的
- **菜单是整块多帧**：`MENUBEGIN[@win]` → `MENU <title>` → `ITEM <id>\t<label>\t<key>\t<flags>` / `SEP` / `SUB…SUBEND` / `ROLEITEM <role>` → `MENUEND`。flags = `c`(checked)+`d`(disabled)。launcher 在 MENUEND 时重建 Win32 菜单栏。
  - **注意**：重置只有子窗口的 `MENURESET@<win>`，**没有裸 `MENURESET`**；要清空 app 菜单就再 `menu.set` 空列表。
  - 主窗口入口是 `menu.set`（`tiny.menu.set` → `call('menu.set')`）；`win.menu.set` 是单窗口覆盖。
- **`MENU <id>` / `TRAY <id>` / `TRAYCLICK` 通知** → 转成页面事件 `menu`/`tray`/`trayclick`（bridge.js 的 `push('menu',{id})`），这样 `tiny.menu.on(fn)` 才有反应。
- **非交互验证原生 UI 的钥匙：`TINYJS_TEST_AUTODLG=ok`**。launcher 的 `autodlg_arm()` 会轮询本进程的 modal `#32770` 并按 `IDOK`/`IDCANCEL` 点掉，于是文件对话框/MessageBox/prompt 全都能无人值守跑完。
- **实测链路（真实窗口）**：菜单栏渲染出「文件 / 帮助」→ 点菜单项 → launcher 发 `MENU open` → 后端转 `EVAL@* menu {id:'open'}` → 页面处理函数 → `tiny.dialog.openFile` → 后端发 `DLG <id> open\tpng,jpg,md,txt` → launcher 原生文件对话框 → 返回 `null` 回页面（页面显示 `openFile → null`）。alert/confirm/prompt 全部走通，`prompt` 返回默认值 `tiny`。
- 单次会话覆盖 **8 类帧**：CALL(19) RET(15) EVAL(13) WINSTATE(10) MENU(4) ITEM(4) DLG(4) + SIZE/SYS/NAV。
- **脚本坑**：截图/点击脚本里不要调 `ShowWindow(hwnd, SW_RESTORE)` —— 它会把窗口恢复成"出厂尺寸"（把 SetWindowPos 的结果冲掉），导致坐标漂移。用 `SetForegroundWindow` 就够。已修 `grab.py`/`click.py`；新增 `movewin.py`（把窗口摆到确定位置）。
- 证据：`planb/e2e-dialogs-menu.png`、`planb/e2e-dialog-openfile.png`、`planb/e2e-dialogs-menu-frames.log`。

## 2026-09-25 session 7（接进 `tinyjs dev` CLI —— "日常可用"）
- `cli.js` `cmdDev()` 新增 TypePHP 分支（`--typephp` / `TINYJS_TYPEPHP=1`）：**跳过 `generateBuild()`**（它会 `resolveBackendEntry()` 并在无 `src/main.js` 时 fail），直接 `tjs.spawn([launcher-win.exe, '--typephp', <html>, title, size, version])`。文档解析优先级 `devUrl` > `cfg.url` > `src/frontend/index.html`；`tinyjs.json` 可加 `"typephp": {"backend":…, "app":…}`（项目相对，可省）。
- 走 xget 下载 txiki.js 运行时 `bin/tjs.exe`（v26.6.0）才能跑 CLI。
- **新坑：launcher 启动即 `SetCurrentDirectoryW(GetTempPathW())`**（原有设计，注释：不能把 cwd 钉在 app 目录，会阻塞自动更新换目录；orig.bak 亦有）→ shim/PHP 继承到 `getcwd()==D:\Temp`，相对路径全废。修复：CLI 注入 `TYPEPHP_CWD=tjs.cwd`，shim 用作 `CreateProcessW` 的 `lpCurrentDirectory`。修复后 `sysinfo.cwd` 正确，目录浏览读到真实项目文件。
- 热更新：`src/**`（非 frontend）→ `restarting backend`；`src/frontend/**` → `reloading window`（TypePHP 链路无 JS 进程，CLI 对 launcher 唯一杠杆是生命周期）。实测两次重启 PID 全换新且仍各 1 个进程（无泄漏）；WM_CLOSE 关窗后 shim `launcher closed`→`done`、CLI 退出、tasklist 零残留。
- 实测帧统计：**13 CALL / 13 RET 完全配对**，2 条 EVAL 推送，1 个菜单块，0 错误。截图 `planb/e2e-dev-cli.png`。
- 新增自包含参考项目 `planb/demo-app/`（`tinyjs.json` + `src/frontend/index.html` + `src/backend.php` + `backend/app.exe` + `build.bat` 一键重建）。

## 2026-09-25 session 7b（分发依赖：`app.exe` 非自包含）
- `objdump -p` 查出 tpc `bin` 产物依赖 `php8ts.dll`(13.5MB) + `phpx.dll` + `libmpdec{,++}-4.0.1.dll` + `gmp-10.dll` + `mpfr-6.dll` = **15.5MB**，外加 MSVC 运行时。本机此前"能跑"是因为 PATH 上恰好有 tpc —— 还是 **v0.9.0**，版本不匹配。
- 修法：6 个 DLL 拷到 `app.exe` 同目录（Windows 对非 KnownDLL 优先查 exe 所在目录）。已固化进 `demo-app/build.bat` 步骤 [3/4]；闭包用递归 `objdump` 解析（脚本 `scripts/deps-dlls.py`）。
- 验证：把 PATH 里的 tpc 整个剥掉，`tinyjs dev --typephp` 仍全链路 PASS（截图 `e2e-dev-cli-cleanpath.png`）。

## 2026-09-25 session 8（nano 修复后能否走"小巧路线" —— 实测否定）
- 用**修复分支的源码 tpc**（`php bin/tpc.php --nano`，非预编译 tpc.exe）编 `planb/backend.php`，与 bin 逐项对比（产物 `planb/nanotest/`）：

  | | `--nano` | `bin` |
  |---|---|---|
  | exe（5 行程序） | 48,640 B | 54,272 B |
  | exe（backend.php） | 301,056 B | 305,664 B |
  | 依赖 | php8ts/phpx/libmpdec* | **完全相同** |
  | 链接指令 | phpx.lib php8ts.lib php8embed.lib gmp mpfr libmpdec* | **逐字相同** |
  | 退出码 | **139 (SIGSEGV)** | 0 |

- 根因：`NanoBuildBackend::forHost()` **硬编码** `Windows → WINDOWS_DLL`（src/Build/NanoBuildBackend.php:14-17）→ Windows 永远不是 `COMPOSER_SOURCES`，`--nano` 只是 bin + 策略。体积省 1.5%，代价是崩溃 + 额外禁 exec/proc_open/system → **严格更差**。
- teardown SIGSEGV 用 5 行程序 `nano_min.php` 复现（nano 崩、bin 干净）→ 是 nano-policy 路径固有缺陷，与本后端无关。
- **纠正上一轮的错判**：我曾推测"Linux/macOS 上 PHP 可直接服务 launcher 的 unix socket，不需要 shim"——**错**。证据：`vendor/swoole/php-nano/SUPPORTED.md` 明言 "Socket capability remains absent **even on POSIX hosts**" 且 "Windows **deliberately** uses the complete PHP/PHPX DLL runtime instead of php-nano"；`REMOVED.md` 移除 "socket transports, …, processes, shell execution…"；`CompilerBase.php:951` 对 `NANO_UNSUPPORTED_FUNCTIONS` 里的 `stream_socket_server`/`getenv`/`gethostname` 直接 `fatalError`（**编译期**）。
- 另一处关键：`CompilerBase` 的 `NANO_UNSUPPORTED_FUNCTIONS` **只在 `isNanoMode()` 时才应用**（源码注释：Windows Nano 只用完整 PHP/PHPX DLL，只应用 common policy；php-nano 的小宿主面仅 Unix/WASI）→ 解释了为何我们的后端（用了 `getenv`/`gethostname`）在 Windows nano 能编过、在真 nano 会编不过。
- 结论：**shim 跨平台必需**（Windows 缺 transport；nano 任何平台都无 socket API；POSIX bin 能服务 socket 但已不小巧）。Linux 的收益是"shim + 真 freestanding nano"的体积（无 libphp），不是免 shim。
- 文档更新：`aot-compiler-nano-fix.md`（复测表）、`planb/PLANB_LANDING.md` §六（含更正）、两个技能（`aot-compiler-windows-build` 新增 fact #7 双清单；`tinyjsapp-typephp-bridge` 更正 shim 必要性）。

## 2026-09-25 session 9（`tinyjs build --typephp` —— 可分发）
- **设计要点：打包版不需要 `--typephp` 补丁。** 让 shim 兼任"应用入口"（新增 `--launch` 模式；无参数时默认启用，因为 dev 路径**总会**传管道名，`argc==1` 不会冲突），由它走上游**原生方向**（Plan A）：入口自己建命名管道 → spawn **原版** launcher `<html> <pipe> <title> <WxH> <ver>` → spawn PHP → 双向泵。
  - 好处：分发的 `launcher.exe` 是**未修改的上游二进制**，`--typephp` 降级为 `tinyjs dev` 的便利补丁，减少长期维护面。
  - 细节：spawn launcher 必须 `bInheritHandles=FALSE`，否则 launcher 会持有 shim 的 child-stdio 管道端 → PHP 永远读不到 EOF。
  - 配置：`<exe_dir>/<exe_stem>.conf`（行式 `key=value`，`#` 注释，相对路径按 exe 目录解析）。**故意不用 JSON** —— C++ 侧不需要解析器。键：`html/title/size/version/icon/app/launcher`。
- **`cli.js` 新增 `cmdBuildTypephp()`**：`cmdBuild()` 在 `typephpEnabled()` 时短路调用。跳过 `generateBuild()` 与 `tjs app compile`。产出 `dist/`：`<name>.exe`(shim 改名) + `launcher.exe`(原版) + `app.exe`(PHP) + 6 个 DLL + `frontend/` + `<name>.conf`（+ `icon.png`）= **18MB**。
  - `tinyjs.json` 的 `"typephp"` 支持三个键：`build`（shell 钩子，与 `frontend.build` 同构，用于让用户自带 tpc/MSVC 编译）、`app`（编译好的 PHP 后端，默认 `backend/app.exe`）、`dlls`（DLL 来源目录，默认取 `app` 同目录）。
  - 找不到 DLL 时只 WARNING 并说明后果（会在干净机器上跑不起来 / 静默加载 PATH 上的不匹配版本）。
- **实测**：
  - `planb/dist-test/` 手工布局首跑 PASS（证明设计与 cli 无关也能用）。
  - `tinyjs build --typephp`（demo-app）一条命令完成 shim + PHP + DLL + 组装；加 `typephp.build` 后连 tpc 编译一起跑通。
  - 构建产物双击运行：13 CALL/13 RET、`cwd` = dist 目录、标题/尺寸/版本正确、菜单栏正常、关窗后 launcher/app/entry **零残留**。
  - **dev 回归**：13 CALL/13 RET，未误入 launch 模式 → shim 改动对 `tinyjs dev --typephp` 无影响。
  - 截图 `planb/e2e-packaged.png`（dist-test）、`planb/e2e-build-typephp.png`（build 产物）。
- 待办：Phase 16/17（Linux + AF_UNIX shim + 真 nano）需要 Radeon Cloud 环境；`tinyjs publish --typephp`（打 zip/签名/图标 stamping）未做。

## 2026-09-25 session 10（Phase 17 合规化 + Phase 16a shim 跨平台化）
- **Phase 17（backend.php 的 nano 合规）**：`sysinfo` 去掉两个**真 nano 会编译期 fatalError** 的调用
  —— `gethostname()` → `php_uname('n')`；`getenv('USERPROFILE')?:getenv('HOME')` →
  `$_SERVER/$_ENV` 超全局链。核验要点：① `php_uname` 不在两份禁用清单、也不匹配任何禁用前缀；
  ② **`$_SERVER` 必须优先**（PHP CLI 的 `variables_order` 默认不含 E，实测 `$_ENV` 为空、
  `$_SERVER['USERPROFILE']` 有值）；③ 全文件对禁用清单复审计 **0 命中**；④ Windows 重建后
  `host`/`home` 取值**不变**。→ 依据：这份清单只在 `isNanoMode()` 时生效（两级早退），
  所以"Windows 编得过"从来不能证明"真 nano 编得过"。
- **Phase 16a（shim 跨平台化）**：`planb/backend_shell.cpp` 重构为**单文件双平台** —— 抽象边界是
  `io_t`（Windows HANDLE / POSIX fd）+ 一组原语（endpoint 创建/accept、非阻塞读、写、清理、
  spawn、kill），**帧泵/行重组/conf 解析/路径处理全部零分支共享**。
  - POSIX 传输：`socket(AF_UNIX)+bind+listen+accept`，socket 路径对齐 `bridge.js` 的
    `<workDir>/app.sock`（bind 前 unlink 陈旧文件、退出再 unlink；过长回退 `/tmp/...`）。
  - POSIX 泵：`poll(fd,0)` + 阻塞 `read` —— socket 与 pipe **同一套代码**（poll 报可读即不阻塞，
    `read()==0` 即 EOF）。
  - POSIX spawn：`fork+dup2+execv`，所有自建 fd 一律 `FD_CLOEXEC`（dup2 自动清目标 fd 标志）
    → 等价 Windows 侧 `bInheritHandles=FALSE`；`SIGPIPE` 忽略；退出 `SIGTERM`→(50×10ms)→`SIGKILL`+`waitpid`。
- **e2e 抓出一个真 bug（关键 bug #8）**：重构时把**子进程 stdin 的管道方向写反**（返回的是
  `(read,write)`，但 stdin 要的是"子进程读、父进程写"）→ 父进程拿读端 `WriteFile` 直接失败、
  子进程拿写端当 stdin 立刻 EOF。**现象很有欺骗性**：`P->L` 方向照常发出 `READY`，只有 `L->P`
  全空 → 症状是"窗口根本不出现"。`-Wall` 零警告。修好后全绿。
- **实测（Windows 侧零回归）**：
  - `tinyjs dev --typephp`：**13 CALL / 13 RET**、0 错误、0 unknown method；`sysinfo` 取值
    `host=DESKTOP-KO73F8K`、`home=C:\Users\Administrator`、`cwd` 正确；关窗序列
    `launcher closed`→`closing`→`done`，**零残留进程**。截图 `planb/e2e-dev-regress.png`。
  - 打包版 `demo-app/dist/TypePHP Demo.exe`（换上**新 shim + 新 app.exe**）：launch 模式 conf 读取
    正常、**13 CALL / 13 RET**、`spawned launcher=1`、0 错误、`cwd` = dist 目录；关窗零残留。
    截图 `planb/e2e-packaged-regress.png`。
- **重要限制（决定了 Phase 16b 必须在远端做）**：本机**无法编译 POSIX 分支** ——
  MinGW g++ 没有 `fork`/`execv`；MSYS2 只装了 mingw/ucrt/clang 工具链（`usr/bin` 无 g++、
  无 `sys/un.h`）；Docker Desktop 只留安装日志、**无 `docker` CLI**；WSL 仅一个 Stopped 的
  `docker-desktop` 工具发行版。→ 本地能保证的上限是"Windows 零回归"，POSIX 分支的正确性
  只能靠远端一次编译+运行验证。
- 待办：**Phase 16b**（Linux 真机：编译 POSIX shim + 真 freestanding `--nano` 后端 + `launcher-linux`
  全链路，量真实分发体积）；`tinyjs publish --typephp`（zip/签名/图标 stamping）未做。

## 2026-09-25 session 11（Phase 16b：远程阻塞 + 验证套件落地）
- ⛔ **阻塞**：`rc doctor -y` → `[FAIL] ssh alias 'radeon-cloud' defined`（"no Host block for
  'radeon-cloud' resolves"）。本机**没有配置该 ssh 别名** → 远端 Ubuntu 盒子不可达 →
  **Phase 16b 无法执行**。这是**用户侧前置条件**（需从 AMD Radeon Cloud 控制台取
  HostName/User/Port 写进 ssh config，见 `radeon-cloud` 技能里的官方指引），不猜测、不代填。
- 同时确认"在本机另辟蹊径取得 POSIX 编译器"全部堵死：MinGW 无 `fork/execv`/`sys/un.h`；
  MSYS2 只装了 mingw/ucrt/clang 工具链（无 msys g++）；Docker Desktop 无 `docker` CLI；
  WSL 只有 stopped 的 `docker-desktop` 工具发行版。**另外实测 Windows 版 Python 没有
  `socket.AF_UNIX`** —— 连"用 Python 模拟 AF_UNIX 端点"都做不到。
- ✅ **交付 `planb/posix-test/`** —— 把 Phase 16b 从"到远端从零搭环境"压缩成"**一条命令**"：
  - `run.sh`：5 步 —— ① fixture 自测 ② 用 `-Wall -Wextra` 编译 POSIX 分支
    ③ 起 shim 并确认 AF_UNIX 监听 socket 出现 + 日志自报 `transport=unix-socket`
    ④ 交错帧交换 ⑤ 收尾断言（shim 自行退出 0 / 日志有 `launcher closed` / socket 文件已 unlink）。
    **不需要 GTK+webkit2gtk、不需要显示、不需要 PHP AOT 工具链** —— 隔离出的正是唯一真实风险
    （AF_UNIX 端点 + poll/read 泵）。开头 `case $(uname -s)` **拒绝在非 POSIX 主机运行**（exit 2），
    因为 Windows 上 shim 会编译 `_WIN32` 分支并服务命名管道，断言会以错误理由失败。
  - `mock_launcher.py`：AF_UNIX 客户端，**把通知帧（WINSTATE/SYS）与 CALL 交错发送** —— 请求/响应
    耦合的代理会在这里死等，正是 Windows 侧换轮询泵之前踩的那个死锁。
  - `mock_backend.py`：shebang 脚本充当后端。注意 shim 是以**零参数** spawn 后端的，所以 POSIX 下
    "带 shebang 的可执行脚本"就是合法后端（内核处理 shebang），而 Windows 下必须是真 exe ——
    这也是本套件只在 POSIX 成立的根本原因。写帧用 `sys.stdout.buffer`（裸字节，平台无关）。
  - `selftest_fixtures.py`：**全平台**验证 oracle 自身 —— monkeypatch `socket.socket` 成走
    `mock_backend.py` stdio 的假对象，再用 `runpy` 执行**真的** `mock_launcher.py`，
    于是 oracle 的解析/断言被真实执行且不需要 AF_UNIX。
  - `README.md`：四档渐进（mock → 真 PHP → AOT `--nano` 量体积 → 真 `launcher-linux`），
    并给出各档的确切命令。
- 🐛 **fixture 自测抓到真 bug**：`mock_backend` 原来用 text-mode `sys.stdout` 写帧，Windows 上 `\n`
  被翻译成 `\r\n` → oracle 拿到 `'READY\r'` 判 FAIL。改用 `sys.stdout.buffer` 写裸字节；
  假 socket 里补上 shim 的 CRLF→LF 归一化（shim 的泵会 pop 行尾 `\r`）以保持 oracle 严格。
  另外修掉自测自身的一个 hang：oracle 早退时不 `close()` → 后端永远阻塞在 `readline()` →
  解释器退出挂住（实测 `timeout 60` 触发、退出 124）。现在无论成败都显式回收子进程。
- 本地实测：`python selftest_fixtures.py` → **`FIXTURES OK`**（banner ok、5 CALL → 5 RET、
  5 EVAL 帧、exit 0）；`bash -n run.sh` 通过；`./run.sh` 在 MINGW64 下**干净拒绝**（exit 2）。
- 待办：**Phase 16b 需用户先配好 `radeon-cloud` ssh 别名**（配好后 `rc doctor` 应能走到 GPU 检查，
  然后 `rc push planb/posix-test /workspace/posix-test` + `rc exec -- bash /workspace/posix-test/run.sh`）；
  `tinyjs publish --typephp`（zip/签名/图标 stamping）未做。

## 2026-09-25 session 12（Phase 19：`tinyjs publish --typephp` —— 可分发 zip + 清单）
- **先看清楚"白送"的部分**：`cmdPublish()` 本来就调 `cmdBuild()`，而 `cmdBuild()` 已在
  `typephpEnabled()` 时短路到 `cmdBuildTypephp()` —— 所以打包动作与 `manifest.json` 几乎不用改，
  真正要补的是**"产物到底能不能发给别人"**。
- 🐛 **修出货级 bug #10：入口是 console 子系统**。入口 exe 由项目自带 build hook 用 g++ 编，
  MinGW 默认 **CUI** → **双击**会全程挂一个黑框控制台窗口（此前都从 shell 起，看不见）。
  新增 `forceGuiSubsystem()`：读 PE 头把 `OptionalHeader.Subsystem` 3→2，**只改一个 16 位字段**
  （`peOff+24+68`），其余字节不动。**放在 `cmdBuildTypephp` 最后** —— 图标嵌入会重写整个 PE。
  实测：`tinyjs build --typephp` 打印 `entry: PE subsystem console -> GUI (no console window on double-click)`。
- **图标 stamping**：`.conf` 的 `icon=` 只管运行时窗口/任务栏；**Explorer 读的是 exe 的 PE 资源**。
  新增 `embedIcon()` 调 `launcher-win.exe --embed-icon` 把图标刻进**入口**（工具不要求 `-mwindows`）。
  **故意不刻 `dist/launcher.exe`** —— 分发版 launcher 必须与上游逐字节一致。
- 🐛 **修出货级 bug #11：`publish --typephp` 产出的 `.zip` 是假的**。`file` 报
  `POSIX tar archive (GNU)`、`zipfile` 抛 `BadZipFile`，但 manifest 已给它记 sha256。
  根因：CLI 调裸 `tar`，Git Bash 解析到 **GNU tar 1.35**，而 **GNU tar 的 `-a` 不会写 zip**
  （静默产出未压缩 tar）；能写 zip 的是 Windows 自带的 **bsdtar 3.7.7**
  （`%SystemRoot%\System32\tar.exe`）。修法：新增 `zipTar()` 优先钉死该系统 tar，
  再 `assertRealZip()` 读文件头两字节必须是 `PK`，否则 `fail()`。副作用（正向）：**18.6MB 存储 → 7.35MB 压缩**。
- **发布前校验 `assertTypephpBundle()`**：缺 entry/launcher/app.exe/conf/frontend 直接 fail；
  缺 6 个 PHP DLL 时**大声警告**（app.exe 不是静态链 PHP：构建机上 PATH 有 PHP 运行时所以照样能跑，
  到干净机器必死 —— 这类"构建机错觉"必须显式说破）。
- **实测（完整出货链路）**：
  - `tinyjs build --typephp` → `icon embedded into TypePHP Demo.exe` + 子系统已改 GUI。
  - `planb/verify-bundle.py dist` → **0 failure / 0 warning**：GUI 子系统、1 个可提取图标、
    `launcher.exe` **sha256 == stock**、6 个 DLL 齐全、conf+frontend 在、顶层 **18.6MB**。
  - `tinyjs publish --typephp --notes "first TypePHP build"` →
    `dist/publish/TypePHP Demo-0.1.0-win.zip`（**7,354,410 B**）+ `manifest.json`（sha256 实测一致）。
  - **把 zip 解压到干净目录**再跑：`verify-bundle.py` 全绿 → 解压出来的应用**直接 13 CALL/13 RET**、
    0 错误、`cwd` = 解压目录、关窗零残留。截图 `planb/e2e-shipped.png`。
- 新增工具 **`planb/verify-bundle.py`**（可复用）：入口靠 `<stem>.conf` ↔ `<stem>.exe` 的**配对关系**定位
  （不能从 `.exe` 列表猜，那里还有 `app.exe`）；`pe_subsystem()` 解 PE optional header；
  **`icon_count()` 调 `shell32.ExtractIconExW(path,-1,None,None,0)` 数图标**（用 Explorer 实际会问的
  那个 API，而不是猜资源目录长什么样）；`launcher.exe` 与 stock 比 sha256。退出码 0/1/2。
- 收尾清理：`_shiptest/`、`_pubtest/`、`demo-app/.build` 已删。
- 待办不变：**Phase 16b** 仍阻塞在用户的 `radeon-cloud` ssh 别名（唯一阻塞项）。

## 2026-09-25 session 13（Phase 16b-1：POSIX 分支本地实跑 —— Cygwin 打通，云环境不再必需）
- **用户提示**："cygwin 里编译出来的是 POSIX，我没什么云环境" → 一举解除阻塞。实测 **Cygwin 3.5.3 + g++ 11.4.0 就是真 POSIX 目标**：
  `g++ -dM -E` 显示它定义 `__CYGWIN__`/`__unix` 而**不定义 `_WIN32`** → shim 自动走 POSIX 分支；`sys/un.h`/`poll.h` 齐全。先写 `host_probe.c` 逐项验证原语，打印 **`PROBE: ALL PRIMITIVES PRESENT`**：
  AF_UNIX bind+listen、`fork+execv+dup2`、**`accept()` 返回新 fd**（与 Windows 命名管道"同一个 handle"相反）、`poll(0)`+`read` 分帧、`read()==0` 即 EOF、`SIGPIPE` 忽略、`waitpid` 回收。
- 🐛 **修掉会让 Linux 也踩的真 bug（#12）**：POSIX 分支**从来编不过**。`-std=c++17` → `__STRICT_ANSI__` → libc 隐藏 POSIX 声明；**glibc 上 g++ 驱动自动注入 `_GNU_SOURCE` 所以看不出来**，Cygwin/newlib 不注入 → `readlink()`/`kill()`/`setenv()` 全报未声明。修法：源码在**所有 `#include` 之前**自带 `#if !defined(_WIN32) && !defined(_GNU_SOURCE)` + `#define _GNU_SOURCE`（可见性宏晚于第一个头文件即失效）。修完 `-Wall -Wextra` 零警告。
- 🐛 **发现 Cygwin 特有的 AF_UNIX 互操作陷阱（#13）**，矩阵实测：C 服务端+C 客户端 OK；**C 服务端 + Cygwin-Python 客户端 → `accept()` 报 `ECONNABORTED(113)`，而客户端 `connect()` 返回成功**；Python 服务端 + C 客户端 → Python 端 accept "成功"却读到**无关的 16 字节垃圾**、C 端 `ECONNREFUSED`；Python↔Python 正常。→ 照旧用 Python 客户端就会**把客户端运行时的怪癖误判成 shim 的 bug**。修法：新增 **`mock_launcher.c`** 作为 kit 的客户端（真 launcher 本就是 C++，更保真；且无 `socket.AF_UNIX` 依赖），`mock_launcher.py` 降级为 `selftest_fixtures.py` 的**跨平台协议 oracle**。
- **实测：35 PASS / 0 FAIL**（`planb/posix-test/cygwin-all.log`，四段合一）：
  | 验证 | 结果 |
  |---|---|
  | `host_probe` | ALL PRIMITIVES PRESENT |
  | tier 1（mock 后端，`run.sh`） | **11/11**，另跑 25 CALL 压力 |
  | tier 2（**真 PHP 8.5.11** 后端，`tier2.sh`） | **11/11**，12 CALL → 12 RET → **24 EVAL** |
  | **launch 模式**（打包入口 `argc==1`+`.conf`，`launch-mode.sh`） | **13/13** |
- **tier 2 落地为一条命令 `tier2.sh`**：shim 以**零参数** execv 后端 → POSIX 下"带 shebang 的脚本"即合法后端。两个路径坑：① `TYPEPHP_APP` 是作为**脚本参数**交给 PHP 的，**Windows PHP 打不开 `/cygdrive/...`**（症状：第一帧就是 `Could not open input file: /cygdrive/…`）→ 要用 `cygpath -m` 给 Windows 形式路径（shim 自己的 execv 两种形式都收）；② 包装脚本里的 `require` 必须**绝对路径**（`__DIR__` 会把 Cygwin 路径喂给 Windows PHP）。另：**Cygwin 自带 PHP 是 7.4**，而 `backend.php` 用了 `str_starts_with`/`str_contains` → `tier2.sh` 校验 `PHP_VERSION_ID >= 80000`，改用 tpc 发行包的 php.exe（8.5.11）。
- **新增 `launch-mode.sh` —— 覆盖此前从未在 POSIX 上跑过的"出货路径"**：打包模式下 shim 是入口（`argc==1`），自己读 `<exe_dir>/<exe_stem>.conf`、自建端点、spawn 后端、再 spawn **原版 launcher**（`launcher <html> <endpoint> [title] [WxH] [ver]`）。它验证：conf 解析、`app=`/`launcher=` 相对 exe 目录解析、**交给 launcher 的 argv 顺序**、无 stdio spawn（`bInheritHandles=FALSE` 的 POSIX 等价物）、以及收尾不留孤儿子进程。设计要点：
  - 该模式下 launcher 的 stdout 是 `/dev/null`（shim 不给 stdio），所以 mock launcher 把收到的 argv **当作一帧发回**，让 shim 自己的日志成为断言来源 —— 于是"conf → argv → 线上帧"整条链都被证据覆盖。
  - `MOCK_LAUNCHER_ARGV=launcher` 用环境变量切换 argv 布局（shim 控制的参数不能加 flag，env 会继承给子进程）。
  - Cygwin 的 `/proc/self/exe` 可用 → `exe_path()` 正常（conf 能被找到即是证据）。
- **教训（与 session 11 的"测试自己的 oracle"同源）**：孤儿断言**初版是空洞的** —— 它"通过"只因当时没有进程在跑。现已加**正向对照**（先用存活同名进程证明匹配器看得见、再证明归零）。另实测 Cygwin `ps -ef` 打印**解析后的绝对路径**且**忽略 `argv[0]`**（`exec -a` 骗不过它）。
- **Windows 侧零回归**（源码改动必须验证）：`_GNU_SOURCE` 块被 `#if !defined(_WIN32)` 守卫 → MinGW 重编 **`-Wall -Wextra` 零警告、体积 126117B 与改动前完全一致**；重跑 `tinyjs build --typephp`（连 `typephp.build` 钩子里的 tpc+MSVC 一起跑）+ 双击 dist 应用：**13 CALL / 13 RET**、`WINDOW-E2E OK ping=pong in 427ms`、WM_CLOSE 后 `launcher closed`→`closing`→`done`、**零残留进程**、`verify-bundle.py` **0 failure / 0 warning**。
- **Phase 16b 因此拆成两块**：**16b-1（本地，已完成）** = tiers 1/2 + launch 模式 + 编译合规；**16b-2（仍需 Linux，但不再阻塞任何事）** = tier 3 `--nano` freestanding 体积测量（小巧路线的唯一真实答案）+ tier 4 真 `launcher-linux`（需 GTK/webkit2gtk/xvfb）。
- **边界（引用时必须说清）**：Cygwin 是**内核之上的 POSIX 仿真层**，证明的是**代码路径**（编译/端点/泵/spawn/收尾），**不是** glibc/Linux 的系统调用语义；它也不能产出可发行的 Linux 二进制。
- 新增/改动文件：`planb/backend_shell.cpp`（+`_GNU_SOURCE` 块）、`planb/posix-test/{mock_launcher.c, host_probe.c, tier2.sh, launch-mode.sh, run.sh}`、证据 `cygwin-all.log`/`tier2-shim.log`/`launch-mode-shim.log`、`planb/closewin.py`（WM_CLOSE 收尾助手）。

## 2026-09-25 session 14（Phase 16b-1 续：stdio 三通道分离 + 把 kit 当交付物来验）

- **起点**：用户只说了"继续"，于是回到 session 13 末尾自己标记过的、当时唯一"本地可做且确实该做"的加固项 —— `backend.php` 的 `log` 分支会写 stderr，而**当时的 stderr 就是帧通道**。顺带确认磁盘仍很紧（`C:` 2.8G 可用 97%、`D:` 6.8G 100%），所以没有擅自去装 WSL 发行版跑 tier 3。
- 🐛 **修掉协议级隐患（bug #14）：子进程 stderr 被并进帧通道**。`spawn_proc` 原本 `si.hStdError = child_out` → 后端任何一行诊断都变成**帧流里的畸形帧**；之所以一直没暴露，是因为 **launcher 对不认识的帧直接丢弃**（协议设计如此），所以它只是"脏"。真正的风险是 **PHP 错误路由随版本变化**（实测：**8.5 走 stderr、Cygwin 的 7.4 走 stdout**）→ 同一份后端在不同 PHP 上行为不同，且**炸在哪取决于 notice 落在哪两个帧之间**。改为 **stdin/stdout 走帧 + stderr 独立第三条管道**：shim 只排空、只写日志（`[shell] backend stderr: …`）、**永不转发**。
  - **排空是机械必需**：匿名管道 ~64KB 写满后**写者永久阻塞** → 话多的后端会在协议中途把自己卡死，症状伪装成"后端不应答"。**任何"子进程 stderr 不管"的设计都必须先回答"谁在读它"。**
  - 实现：`spawn_proc()` 加第三通道参数 `child_err`（Windows 注释写死 `NEVER child_out`；POSIX `dup2(child_err,2)`，未给才回退）；新增 `drain_stderr()` 做**按行重组**（半行等 `\n`，残行 8KB 上限防漏）；**`kill_proc(php)` 之后再排空一次**（管道缓冲里还有后端临死前写的内容）；`done:` 处 `io_close(hReadStderr)`。
- **验证方式本身是重点：诱饵 + 正向对照**。新增 `posix-test/stderr-channel.sh` + `mock_backend_noisy.py`：对抗型后端在**被回答的同一个 id** 上往 stderr 写一条**与真实应答无法区分**的诱饵 `RET <id> 0 …`，外加一条**无换行的半行**。因为客户端等的是**前缀匹配**，一旦合并它会**把诱饵当成该 id 的答复**，真实 RET 晚一拍到达、报错指向**下一个**调用（一个会把人带偏的症状）。
  | 跑 | 诱饵写到 | 断言 |
  |---|---|---|
  | A | stderr | 客户端全绿；`P->L:` 中诱饵 **0** 条；日志中 `backend stderr:` **N** 条；半行被**重新组装成一行** |
  | C | stderr，后端换**真 `backend.php`** | `log`（页面 API `tiny.log(msg)`）的行只出现在日志，`P->L:` 为 0 |
  | B | **stdout**（正向对照） | 客户端**必须失败**；shim 日志 forwarded 诱饵 **≥1**（与 A 的 0 正好相反） |
  - B 的断言刻意落在 **shim 日志**（`0 → 1`）而非客户端报错措辞上，使对照不依赖措辞；计数用 `≥1` 而非 `==N`，因为客户端一首个不匹配就退出、后面的 CALL 压根没发出去（实测 1 条即定案）。
  - **这是"给负向断言加正向对照"的第二次实践**（第一次是 session 13 的孤儿断言）。规律：**凡"断言某事没有发生"的检查，都要先证明"如果它发生了你看得见"**，否则无论被测系统好坏都会亮绿灯。
- **实测：50 PASS / 0 FAIL**（`posix-test/all.sh` 一条命令，`cygwin-all.log`）：host probe（ALL PRIMITIVES PRESENT）+ tier 1 **11/11** + tier 2 **11/11** + launch 模式 **13/13** + **stderr 隔离 15/15**。
- **Windows 侧零回归**：`-Wall -Wextra` 干净（126117 → 127227B，+1110 与新增代码相符）；`tinyjs build --typephp` 全链重跑（tpc+MSVC 钩子、图标 stamping、GUI 子系统补丁）；打包版与 dev 反向路径**各 13 CALL/13 RET**、`WINDOW-E2E OK ping=pong in 371ms` / `417ms`、`WM_CLOSE` → `launcher closed`→`closing`→`done`、**零残留**；`verify-bundle.py` **0 failure / 0 warning**。
  - **顺带可见的副作用（正向）**：那个页面标记来自 `tiny.log()`，实测现在落在 `[shell] backend stderr: [php-backend] "WINDOW-E2E OK …"` —— 而**在旧 shim 下它是 `P->L:` 的一条伪造帧**。同一事实、两行归属，正是本次改动的意义。
- **新增 `all.sh`**：把 host probe + 四个层次汇成一份可复现证据日志（退出码区分"失败=1"与"缺工具链跳过=2"）。此前每次都要手拼 env 和顺序的 heredoc —— 这正是日志与脚本悄悄脱节的来源。
- **新习惯：把 kit 当交付物来验**。把新版 shim + 整份 `posix-test/` 同步进技能后，**从技能目录就地跑 `all.sh`**，立刻抓到两个只有按"分发形态"运行才显形的问题：
  1. **kit 不带 `backend.php`**，而 `tier2.sh`/`stderr-channel.sh` 默认去 `../backend.php` 找 → 旧行为是拿一个**用户从没选过的路径报错**。改为：缺失即 **SKIP + exit 2**，并提示 `BACKEND_PHP=/path/to/backend.php`（与 tier2.sh 的 exit 2 约定一致，`all.sh` 会报成"至少一层跳过了自己"而非"全绿"，不会假绿）。
  2. **`launch-mode.sh`/`tier2.sh` 把 `$HERE/.work` 写死**、无视 `WORK=` 覆盖 → 会往源码/技能目录吐临时产物。已改为遵守 `WORK`；复跑确认技能目录**不再留 `.work`**。
  - 另外顺手把 `tier2.sh` 的 PHP 探测自动化为**依次试探**（Cygwin 的 `php` 是 7.4 会被版本检查挡掉 → 继续走到 tpc 发行版的 8.5.11），裸跑 `./tier2.sh` 即可用 —— 旧版直接报"set PHP_EXE"，等于把脚本自己已知的信息藏起来让人手填。
- **同步范围**：`planb/backend_shell.cpp`、`planb/backend.php`（改掉"shim 把 stderr 并进 stdout"的过时注释，并补三条 stdio 通道说明）、`planb/posix-test/*`（新增 `all.sh`/`stderr-channel.sh`/`mock_backend_noisy.py`；改动 `tier2.sh`/`launch-mode.sh`/`mock_launcher.c`(+`MOCK_LOG_CALL`)/`mock_backend.py`/`README.md`）、技能 `SKILL.md`（架构段三通道、pitfall 4 重写为"不要合并 stderr"、POSIX 段与 Related 更新）与 `scripts/`（含 `scripts/posix-test/` 整份同步；`quick_validate.py` → **Skill is valid!**）。
- **仍未做（且需要用户点头）**：Phase 16b-2 的 tier 3（`--nano` freestanding 体积）与 tier 4（真 `launcher-linux`）必须用 Linux；WSL 导入理论可行，但 **C: 仅剩 2.8G（97% 已用）**，装一个 1.5–2.5G 的发行版属于破坏性操作，未经同意不做，只在此报告。

## 2026-09-25 session 15（planning-with-files：把计划变成机器可读 + 进度校正）

- **用户指令**：`@skill:planning-with-files 更新进度`。按技能要求先做**恢复上下文**（读三份文件），再决定改什么。
- **本轮不是写代码，而是修"进度本身不可信"这个元问题**：
  - 跑技能自带 `scripts/check-complete.sh` → 输出 **`Task in progress (0/0 phases complete)`**。原因是 `task_plan.md` 一直用 `- [x] Phase N: …` 复选框记进度，而脚本只认两个**字面量**：`### Phase` 出现次数 = 阶段总数，`**Status:** complete` 出现次数 = 已完成数。→ **人类可读，但机器读出 0/0**，所谓"进度"完全无法被工具核对。
  - 核对仓库：`git status` 报 **not a git repository**（本项目非 git 仓），所以技能流程里"用 `git diff --stat` 验证实际改动"这一步在这里不可用 —— 改用**文件 mtime + 证据日志内的 sha256** 交叉验证（`cygwin-all.log` 头部的 `backend_shell.cpp sha256` 与当前源码一致，证明那份 50 PASS 证据确实对应现版本）。
- **重写 `task_plan.md` 为 planning-with-files 契约格式**（内容一字未丢，只重新归位）：
  - 补齐模板要求的结构：`Goal` / `Current Phase` / `Phases` / `Key Questions` / `Decisions Made`（表格）/ `Errors Encountered`（表格）/ `Notes`。
  - 21 个阶段全部改成 `### Phase …:` 标题 + 粗体 Status 行；15 个整数阶段 + `16a`/`16b-1`/`16b-2`/`17`/`18`/`19`。
  - **决定不重编号**：`16a`/`16b-1`/`16b-2` 这套标识被 `progress.md`、`findings.md`、技能文档全面交叉引用，为"整齐"改号会让全部历史记录失效 —— 作为一条正式决策写进 Decisions 表。
  - `Errors Encountered` 补了 14 行**索引表**（一句话症状 + 根因→修法指针），详细论证仍留在 session 条目与 `findings.md`，不重复搬运。
  - `Key Questions` 首次把**悬而未决的问题**显式化：① Linux 上 `--nano` 到底省多少（唯一还悬着的技术问题）；② Linux 上 POSIX 分支行为是否与 Cygwin 一致；③ shim 能否省掉（**已答：不能**）；④ stderr 走哪条通道（**已答：独立管道**）。
  - 顺手更正两处**已过时的陈述**：Phase 6 的"真实窗口渲染待用户验证"早已在 Phase 10 完成；Phase 11 的"通知帧不再写 stderr"是**当时的正确做法**（那时 stderr 就是帧通道），Phase 16b-1 后语义已变，加了注指向 bug #14。
- **踩到一个自指的坑（值得单独记）**：为了"说明格式"，我在说明段和自检段里**原样写出了那两个被统计的字面量** → 解析结果被污染成 **25/21**、随后 **22/22**（第二次数"更正"时又写了一遍）。连续两次都是同一个原因。
  - 最终改法：说明段改用「三级标题」「粗体 Status 行」这类**不含字面量**的措辞；自检改成"跑 `check-complete.sh`，它应报 21 阶段 / 20 完成 / 1 pending"（**用脚本读数自检，而不是在正文里写 grep 模式**）。
  - 校正后：`headings=21, complete=20, pending=1` → `[planning-with-files] Task in progress (20/21 phases complete). 1 phase(s) pending.` —— **第一次有了可被工具核对的真实进度**。
  - **可复用结论**：`task_plan.md` 里**任何**位置（含格式说明、Notes、示例）都不能原样出现那两个计数用的字面量，否则阶段数/完成数双双虚高。
- **技能层面发现的改进点（未擅自修改）**：`planning-with-files` 的 SKILL.md 只提醒了"不要用 TodoWrite / 要写文件"之类，**没有**提醒"在正文写出计数用的字面量会污染统计"这个陷阱。两份本地副本（`planning-with-files`、`planning-with-files__skillhub`）的 frontmatter 都**没有 `agent_created: true`**，按规则不得由我改动 → 已在回复里向用户点明，建议作为上游 issue/PR 或在 Anti-Patterns 表里加一行。
  - 另：`resolve-plan-dir.sh` 在我们这种"计划文件在项目根、没有 `.planning/`"的**旧式布局**下输出为空，但后续脚本都能正确回退到 `./task_plan.md`（`check-complete.sh` 实测可用），所以旧式布局仍受支持。
- **产出**：`task_plan.md` 整体重写（机器可读，20/21）、`progress.md` 本条目、`findings.md` 增补"计划文件计数契约"一节、当天工作记忆追加。
- **状态未变**：Phase 16b-2 仍是唯一 `pending`，仍卡在"需要 Linux"（三条路任选：用户已有的 `radeon-cloud`、任意 ssh 可达机器、本地 WSL；其中 WSL 受 **C: 2.8G 可用**限制，须用户明确同意）。

## 2026-09-26 session 16（用户要求：梳理仓库布局 + 完善 README；随后把套件按"分发地"重验）

- **用户指令**：「当前代码仓库是 `D:\git\php\typephp-gui` 感觉现在里面目录乱 不是一个 php 项目，然后有的编译你放到了 `D:\git\web\tinyjsapp-0.42.0\native` 梳理一下 然后完善 `README.md` 讲清楚具体怎么用 扩展」。
- **两个决定先问再动**（`AskUserQuestion`）：① 梳理力度 → **完整梳理**（重排为标准布局、生成物归 `build/`、同步修正脚本内相对路径并重跑全部验证）；② 上游 checkout 里被我们改过的文件 → **固化为 patch 并还原上游**。
- **为什么先备份**：重排前这个目录**完全没有版本控制**（`git status` → not a git repository）。所以顺序是：外部 `tar` 整树备份（含被 gitignore 的生成物，56MB）→ `git init` → **提交重排前快照**（`fbecd06`，110 文件）→ 重排（`eca999c`）→ bootstrap（`6895a50`）→ README。**每一步都可回滚**，这在"一次动 100+ 文件"的操作里不是礼节而是前提。
- **新布局**（`planb/` 彻底消失）：

  | 旧 | 新 |
  |---|---|
  | `planb/backend.php` | `src/backend.php` |
  | `planb/backend_shell.cpp` | `shim/backend_shell.cpp` |
  | `planb/launcher_bridge.cpp` | `experiments/bridge-probe/launcher_bridge.cpp` |
  | `planb/posix-test/` | `test/posix/` |
  | `planb/demo-app/` | `demo/`（那份 12 行占位 `src/backend.php` 移出，改名为 `experiments/bridge-probe/demo-backend-placeholder.php.txt`） |
  | `planb/www/` | 删除（与 `demo/src/frontend/index.html` 逐字节相同的重复页） |
  | `planb/dist-test/`、`planb/demo-app/{dist,backend}/` | `build/`（生成物，gitignore） |
  | `_b.err` / `_b.out` | `build/` |
  | `*.orig.bak`（散落在 checkout 里） | `patches/base/` |
  | 根目录 `task_plan.md`/`findings.md`/`progress.md` | `docs/planning/` |
  | e2e 截图 / 套件日志 | `evidence/` |

  - 体积大头是**三份重复的 15.5MB PHP DLL 树**（`dist-test/`、`demo-app/dist/`、`demo-app/backend/`），收敛后才显出"目录乱"的真实规模。
  - 顺带发现：`mv planb/demo-app demo` 报 `Permission denied`，排查了进程、A/B 试验后确认是**目录本身不能改名而内部条目可以**；逐个搬内容再 `rmdir` 成功。根因是一个**早前 E2E 自动化残留的交互式 `cmd.exe /s /k pushd …`（PID 38036）**把目录 CWD 钉住（`Get-CimInstance Win32_Process` 查 CommandLine 才看到），不是权限问题。与此相关的一条工具约束：PowerShell 工具里不能拼 `cmd`/`bash` 关键字，改用 `Get-CimInstance`。
- **上游 checkout 不再带着我们的改动**：联网取 tinyjsapp **v0.42.0 原始** `cli.js`（75,888B，sha256 `07c78612…`）与 `launcher-win.cc`（306,252B，sha256 `d2fb5fed…`）存进 `patches/base/`，diff 出 `patches/cli-typephp.patch`（8 hunk，+324）与 `patches/launcher-win-typephp.patch`（4 hunk）。**两个补丁都实测"基线 + 补丁 = 在用文件的 sha256"**，不是"看起来对"。新增 `tools/bootstrap-tinyjsapp.sh`（`status|patch|restore`，用 sha256 + 试打补丁判定 pristine/PATCHED/MODIFIED），一键把 checkout 在两种状态间切换并把我们的产物**移出**（不是删除）到 `build/checkout-residue/`。
  - **`cli.js` 必须就地打补丁**（`TOOL_DIR = new URL('.', import.meta.url)` → CLI 只能从 checkout 里跑）；**`launcher-win.cc` 不需要**——`tools/build-launcher.sh` 改写为**离树编译**，从 `patches/base/` 派生自己的副本，实测 `build/gen/launcher-win.cc` 的 sha256 与跑过全套验证的源逐字节相同。
  - **三处联动陷阱，全写进 README 与脚本注释**：① `cli.js` 的 `ensureLauncherFresh()` 会在 `native/launcher-win.cc` 比 `.exe` 新时触发 `setup.ps1` 重建，而 MinGW 上这个重建**必然失败**（上游期望 Windows SDK 的 WinRT 头，我们的 overlay 故意在 `build/winrt-shim`）→ `bootstrap patch` 装上我们编好的 launcher 并 `touch`。② `cli.js` 硬编码 `TOOL_DIR + 'native/backend.exe'`（dev 与 build **都**读它，"the shim doubles as the packaged entry"）→ shim 必须装在 checkout 的 `native/`，`restore` 时把它移走会直接让 `tinyjs build --typephp` 报 "shim missing"。③ `demo/build.bat` 是 `tinyjs.json` 的构建钩子，CLI 会 `chdir` 到项目目录执行，所以里面只能写相对路径。
- **README.md 是主交付物**：验证结果表 / 目录结构 / 环境要求 / 快速开始（准备 checkout → 打补丁 → 构建 → dev → 打包）/ 工作原理（帧协议两张表 + **三条 stdio 通道** + dev 与 packaged 两个方向对照）/ **如何扩展**（加后端方法、加帧类型、加页面 API、加新平台、为什么后端只允许一个文件）/ 验证 / **维护与升级上游（两个联动陷阱）** / 已知限制。
  - 起草时写错了一个不存在的 API（`tiny.call`），对 `runtime/tiny.js:80-97` 核实后改为 **`tiny.api.call`** —— 顶层确实没有 `call`。**文档里的调用示例必须对着 runtime 核一遍**，否则它会稳定地教错人。
- **重排后全链路复验**：Cygwin 套件 **51 PASS / 0 FAIL**（tier1 11 + tier2 11 + launch 14 + stderr 15）；**dev 方向** 13 CALL/13 RET + `WINDOW-E2E OK ping=pong in 441ms`；**packaged 方向**（双击 `<App>.exe`：shim 当入口、再按上游 stock 参数契约拉起**未打补丁**的 launcher）同样 13 CALL/13 RET + 438ms；两者**零残留进程**；`verify-bundle.py` **0 failure / 0 warning**。

### 把套件按"分发地"重验：又抓到三个真 bug 和一条"假通过"

session 14 立下的规矩——**一个 kit 资产只有在"它被分发到的位置"跑起来才算验过**——这次从技能目录跑同步后的副本，立刻开出三朵花（in-tree 全绿，standalone 是 `TIER1_RC=1`、`STDERR_RC=1`）：

1. **`sun_path` 超长（真 bug，会 bind 失败）**。日志：`[shell] socket path too long (108): /cygdrive/c/Users/<u>/.workbuddy/skills/<skill>/scripts/posix-test/.work/app.sock` → `endpoint create failed` → `[FAIL] socket never appeared`。这条路径**恰好 108 字节**，而 in-tree 只是碰巧短 —— "in-tree 通过"完全不能外推。
2. **`$WORK` 还没被创建（真 bug）**。`all.sh` 把 `host_probe` 编进 `$WORK/` 时它还不存在：`ld: cannot open output file … No such file or directory`。各 tier 各自会建，所以**只有第 0 步**被打中。
3. **"默认值"无视显式的 `WORK=`（真 bug，浪费 + 污染 TMPDIR）**。`all.sh` 会 `export WORK` 给子进程共享一个 scratch 目录，但每个子脚本仍然调了 `typephp_default_work`，**先造一个临时目录再发现用不上** —— 一次 standalone 跑留下 **9 个空目录**。
4. **一条"假通过"的断言（比 bug 更值得记）**。launch 模式下端点名是**入口自己**取的（`<exe_dir>/app.sock`，超长才回退 `/tmp/tinyjs-typephp-<pid>.sock`）。`launch-mode.sh` 却断言 `$WORK/app.sock` 已被 unlink —— 于是在**回退触发时**（= 正好是被分发的那一侧）它断言一个从来就没存在过的文件，**无条件通过**。改为从 shim 日志里读回真实路径：`transport=unix-socket pipe=… app=…`，断言那条，并打印用了哪条形式。

- **修法与验证**（`resolve-root.sh` 里两个助手，均在"两个 home"一节有文档）：
  - `typephp_default_work`：in-tree → `<kit>/.work`；standalone → `$TMPDIR/typephp-kit.XXXXXX`（**短**，且"发布出去的副本不许弄脏自己"）；**显式 `WORK=` 立即短路**（这是第 3 条 bug 的修法）。
  - `typephp_socket_path`：`$WORK/app.sock` 放得下就用它，否则挪到 `$TMPDIR/tpkit.XXXXXX/app.sock`。**两个助手都设变量、不 print** —— `SOCK="$(…)"` 会跑在子 shell 里，要回传的 `TP_SOCK_TMP` 会一起被丢掉（这个坑在写下之前就避开了）。
  - `all.sh` 补 `mkdir -p "$WORK"` + `export WORK`；standalone 的证据日志落到自己的临时 scratch 并打印路径，**in-tree 照旧写 `evidence/kit/`** —— 目的是让"把这棵 kit 同步进技能后 `diff -rq`"这件事**永远干净**，否则残留会变成幽灵差异、并掩盖真差异。
  - **两条回退分支都实测**：`WORK=/tmp/$(printf 'd%.0s' $(seq 1 120))/lw ./launch-mode.sh` → `[PASS] endpoint is the shim's /tmp fallback (/tmp/tinyjs-typephp-1465.sock)`；同法跑 `run.sh` → `[PASS] AF_UNIX listening socket created: /tmp/tpkit.pEflZj/app.sock`，且 `EXIT` trap 把临时目录清干净（**0 残留**）。
- **最终两侧一致**：in-tree **51 PASS / 0 FAIL / ALL TIERS OK**（且**零**临时目录）；standalone（`BACKEND_PHP=` 指向本仓后端）同样 **51 / 0 / ALL TIERS OK**，临时目录**恰好一个**，就是它打印并实际使用的那个。技能目录 `diff` 回干净：只剩 13 个同步文件。
- **顺带纠正两处已过时的旧结论**（见 `findings.md`）：`planb/` 已不存在；本项目**现在是 git 仓**（session 15 记的"不是 git 仓"已被推翻，`git diff --stat` 重新可用）。
- **仍未做（不变、不阻塞）**：Phase 16b-2 的 tier 3（真 `--nano` freestanding 体积）与 tier 4（真 `launcher-linux`）需要 Linux；三条路（`radeon-cloud` / 任意 ssh 机器 / 本地 WSL，后者受 **C: 2.8G 可用**限制）等用户点头。

## 2026-09-26 session 17（README 同步 + 打包链路回归修复：把 PE 后处理接回 tgui build）

- **背景**：session 16 之后有三个未记档的 commit——GUI 融合入树（`f8202d0`）、真机验证中修好
  `tgui build` 三个布局 bug（`3c9370e`：shim/后端同名互覆、漏拷 MinGW 运行时、`set -u` 未定义变量）。
  本次用户要求更新 README；核对时发现两处"README 说的还是真的吗"级别的问题。
- **发现的真回归**：README 声称入口"已置 GUI 子系统并嵌图标"——这正是旧 cli.js 的出货级修法
  （bug #10：CUI 入口双击全程挂黑框）。融合 CLI `tgui build` **没接这两步**，当前 dist 入口是
  console 子系统、无图标 → 声明为假。此前所有实测都从 shell 起，黑框根本看不见（#10 当年的
  教训原样重演）。
- **修法**：
  - `gui/bin/tgui` build 接回两步 PE 后处理：① `launcher --embed-icon dist/<App>.exe <icon>`
    （launcher 自带工具，会**整体重写 PE**）；② 用 php 内联改 PE `OptionalHeader.Subsystem`
    （`peOff+24+68`，uint16）3→2。**顺序敏感**：子系统必须是最后一步（findings 既有结论）。
  - `tools/verify-bundle.py`：PHP 后端改查 **`php.exe`**（新布局，入口是 shim、二者不同名）；
    必查 DLL 加上 **2 个 MinGW 运行时**（libgcc/libstdc++，launcher 与 shim 都依赖）；入口候选
    排除表加 `php.exe`；docstring 同步。
- **实机验证**：重建 dist → `verify-bundle.py` **0 failure / 0 warning**（PE subsystem GUI、
  图标 1 枚可被 Explorer 提取、launcher 逐字节一致、php.exe、8 DLL、conf、frontend；
  top-level **20.7MB**）→ PE 补丁后的入口重跑打包方向 E2E：**`WINDOW-E2E OK ping=pong in 430ms`**
  + 干净收尾（`evidence/e2e/pub_real2.log`）。
- **README 同步（8 处）**：验证表改融合后真机复验数据（dev 406ms / packaged 430ms，旧 441/438ms
  是融合前 cli.js 时代的数据）；图注补"打包方向后端叫 `php.exe`、为何与入口不同名"；build/ 树的
  `runtime/` 补 2 个 MinGW DLL；产物清单重写（含自动刻图标 + 子系统 patch 的说明）；打包方向 E2E
  命令改 `TypePHP-Demo.exe`（name 含空格被净化）并写明 **`TYPEPHP_SHELL_LOG` 必须给原生 Windows
  路径（`D:/...`），原生 shim 读不懂 `/d/...`**；verify-bundle 描述改 8 DLL 口径；分发体积改
  20.7MB 实测；已知限制改 `php.exe` 措辞。
- **教训**：改构建产物布局时，要同盘盘点**引用该布局的下游工具**（verify-bundle）与**构建流程
  隐含的后处理步骤**（PE 补丁）——README 的声明只能靠实跑 verify-bundle + E2E 背书，不能靠记忆。

---

## Session 2026-09-26 — Phase 20：macOS（Apple Silicon）实机编译运行

- **环境**：macOS 26.6.2 / arm64 / Apple clang 21 / 系统 PHP 8.5.7。用户要求"尝试在 mac 下编译运行"，
  走 planning-with-files，结果全绿。
- **范围（未静默收窄，均为 README 既有边界）**：不碰 tpc/MSVC（Windows 专属），后端用系统 PHP 的
  shebang 脚本；跑**打包方向**（shim 当入口拉起 pristine `launcher-macos.cc`）。dev 方向的
  `--typephp` 在 mac 仍不存在（既有已知限制）。
- **20a shim 编译**：`clang++ -std=c++17 -Wall -Wextra` 零警告过（57KB）。
- **20b POSIX 套件**：`test/posix/all.sh` 首轮 **launch 档 8/6**——根因是 shim 的 `exe_path()`
  依赖 `/proc/self/exe`，**macOS 无 `/proc`** → 静默退化成 `"app"`（bug #17）。用
  `_NSGetExecutablePath`+`realpath` 补 `__APPLE__` 分支后，launch 档 13/14，剩两项都是**测试夹具的
  macOS 假象**：① `/tmp→/private/tmp` 符号链接（realpath 返回物理路径是对的，与 Linux 一致）→
  测试先把 `WORK` 归一化成物理路径；② 正向对照 `cp /bin/sleep` 在 Apple Silicon 被 AMFI 直接
  SIGKILL → 改成现场编译一个常驻探针（并补 `#include <unistd.h>`，新 clang 把隐式声明当错误）。
  修完 **ALL TIERS OK（probe + 11 + 11 + 14 + 15，0 FAIL）**，证据 `evidence/kit/macos-all.log`。
- **20c launcher-macos 编译**（`tools/build-macos.sh` 固化，零源码改动）：关键三点——`-x objective-c++`
  （`.cc` 名不含 ObjC）、**MRC 禁 `-fobjc-arc`**（源码满屏 release/autorelease + 裸 void*↔id）、
  `webview.h` 需要新版 header-only webview 整套 69 头文件（从 tinyjsapp archive 的
  `native/include/webview` 取）。产物 684KB，usage 自检正常，ScreenCaptureKit 弱链。**子代理首轮报告
  的 `-fobjc-arc` 是错的、且报"成功"但盘上无产物——以磁盘为准重编验证。**
- **20d 打包方向真窗口 E2E**：`build/mac-e2e/Demo`（入口）拉 `launcher-macos` + 真 PHP 后端，
  WKWebView 出窗，**13 CALL / 13 RET**、`WINDOW-E2E OK ping=pong in 48ms`、stderr 隔离成立
  （标记落在 `[shell] backend stderr:`）。证据 `evidence/mac/packaged-e2e.log`。
- **顺带修的两处陈旧/缺陷**（非本轮引入，实机撞见）：
  - `bin/run-backend.php` 早已失效（`require` 指向不存在的 `bin/backend.php` + 调 fusion 前删掉的
    `main()`）→ 重写为带 shebang 的正确 wrapper（`require ../src/backend.php`，其顶层已
    `Gui::serveDemo()`），并 `chmod +x` 供 POSIX 无 argv `execv`。
  - `gui/host/script/gen-client.sh` 的 `cd ../..` 少一层（脚本在 `gui/host/script/`，`../..` 只到
    `gui/`）+ heredoc 里用未定义的 `__file__` → 改 `cd ../../..` + `base=os.getcwd()`。
- **域名**：`xget.xi-xu.me` 已 429 限流 → 用户自有镜像 `xget.fnthink.top`，README + build-launcher.sh
  同步替换。
- **README 同步**：验证表加 macOS 行；"支持一个新平台"与"已知限制"改为"打包方向 macOS 已真窗口跑通、
  dev 方向 `--typephp` 仍 Windows 独有"；`tools/` 结构补 `build-macos.sh`。
- **未做（诚实标注）**：`tgui`（bash CLI）本身没接 macOS 分支（本轮用 `tools/build-macos.sh` 直接编排）；
  Linux 的 GTK tier 4 仍未跑；`.app bundle` 未封装（裸可执行文件已能出窗，双击体验另说）。
  → 以上已升格为 **Phase 21**（`task_plan.md`，status: pending；Linux tier 3/4 仍在 Phase 16b-2）。

## Session 2026-09-26（续）— Phase 21a：tgui 接 macOS + sysinfo 后端字段说真话

- **shim 判型注入**：`app_kind_of()` 读 `app` 文件首 2 字节（`#!`→stock / `MZ`→aot /
  其他→unknown），spawn 前 `SetEnvironmentVariableW`/`setenv` 注入 `TYPEPHP_APP_KIND`
  （子进程继承环境，与 TINYJS_ICON 同惯用法）；shim 日志新增 `app_kind=` 字段。
- **PHP 侧真话上报**：`CoreHandler::sysinfo().backend` 不再硬编码 "aot-compiler (tpc)
  AOT native"，改为 `backend_kind()` 按 `$_SERVER`→`$_ENV` 链映射（Phase 17 禁 getenv）；
  同类撒谎的 `DemoApiHandler api.version.backend` 由 'tpc-AOT' 改为透传原始 kind。
- **tgui Darwin 指引**：`status` 增列 macOS 三件套实际路径并指向 `build-macos.sh --run`；
  `dev` 在 Darwin 先打同一段指引再 die，不再"找不到 launcher-win.exe"式裸失败。
- **实测**：直调后端两档输出正确（stock→"stock PHP CLI (no AOT)"、未设→unknown 文案）；
  打包 E2E shim 日志 `app_kind=stock` + 13 CALL/13 RET + `WINDOW-E2E OK 54ms`，活动帧流
  RET 内 `backend":"stock PHP CLI (no AOT)"`；回归 smoke 24/24、posix ALL TIERS OK。
- **如实登记的边界**：Windows 新增段本机无 mingw，仅代码审查（与既有用法逐字同构）；
  `tgui build` 的 Darwin 行为不在 21a 验收内、未动。

## Session 2026-09-26（再续）— Phase 21b：--typephp 移植进 launcher-macos，mac 真 dev 方向

- **launcher-macos.cc**：按 `launcher-patch-notes.md` Hunk A–E 同构移植——`g_typephp` 运行时门控、
  argv 归一化（拷贝不左移，win 教训原样遵守）、`posix_spawn` shim（env `TYPEPHP_BACKEND`，缺省
  `<exe_dir>/backend`）、端点固定 `/tmp/tinyjs-typephp-<pid>.sock`、connect 重试 50×100ms **仅
  typephp 模式**（stock 客户端契约单次 connect 不变）、`terminate_typephp_backend()`（SIGTERM+
  `waitpid(WNOHANG)`）挂 `_exit(0)` 前——**win 的 `std::atexit` 在 mac `_exit` 路径不会跑**，主回收
  靠 shim 端点 EOF 链（`launcher closed` → `kill_proc(php)`，launch tier 已证）。
- **tgui dev**：Darwin 默认三件套 `build/launcher-macos`+`build/backend_shell`+`bin/run-backend.php`；
  `typephp.{backend,app}` 配置仅文件存在才生效（模板是 win .exe 路径）；mtime watcher（`src/**`+
  框架 php，`stat -f` BSD 格式）变更 → kill launcher → respawn = 窗口 bounce。**Windows 分支行为
  逐字保留**——且查实它本来就是单发（见 bug #19）。`to_native` 的 realpath 静音（mac 上 win 默认
  路径不存在，stderr 噪声）。
- **验收（实机）**：`tgui dev` 出窗 **13 CALL/13 RET**、`WINDOW-E2E OK 56ms`、`app_kind=stock`、
  帧流里 `"backend":"stock PHP CLI (no AOT)"`；`touch src/backend.php` → bounce → 新 shim 再 13/13
  （CALL 13+19）；杀 launcher → tgui 干净退出、`NO_PROCS`、socket 文件清零；打包方向复验 13/13、
  49ms；`test/posix/all.sh` ALL TIERS OK；`bash -n` 过。证据 `evidence/mac/dev-21b.log`。
- **撞出既有缺陷 #19**（Windows dev 热重启在 fusion 时变死代码）→ 登记 task_plan Errors 表 + 新增
  未做项 **21e**（win watcher 恢复），README 三处（验证表/dev 说明/支持新平台/已知限制）与
  `launcher-patch-notes.md` 同步为实机事实。

## Session 2026-09-26（三续）— Phase 21c：macOS .app bundle 封装 + verify-bundle-macos.py

- **tgui build Darwin 分支**（新增）：`demo → dist/<App>.app`。布局：`Contents/MacOS/App`（= shim，
  **名字不带点**——`stem_of()` 在第一个 `.` 截断，带点会把 conf 解析成 `App.exe.conf` 式错配）、
  `App.conf`（launch 模式，`html=../Resources/frontend/index.html`、`app=../Resources/app/bin/run-backend.php`、
  `launcher=launcher-macos`）、`MacOS/launcher-macos`、`Resources/app/`（后端 + 框架 php **逐字节镜像**，
  `__DIR__` require 链原样生效）、`Resources/frontend/`、`Resources/AppIcon.icns`（`sips`→iconset
  10 张精确命名→`iconutil`；缺 icon.png 时 CFBundleIconFile 键整体缺席）、Info.plist heredoc
  （CFBundleExecutable、TCC 相机/麦克风/语音串、LSMinimumSystemVersion 12.0）。
- **codesign 步骤实测移除**（bug #20）：macOS 26 上整包 ad-hoc 签名拒绝此布局（Contents/ 下每个
  文件包括 644 的 conf 都被封成子组件）；bundle 内重签主执行体后原始路径 `--verify` 反而报
  "code has no resources…"。二进制保留**链接器 ad-hoc 签名**（全程可跑）。Developer ID+公证另立事项。
- **tools/verify-bundle-macos.py**（新增）：layout / plistlib / Mach-O 头解析（fat+thin，主机架构硬检）/
  conf 按 shim 语义复析（html/app/launcher 解析存在、app 须 `#!`）/ X_OK 位 / 镜像完整性 / icns /
  sun_path 104B。codesign 用 `-dvv` **信息报签**不 `--verify`。build 末尾自动调用。
- **实机验收**：干净重建 verify **PASS/0 warn**；直跑 bundle 入口（清 `TYPEPHP_*` env，conf 驱动）
  **13/13**、`WINDOW-E2E OK 51ms`、`app_kind=stock`；杀 launcher → shim 干净退出、socket unlink、NO_PROCS。
  `open` 双击等价：/tmp 副本 13/13（79ms）；仓库外部卷上 LaunchServices 实例卡 `__bind`（bug #21，
  环境性：直跑同二进制正常，sample 787/787 全在 bind，socket 未创建）。
- **文档回写**：README 验证表 +macOS bundle 行；tools/ 树增 verify-bundle-macos.py；打包发布节 +macOS
  段；已知限制拆分（tgui build 不再 Windows-only，改列 mac 三条边界）。task_plan 21c ✅、Errors #20/#21。

## Session 2026-09-27 — Phase 21d/16b-2（当日闭环）：Linux 环境 = Apple Container

- **路线**：用户否决 OrbStack（相关后台任务/机器已拆除），改 **Apple Container**：brew 公式 `container`
  1.4.1 装好、`container system` apiserver 正常。
- **环境事实**（每条都实际撞过）：
  - ghcr 直连 ~8KB/s → `HOMEBREW_BOTTLE_DOMAIN` 指 TUNA 后装成。
  - 启动卷剩 224Mi → brew "No space left on device"；**获批逐批**清 4 个 updater 缓存（~1.7G）后成功；
    第二批提案用户未答复 = 不扩大删除范围。
  - `paths.appRoot`（~/Library/Application Support/com.apple.container/）软链到 /Volumes/data →
    apiserver XPC 挂死、brew services 假启动；恢复默认目录+重启即好。**appRoot 必须留在启动卷**。
  - recommended 内核 = `kata-static-3.32.0-arm64.tar.zst`（696,573,576B）：GitHub 直连 remoteConnectionClosed；
    xget 镜像可 Range 但掐长连；两条 curl 并发写同一文件互相打坏（premature end）→ 用户令**停 curl**。
  - **下载改道 unfetch MCP**（用户指定）：**32 线程分片会把文件写坏**（xget 掐流后分片重发，
    `done_bytes` 冲到 956MB > `total_bytes` 696,573,576B，`zstd -t` 报 Data corruption）；删任务清残留后
    **threads=1 顺序下载 5m20s 完成、retry_count=0、`zstd -t` 通过**（任务 id `e268d08c`，
    `save_dir=/Volumes/data/tmp`）。教训：对该镜像源用 unfetch 必须单线程。
  - 安装：`container system kernel set --tar /Volumes/data/tmp/kata.tar.zst --binary ./opt/kata/share/kata-containers/vmlinux-6.18.35-197 --arch arm64 --force`。
- **已就绪待执行**：`test/posix/tier4-linux-window.sh`（shim 服务端 / launcher-linux 客户端、Xvfb :99、
  ≥13 CALL/≥13 RET + WINDOW-E2E marker + 截图 + teardown 零残留断言）。
- **容器落地**：debian bookworm-slim 经 `docker.m.daocloud.io` 秒拉（docker.io 直连超时、1ms.run 限速）；
  vminit 缺失 → `ghcr.m.daocloud.io/apple/containerization/vminit:0.45.0` 拉回后 `image tag` 成规范名；
  外卷 `--volume` 建容器失败（No space left/HTTP2 StreamClosed）→ **不挂卷 + base64|exec -i 管道传文件**；
  debian CMD 无 TTY 即退（非故障）→ `create … sleep infinity` 常驻。apt 源：TUNA 403/证书不受信 → **aliyun 可用**；
  x11-utils 无 xwd → 截图走 imagemagick `import`。依赖装齐：g++ 12.2 / php8.2 / GTK 3.24.38 /
  webkit2gtk-4.1@2.50.6 / Xvfb / libayatana-appindicator3-dev。
- **tier 4 = PASS**：修两个脚本级阻塞（ROOT 层级 `../..`；launcher-linux **不定义 TINYJS_APPINDICATOR 编不过**
  的上游缺陷 → pkg-config 双名探测）后重跑：**14 CALL / 14 RET、`WINDOW-E2E OK ping=pong in 128ms`、
  shot.png 98,337B、shim 随 launcher 退出、socket 清零、TIER4_RC=0**。真 glibc 上系统调用语义与
  Cygwin/mac 一致（Key Question ② 闭环）。
- **tier 3 = 数字到手**：`php:8.4-cli-bookworm` 镜像 881MB 拉一半 ENOSPC（启动卷 ~700Mi）→ 改 **sury apt**
  装 PHP 8.4.25；tpc 树核实为 **v0.9.3**，vendor phpx 2.7.0 缺 nano 元数据 → xget+unfetch(1 线程) 拉
  **phpx v2.9.2 / php-nano v1.0.1** 放入 `vendor/swoole/`（`resolveLocalPackage` 命中，不动 composer 元数据）。
  5 行 `nano_min.php` 编译成功（122 文件，`Auditing Nano runtime dependencies` 过）：产物 **1,160,624B /
  strip 987,208B**，**ldd 仅 libstdc++/libm/libgcc_s/libc（无 libphp）**，直跑 `nano-policy-build-ok` RC=0
  （Key Question ① 闭环）。**真 nano 拒 `require`** → demo `src/backend.php` 入口在 Linux 真 nano 下编不过
  （Errors #22，能力边界非 bug）；Linux bin 模式无 embed 开发库 → 与 bin 的对比按定性 + Windows 既有数字。
- **文档回写**：task_plan（16b-2 complete、Phase 21 只剩 21e、Q1/Q2 已答、Errors #22-#24）；README 验证表
  +Linux tier4/tier3 两行、已知限制改写（Linux 打包方向已有真窗证据；nano 语法面边界入档）；findings 新节。
- **下一步**：unfetch 下完 → `container system kernel set --tar` → 拉 debian:bookworm-slim → apt 装
  g++ php-cli libgtk-3-dev libwebkit2gtk-4.1-dev xvfb → 跑 tier4（任务 #10）→ tier3 `php bin/tpc.php --nano`
  源码路线（任务 #11）→ 回写（任务 #12）。

## Session 2026-09-27 (2) — Phase 21e：Windows watcher 代码侧落地（真机验收待通道）

- `gui/bin/tgui` dev 监视循环去掉 Darwin 门控：win/mac 同一 `--typephp` 生命周期链（kill launcher → shim
  EOF 回收 → respawn），Windows 分支不再是"融合遗留单发"。
- `hot_snap` stat 方言现场探测：`stat -f '%m' /` 试探成功 → BSD `-f '%m %N'`；否则 GNU `-c '%Y %n'`
  （Git Bash 自带 GNU coreutils）。不再把 BSD 写法硬编进 Windows 路径（bug #19 修复的收尾）。
- 本地验证（macOS，这台机器能证的全部）：`bash -n` 通过；假 stat（拒绝 `-f`）证明 GNU 探测被选中，
  且 GNU 路径 digest 与 BSD 路径 cksum 一致；**无头冒烟**：fake launcher/shim/app 起 `tgui dev` →
  `touch src/backend.php` → 日志 `sources changed — bouncing…` → 新 launcher 实例拉起 → 杀 tgui 后零残留。
- **未做（不能用本地证据冒充）**：真 Windows 机 `tgui dev` 的 kill/respawn（MSYS2 `kill` 对 launcher-win.exe
  的语义、Named pipe EOF  teardown 链、WebView 窗口闪一下）+ 13/13 复用 = 21e 验收本体。README 的
  "win 侧单发启动"注记保留未删，等真机 PASS 再改。

## Session 2026-09-27 (3) — Phase 22 开轮：Linux 打包/dev 方向（用户选定）

- **方向选定**：21e 阻塞在 Windows 通道，用户从四个候选里选了 **Linux 打包/dev 方向**（复用现成容器
  `tgl`，不依赖外部通道）。新开 **Phase 22**（22a 构建脚本 / 22b `tgui status|dev` / 22c `tgui build|publish`
  / 22d 端到端验收+回写），设计约束先写死：**不给 `launcher-linux.cc` 打 `--typephp` 补丁**（保持 pristine，
  那是 tier-4 证据成立的前提），Linux dev 反向由 shim 做 AF_UNIX 服务端、原版 launcher 做客户端。
- **22a 完成**：新增 `tools/build-linux.sh`。容器内一条命令产出 `build/backend_shell`(78,352B) +
  `build/launcher-linux`(545,496B)，与 tier-4 当时的两个产物**逐字节相同** → 提炼过程没有改变 flag/输入。
  `file`=ELF pie ARM aarch64，launcher 链 171 个共享库。
- **22a 错误路径实测**：假 `pkg-config`（只对 `*appindicator*` 返回 1）→ 脚本点名两个 pkg-config 名 +
  Debian 包名并 die（RC=1），落实 #23 的"pristine 源码离开 appindicator 根本编不过"。
- **附带**：`gen-client.sh` 要 python3 → 加 php 等价回退（同一 `tiny_client.h` 输出 + 同样的分隔符冲突断言）；
  WebKit 4.1→4.0 回退；`-lX11/-lXtst` 存在性检查。Fedora/Arch 包名**本机未核实**，脚本输出里明说只有
  Debian/Ubuntu 名是实测过的（不把推断写成验证）。
- **环境注意**：容器内 `/work/repo` 已换成当前源码快照（`repo.old` 保留 tier-4 现场）；宿主启动卷只剩
  ~500Mi，本轮**不新增任何安装项**，容器盘 503G 充足。
- **下一步**：22b `tgui status|dev` 的 Linux 分支（任务 #15）。

## Session 2026-09-27 (4) — Phase 22b：`tgui status|dev` 的 Linux 分支，容器内真窗口 PASS

- **实现**：`gui/bin/tgui` 的 dev 循环加 Linux 分支——shim 站在 AF_UNIX 服务端（显式端点名 +
  `TYPEPHP_{SHELL_LOG,APP,CWD}`），pristine `launcher-linux` 作客户端；`dev_spawn`/`dev_reap_shim`
  两个函数，watcher 本体沿用 21e 的 OS 无关循环。`launcher-linux.cc` 零改动（pristine 前提保住）。
  `status` 加 Linux 段（三件套 + X display 要求）；`typephp.{backend,app}` 的空值/存在性判断重写成
  `cfg_override`（旧链式 `&&` 在 Linux 分支改写下会把 `TP_ENV` 打成空）；`build` 在 Linux 明确 die 指向 22c。
- **新增验收件**：`test/posix/linux-tgui-window.sh`——驱动**真 CLI**（不是手工 spawn），按
  `[shell] transport=` 头把帧日志切周期，断言 status 两段、cycle1 ≥13/13 + marker + 截图、
  touch→bounce→cycle2 ≥13/13 + marker、关窗后 shim 自行 EOF 退出 + CLI 退出 + socket 清零。
  结果 **PASS**：两轮各 `CALL=14 RET=14`、`shot.png` 108,958B、拆除零残留。
  证据 `evidence/linux/22b-{shim.log,tgui.out,shot.png}`（已从容器取回仓库）。
- **过程教训（六个环境陷阱，全部记入 findings）**：bash 重定向块缓冲（→ `stdbuf -oL`）、
  非交互 shell 无 job control 导致 `kill -TERM -$!` 打死自己（→ `setsid` 必须是 exec 链首环）、
  `pkill -f <路径>` 自匹配、僵尸被 `pgrep` 当活进程（→ 按 `ps stat` 过滤 `^Z`）、
  X socket 文件存在 ≠ display 可用（→ 用真 X client 探测）、`WINDOW-E2E` 每周期两行不能当周期计数。
- **撞出的新缺陷 #25**：dev 模式下 shim `io_accept` 无超时；第一次失败运行里 launcher 连上前就退出，
  shim 挂在 accept，靠 `tgui` 的 5s 有界回收兜住并如实打 warning。打包模式无人兜底 → 修法列入 22c。
- **下一步**：22c `tgui build|publish` 的 Linux 分支 + #25 的 shim 修法（任务 #16）。

## Session 2026-09-27 (5) — Phase 22c：`tgui build|publish` 的 Linux 分支 + #25 的 shim 修法

- **实现**：`gui/bin/tgui` 的 `build` 分支加 Linux 路径（目录式 `dist/<name>/`：entry=shim、
  `<name>.conf`、pristine `launcher-linux`、`frontend/`、`app/{bin,src,gui/php/src}` 逐字节后端镜像、
  conf 里带 `icon=`）；`name` 先洗字符再在第一个 `.` 处截断，保证"目录名=entry名=conf词干"。
  `publish` 重写：有 `zip` 出 `dist.zip`，Linux 无 zip 时出 `dist.tar.gz` 并**按真实格式命名**
  （#11 教训），同时打印字节数。新增 `tools/verify-bundle-linux.sh`（7 组结构检查，构建末尾作 gate）。
- **shim #25 修复**：launch 模式的 accept 换成 `io_accept_watching()`（`poll` 监听 fd + `waitpid`
  launcher 同循环，100ms 一格）；launcher 先死 → 收尸置标记、杀 PHP、`io_close(srv)` +
  `io_cleanup_endpoint()` 后退出，不再留孤儿 socket 文件。顺带给 `io_accept` 补 `EINTR` 重试。
  Windows 分支原样阻塞，未触碰。
- **容器 `tgl` 实测**：`tools/build-linux.sh` 重建**零 warning**，`launcher-linux` 与改 shim 前
  **逐字节相同**（pristine 前提没破）；`tgui build` → 校验 7 组全 PASS（ELF64/aarch64 匹配宿主、
  3 个 exec 位、`#!`→`app_kind=stock`、conf 四 key 复析、镜像 15 文件齐、`app.sock` 42/108、
  `ldd` 无未解依赖）→ 872KB 目录 / `dist.tar.gz` 392KB；**#25 回归**：`env -u DISPLAY`
  直跑 entry → **0s / RC=1**、日志 `launcher exited (status 768) before connecting`、
  socket 与子进程零残留；**dev 回归**：`test/posix/linux-tgui-window.sh` 重跑 **PASS**
  （cycle1/2 各 14 CALL/14 RET + marker、bounce、关窗全链自解）。
  证据 `evidence/linux/22c-*`（build.log / publish.log / nodisplay.{log,out} / dev-shim.log /
  dev-tgui.out / dev-shot.png）已从容器取回仓库。
- **过程中修的两处自伤**：① 平行实现 accept 导致 `io_accept` 变死函数（`-Wunused-function` 抓到）
  → 收敛为 watcher 只 poll、accept 复用；② 给驱动脚本加注释时把注释插在 `A=1 B=2 \` 续行与命令
  之间 → 那两个环境变量静默丢失，表现成"shim 日志 0 周期"的假失败（真实 CLI 一切正常）。
  另外驱动脚本改用 `bash "$ROOT/gui/bin/tgui"` 起 CLI —— 仓库里所有 .sh 都是 100644、README 也是
  `bash gui/bin/tgui …`，之前的 `exec <cli>` 依赖了一个没被版本化的 exec 位。
- **下一步**：22d（任务 #17）= 打包方向在 Xvfb 下的**纯 conf 驱动真出窗**（清掉全部 `TYPEPHP_*`
  env）+ README 验证表/已知限制回写；如实登记"Xvfb 无头 ≠ 真桌面"。

## Session 2026-09-27 (6) — Phase 22d：Linux 打包方向端到端验收 + 全量文档回写（Phase 22 闭环）

- **新增验收驱动 `test/posix/linux-bundle-window.sh`**（6 步，容器 `tgl` 内 **PASS / RC=0**）：
  ① 工具链在场；② `tgui build` → 结构校验 PASS → 把 `dist/` tar 到**仓库外**
  `/tmp/tpgui-22d/dist/TypePHP-Demo`、**删掉仓库 `dist/`**、在 relocation 后的副本上重跑校验
  **18 项 PASS**；③ X 就绪用真 X client（`import -window root`）探测，失败才清 lock/socket 起 Xvfb；
  ④ 直跑入口前 `env -u` 掉全部穿线变量（`TYPEPHP_APP/CWD/BACKEND/APP_KIND/PIPE_NAME`），并用
  `sh -c 'cd / && exec "$1"' _ "$ENTRY"` 把进程 cwd 设为 `/`；⑤ 断言；⑥ 拆除。
- **实测结果**：`CALL=14 RET=14`、`WINDOW-E2E OK ping=pong in 109ms`，逐条对上
  `launch mode conf=<bundle>/TypePHP-Demo.conf`、`app=<bundle>/app/bin/run-backend.php`、
  `app_kind=stock`、`transport=unix-socket pipe=<bundle>/app.sock`、`cwd=<bundle>`、
  `launcher connected`，launcher pid 存活、`app.sock` 在场、`shot.png` 112,327B 是真实渲染的 demo
  窗口（截图里 `cwd` 显示 `/tmp/tpgui-22d/dist/TypePHP-Demo`）。拆除：杀 launcher → 入口**自行退出**、
  `app.sock` 被 unlink、`ps` 过滤 zombie 后零残留。**"仓库 dist 已删 + cwd 为 / + 穿线 env 全空"仍跑通，
  是自包含目前能给出的最强证明**，与 21c 的 mac 验收同口径。
- **dev + touch bounce（22d 的 ② 项）**在 22c 末已随 shim 修复重跑过（`linux-tgui-window.sh` PASS），
  本轮不重复，只并入 README 验证表。
- **文档回写**：README 打包发布段 + 验证表（Linux 打包 22c/22d 两行，22d 行标 **PASS / 18 项断言** +
  109ms + relocation + 清 env + cwd `/` + 零残留）+ 已知限制新增"Linux 打包（22c/22d）的验收边界与
  前置条件"（① Xvfb 无头 ≠ 真桌面，无合成器/WM/托盘；② 目标机需 stock php ≥8.1 在 PATH；③ 需验证器
  打印的 GTK3/webkit2gtk-4.1/ayatana/X11+Xtst `.so`；④ 图标走 conf→`TINYJS_ICON`；⑤ demo 页调用链
  文案写死 Windows 措辞，属外观遗留非缺陷）。task_plan：22d 条目转完成 + Phase 22 转完成 + 头部自检
  数字与 Current Phase 段同步（现剩 21e）。findings 新增"Phase 22d"节（自包含证明法、X 探针、拆除
  契约、结构可分发 ≠ 用户体验）。
- **修 README 时的一次自伤**：一次 Edit 把"Windows 上 `--nano` 是死路"整条 bullet 覆盖掉了 →
  从 `git show HEAD:README.md` 原样取回，并用 `git diff README.md | grep '^-'` 复核删除行。
- **仍未证明**：真桌面会话（只有 Xvfb）；Windows 侧没重编 shim（改动全在 `#ifndef _WIN32` 分支）。
- **下一步**：Phase 22 闭环，全计划只剩 **21e**（Windows watcher 真机验收），阻塞在 Windows 通道。
  改动尚未提交，等用户明确要求再 commit。


## Session 2026-09-27 (7) — 21e：Windows dev bounce 验收驱动 `test/win/dev-bounce.sh`

- **用户本轮指令**：先"查看 21e 阻塞点详情"，再"写个验证脚本"。阻塞点重新定性为四条**只有 Windows
  真机能证**的运行时事实（Git Bash 的 GNU `stat -c` 方言探测确实落到 GNU 分支、touch→kill/respawn
  生命周期、每次 bounce 换新命名管道、以及管道 EOF 拆除链在无反例保护下不泄漏进程），本机
  无 ssh 宿主 / 无 VM / 无 mingw，因此脚本按"现在可静态验证、将来可粘贴即跑"来写。
- **驱动 7 步**：[1/7] 前置（`bash -n gui/bin/tgui`、tasklist/taskkill 在场、从 `build/` 自动补齐
  `build/runtime` 三件套、**回填 `build/app.exe`**（CLI 的 `[ -f "$app" ]` 死门在 `tinyjs.json`
  覆盖之前）、回显解析出的三件套路径、**断言本机 GNU `stat -f '%m'` 被拒而 `-c '%Y'` 可用**）；
  [2/7] 可选 `g++ -std=c++17 -O2 -Wall -Wextra -ladvapi32` 重编 `shim/backend_shell.cpp` 的
  `_WIN32` 分支并以 **0 warning** 为门（缺 g++ 时大声 skip 并在结论里重申缺口，顺带闭掉 22c 留的
  "Windows 侧未重编"）；[3/7] 静默环境；[4/7] 周期 1（`TYPEPHP_SHELL_LOG` 传**原生路径**，PowerShell
  抓屏 best-effort）；[5/7] touch `src/backend.php` → 断言**管道名必须变**、断言 launcher/backend/app
  进程数在两次 bounce 后仍是 **1/1/1**（这是 21e 的承重断言：`dev_reap_shim()` 只在 Linux 生效，
  Windows 只靠管道 EOF 拆除）；[6/7] 第二次 bounce 仍 1/1/1；[7/7] 拆除（taskkill launcher → 零残留 +
  CLI 退出 + `[shell] done`/`launcher closed`）。周期切分沿用 22b/22d 的日志纪律：按
  `^\[shell\] transport=` 分段，**不**用 WINDOW-E2E 行数当周期计数。
- **离线验证（本机造 fake-Windows 工装）**：伪造 `uname/tasklist/taskkill`、用 python3 模拟 GNU `stat`
  方言、伪造 launcher 吐一整个帧周期，跑通脚本全流程 —— 泄漏场景 **FAIL / RC=1**，模拟 EOF 拆除场景
  **PASS / RC=0（3 cycles、zero residue launcher=0 shim=0 app=0）**。证明断言集**有判别力**，
  不等于 Windows 通过。
- **工装挖出我自己脚本的 4 个真 bug**：① `pipe_of()` 贪婪 `sub(/.*pipe=/,"")` 把整行尾巴都吐出来
  → 补 `sub(/ .*/, "")`；② `APP` 硬编码 `demo/backend/app.exe` → 改成与 tgui 完全同序的解析
  （env → `build/runtime/*` + `build/app.exe` → 依赖 php 在 PATH 的 `tinyjs.json` 覆盖）；
  ③ 没有 cleanup trap；④ `cycle_stat/pipe_of` 在 `set -u` 下可能返回空串参与算术。
- **回写**：task_plan 21e 下新增"验收驱动已就位"子条目。README 的 win 单发注记**继续保留**，
  等真机 PASS 同一轮删。改动仍未提交。

## Session 2026-09-27 (8) — 21e 真机闭环（Windows 真桌面，无 Xvfb）

- **结论**：`test/win/dev-bounce.sh` **PASS（7/7 步绿）**。Phase 21 全部完成，README 单发注记已删，task_plan 21e Status→complete、自检计数 24/24/0。
- **跑法**：本机即 Windows（MINGW64 + MSVC BuildTools + WebView2 Runtime）。`bash test/win/dev-bounce.sh` → cycle1 13/13 + WINDOW-E2E + 整 1 launcher + `shot.png` 渲染；bounce（touch `src/backend.php`）→ `sources changed — bouncing`、新 pipe（`\\.\pipe\tinyjs-typephp-<新pid>`）、cycle2 再 13/13 + marker；**两次 bounce 后 launcher/shim/app 仍 1/1/1 无泄漏**；cycle3 同；关窗零残留。证据 `/tmp/tpgui-21e`（tgui.out / shim.log 3 cycles / tasklist 三段 / shot.png）。
- **撞出的两个真机才暴露的缺陷（已修）**：
  1. **WebView2 重发失败（核心 blocker）**：被硬杀的旧 host 留下的 `msedgewebview2.exe` 锁住共享的 per-exe 用户数据目录（原 UDF = `PathCombine(APPDATA, <exe名>)`），下一发 `CreateCoreWebView2Controller` 一直 `ERROR_INVALID_STATE`、60 次重试（12s）全败 → `webview_create` 返回 null → `launcher: failed to create webview`。修复：每次 launch 用独立 `%TEMP%/tinyjs-typephp-<pid>-<rand>` UDF。`launcher-win.cc` 新增 `tinyjs_prepare_webview_udf()`（建目录 + 启动时 best-effort 清掉旧 `tinyjs-typephp-*` 目录 + 置 `TINY_WEBVIEW_UDF`）；`gui/host/include/webview/detail/backends/win32_edge.hh` 的 `embed()` 读取该变量（未设回退原行为）。与库既有的 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` 读取同构。
  2. **`build-launcher.sh` 构建缺陷（干净状态不可复现）**：① `$HOST/runtime/tiny.js` 路径错（实为 `$ROOT/gui/runtime/tiny.js`）→ 改成正确路径；② 缺 webview 头文件的 staged 步骤 → 新增 `[2b/5]` 把 `gui/host/include/webview` 拷进 `build/include/webview`（此前 webview 头靠手工存在，融合后无人下载，f8202d0 后构建实际已断）。现在 Windows 从干净状态可完整复现。
- **附带**：21e 驱动本身上一轮还修了一个 `stdbuf` 守护 bug（`stdbuf.exe` 在 PATH 但 `libstdbuf.dll` 缺失 → `stdbuf -oL bash …` 整条命令起不来）；改为**功能性**探测（`stdbuf -oL true`），不可用就退回无缓冲。已在真机确认 skip 路径生效。
- **改动清单（待提交）**：`gui/host/src/launcher-win.cc`（`tinyjs_prepare_webview_udf` + 调用）、`gui/host/include/webview/`（ vendored 整库，含 `win32_edge.hh` UDF 读取补丁）、`tools/build-launcher.sh`（tiny.js 路径 + webview staged 步骤）、`test/win/dev-bounce.sh`（stdbuf 功能性探测）、`gui/bin/tgui`（21e 代码侧，前几轮已就位）、`README.md`（删单发注记、验证表 Windows 开发方向加 bounce）、`docs/planning/{task_plan,progress,findings}.md`。

## Session 2026-09-27 (9) — 21e 真机闭环后的计划文件校正（本文件 24/24）

- **状态核对**：21e 由 Windows 那台机器（MINGW64 + MSVC BuildTools + WebView2 Runtime）真机跑通并已提交
  （`4e3f0b8` + `5702b14`），工作树干净。本轮只做**计划文件与真实状态对齐**，不新增功能改动。
- **改了什么**：`task_plan.md` 的 Current Phase 段上一轮我写的"下一步动作唯一且明确：去 Windows 跑驱动、
  PASS 后删 README 单发注记、把 Phase 21 改完成"三件事**都已发生**，原样留着会把下一次会话带偏 →
  改写为"24 个阶段全部完成、0 个进行中"，并如实登记 Windows 真机撞出的 WebView2 共享 UDF 锁死修复与
  `build-launcher.sh` 干净态不可复现的修复（tiny.js 路径 + webview 头 staged）。
- **本轮新登记的开口（① 代价最低）**：**21e 的证据没进仓库**。本仓库约定是把验收现场收进
  `evidence/<os>/`（21b 有 `evidence/mac/dev-21b.log`，22c/22d 有 `evidence/linux/*`），而 21e 的
  `tgui.out` / `shim.log`(3 cycles) / `tasklist` 三段 / `shot.png` 现在只在 Windows 机器的
  `/tmp/tpgui-21e`，不取回即丢。README 验证表里的 406ms、1/1/1、零残留目前**只有文字、没有落库证据**。
- **已核实的（不是转述提交信息）**：`gui/host/src/launcher-win.cc` 里 `tinyjs_prepare_webview_udf` 2 处、
  `gui/host/include/webview/detail/backends/win32_edge.hh` 里 `TINY_WEBVIEW_UDF` 3 处，改动确实在树里；
  README 第 16 行的 Windows 开发方向验证表条目 + 191 行的 UDF 说明已替换掉"单发启动"旧措辞（全文再无
  "单发"）。`check-complete.sh` 报 **ALL PHASES COMPLETE (24/24)**，手工三条计数 24 / 24 / 0 与头部自检一致。
- **用户选定下一轮方向 = 补 21e 证据入库**，据此新增 `test/win/collect-evidence.sh`（Windows 那台机器上
  一条命令把驱动现场从 `/tmp/tpgui-21e` 收进 `evidence/win/`）：先**完整性守卫**（`shim.log` / `tgui.out` /
  三份 `tasklist.*.txt` 缺任何一份就 RC=2 拒绝入库，不归档半截证据），再拷成 `21e-` 前缀（丢弃会过期的
  `cli.pid` 与生成的 `shot.ps1`），最后**自己推导**一份 `21e-MANIFEST.txt`：按 `[shell] transport=` 分周期
  报每周期 pipe + CALL/RET + WINDOW-E2E 行数、跨周期管道去重数（复用即判 MISMATCH）、三份 tasklist 的
  launcher/shim/app 计数、`sources changed` 次数、每个文件的 sha256 + 字节数，外加 host 串与运行时的
  `git rev-parse --short HEAD`。`WORK=` / `OUT=` 都可覆盖。
- **离线验证过判别力（全在临时目录，仓库 `evidence/win` 未被写过，`git status` 已核）**：三份管道互不相同
  → `cycles=3 distinct-pipes=3 OK`；人为让 cycle3 复用 cycle1 的管道 → `distinct-pipes=2 MISMATCH`；
  删掉 `tasklist.teardown.txt` → RC=2 且拒绝生成清单。`bash -n` 过。
- **仍未完成**：真正的入库要在**跑过驱动的那台 Windows 机器**上执行本脚本（证据现在只存在于它的
  `%LOCALAPPDATA%\Temp`；本机 `git reflog` 显示 21e 的提交是 `pull origin/main` 进来的，说明两机分开、
  无法从这里取文件）。取回后再把 README 第 16 行与 session (8) 的"证据 `/tmp/tpgui-21e`"改成
  `evidence/win/…` 落库路径。
