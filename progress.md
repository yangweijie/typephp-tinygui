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
