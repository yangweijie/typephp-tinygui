# TypePHP GUI

用**编译成原生二进制的 PHP** 当 [tinyjsapp](https://github.com/tarwin/tinyjsapp) 桌面应用的**后端**，替换掉默认的 txiki.js / JS 模块图。

WebView2 窗口、`window.tiny.*` 页面 API、`CALL`/`RET` 帧协议**全部沿用上游原样**——换掉的只有"谁来应答这些帧"：从 JS 换成 [aot-compiler](https://github.com/layterz/aot-compiler)（`tpc`）编出来的 PHP 单文件 exe。

```php
// src/backend.php —— 演示入口；tpc 编成 app.exe 里的原生机器码
require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';
\Tiny\Gui\Gui::serveDemo();   // 空应用请用 Gui::serve()（不含 api.*）
```

| 验证项 | 结果 |
|---|---|
| POSIX 套件（host probe + tier1/2 + 启动模式 + stderr 隔离） | **50 PASS / 0 FAIL** |
| Windows 开发方向（`tgui dev`，Phase 21e 真机复验） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 416ms`（三次弹窗分别 416 / 370 / 415ms）；`touch` 后端文件 → CLI 打 `sources changed — bouncing` → 新 pipe 重发、整窗 bounce（再 13/13）、launcher/shim/app 仍 1/1/1 无泄漏；关窗零残留（`test/win/dev-bounce.sh` **PASS**，真实桌面、无 Xvfb；现场见 `evidence/win/`，`CHECK=1 OUT="$PWD/evidence/win" bash test/win/collect-evidence.sh` 可从入库文件独立重算核对） |
| Windows 打包方向（双击 `dist\<App>.exe`） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 430ms`（融合后真机复验，含 PE 补丁后的入口） |
| macOS 打包方向（`tools/build-macos.sh --run`，WKWebView + 系统 PHP 后端） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 48ms`；POSIX 套件 **ALL TIERS OK**（Apple Silicon 实机） |
| macOS 开发方向（`tgui dev`，launcher-macos `--typephp`，Phase 21b） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 56ms`；改后端文件 → 窗口闪一下重启（实测新 shim 实例再 13/13）；关窗/退出零残留（Apple Silicon 实机） |
| macOS .app bundle 外部卷双击路径（`test/posix/macos-bundle-launch.sh`，Phase 26） | **22 项断言全 PASS、0 skip**（抓窗那轮）：仓库卷（非启动卷）上的 `dist/TypePHP-Demo.app` 经 `open`（LaunchServices）拉起 → `launcher connected`、**13 CALL / 13 RET**、`WINDOW-E2E OK ping=pong in 103ms`、`screencapture -l<window>` 抓到真窗口（`evidence/mac/26b-window.png`）；shim 日志明写端点搬迁理由（`endpoint moved off the app dir (app dir is not on the boot volume)`），**bundle 目录零新增文件**，关窗后 shim/launcher/socket 全清；直跑入口回归照旧。**负控**：删掉搬迁分支的同一份源码二进制（`CTL_SHIM=`）在**未 consent 过的 bundle id** 下 `open` → 20s 不连接、`sample` 停在 `__bind`、进程 state `S`（即 #21 原症状）。改完 demo 页 chip 文案后复跑一次是 **21 ok / 0 fail / 1 skip**——唯一的 skip 是 A4b 抓不到像素（那台机器的 Screen Recording 授权中途自己掉了），链路文案改由 `test/posix/demo-chain-harness.js` 断言（13 ok；负控 = 只把 Darwin 那一行退回旧写法 ⇒ 恰好 1 条 FAIL）。证据 `evidence/mac/26b-*`、`26c-*`（Apple Silicon 实机） |
| macOS .app bundle（`tgui build` → `dist/<App>.app`，Phase 21c） | `verify-bundle-macos.py` **PASS / 0 warning**；直跑 bundle 入口（无 `TYPEPHP_*` 环境变量，conf 驱动）窗口正常、**13 CALL / 13 RET**、`WINDOW-E2E OK ping=pong in 51ms`、`app_kind=stock`；关 launcher 窗 → shim 干净退出、socket unlink、零残留。该校验现在会**报出端点真实落点**（外部卷 → per-user 临时目录），外部卷的 `open` 路径已单独验收（见上一行，#21 已修）（Apple Silicon 实机） |
| Linux 开发方向（`tgui dev`：shim 当 AF_UNIX 服务端 + pristine `launcher-linux` 当客户端，Phase 22b） | 窗口正常，**14 CALL / 14 RET**，`WINDOW-E2E` marker + `shot.png`；`touch` 后端 → CLI 打 `sources changed — bouncing` → 第二轮再 14/14；杀 launcher → shim 自行 EOF 退出、CLI 退出、dev socket 清零（容器 `tgl` Debian 12 / aarch64 + Xvfb，`test/posix/linux-tgui-window.sh` **PASS**，证据 `evidence/linux/`） |
| Linux 打包 bundle（`tgui build` → `dist/<App>/`，Phase 22c） | `tools/verify-bundle-linux.sh` **全 PASS**（ELF64/aarch64 与宿主一致、3 个 exec 位 + `#!`→`app_kind=stock`、conf 按 shim 语义复析、后端镜像 15 文件逐字节 `cmp`、`app.sock` 42/108B、`ldd` 无未解依赖）；872KB 目录 → `publish` 出 392KB `dist.tar.gz`。**无 X display 直跑入口**：0s 返回 RC=1、shim 日志 `launcher exited (status 768) before connecting`、socket 与子进程零残留（#25 修复的回归证据） |
| Linux 打包 bundle 端到端（`test/posix/linux-bundle-window.sh`，Phase 22d） | **PASS / 18 项断言**：`tgui build` 产物**打包搬出仓库**（`/tmp/.../dist/TypePHP-Demo`）后，清掉全部 `TYPEPHP_*`/`TINYGUI_*` env、进程 cwd 设成 `/` 直跑 entry → 窗口正常、**14 CALL / 14 RET**、`WINDOW-E2E OK ping=pong in 109ms`、`shot.png` 里后端自报 `cwd=/tmp/tpgui-22d/dist/TypePHP-Demo`；关窗（杀 launcher）→ entry 自行退出、`app.sock` unlink、零残留。容器 Debian 12 / aarch64 + **Xvfb 无头**（≠ 真桌面，见已知限制） |
| Linux 真窗口端到端（tier 4：pristine `launcher-linux`，GTK3 + webkit2gtk-4.1，Xvfb 下） | **PASS**：**14 CALL / 14 RET**，`WINDOW-E2E OK ping=pong in 128ms`，截图取证，关窗后 shim 随退出、socket 清零（Debian 12 / aarch64 真 glibc 容器实测，`test/posix/tier4-linux-window.sh`） |
| Linux 真桌面会话（tier 5：Xvfb + **Openbox + picom + 自建 SNI 托盘宿主**，Phase 23） | **PASS**（`test/posix/desktop-session.sh`，容器 `tgl` Debian 12 / aarch64）：**A1** 窗口被 WM reparent（parent `0x400262` ≠ root `0x50d`）、`_NET_FRAME_EXTENTS = 1,1,20,5`，且客户区相对父窗 Y 偏移正好等于标题栏 20px；**A2** picom 持有 `_NET_WM_CM_S0` 选择权（启动前无 owner、窗口映射期间仍有）；**A3** `xdotool windowminimize` / `wmctrl` 最大化 → 各自带回 `WINSTATE minimized/maximized:true` 帧，最大化后客户宽 1440px；**A4** 会话内帧往返 **56 CALL / 56 RET**、`WINDOW-E2E OK ping=pong in 140ms`；**A5** `GDK_SCALE=2` 下 640×400 逻辑窗 = **1280×856 物理像素**；**B1/B2** 托盘项被 SNI 宿主读到（Id/Status/Menu + dbusmenu 五项），点击回 `TRAY tray-hello` 与 `TRAYCLICK`；**B3/B4** `ctrl+alt+shift+F12` → `HOTKEY boss`，F11 与裸 F12 无帧（负控通过）；**X** 零残留、`app.sock`/`app2.sock` 均由 shim 自行 unlink。证据 `evidence/linux/23-*`，`REGEN=1 bash test/posix/collect-desktop-evidence.sh` 可从入库文件独立重算。**同时暴露两个产品缺口**：后端没有 `tray.set` / `hotkey.register`（B 段用 `mock_shim.py` 注入帧驱动），且 `Protocol::decode` 无 `HOTKEY ` 分支 → `type=ignore`，页面永远收不到全局快捷键（C1 记为 GAP 不算通过） |
| Linux `tpc --nano` 体积实测（tier 3） | 5 行程序 freestanding 产物 **1,160,624 B（strip 后 987,208 B）**，`ldd` 仅 libstdc++/libm/libgcc_s/libc —— **无 libphp / 无 php.ini / 无扩展 DLL**，直跑输出 marker、退出码 0（tpc v0.9.3 + php-nano v1.0.1 + phpx v2.9.2，PHP 8.4.25，g++ 12.2；**2026-09-27 实测**——同一份源码重编产物尺寸不逐字节稳定，本机 2026-09-27 复核同一 fixture 得 1,160,600 B，所以引用尺寸必须带日期） |
| Linux `tpc --nano` 收发货后端（tier 6：`tools/aggregate-backend.php` 把 `require` 链聚成单文件，Phase 24；上游归因 Phase 25） | **PASS-with-recorded-GAP**（该轮记录 2 个上游缺口；Phase 25 又量出第 3 个，并**证伪了本轮的一条推断**——见下）：聚合 16 模块 → `build/backend_aggregated.php` 41,995 B/1,223 行（确定性、`--check` 双向、三条拒绝路径、恰好一个全局 `main()`、每模块独立 `namespace` 块），stock PHP 下与多文件树**逐字节同帧**（11 RET）；未聚合的 `src/backend.php` 仍被 `require` 规则拒（负控）。**nano 前端接受聚合产物**（冷缓存 `--dry`：prepare→convert→arginfo 出 3 个 C++ 文件、零 `[cached]`），完整构建停在 **ld**：`undefined reference to php::Args::get(unsigned long) const`——由度量归因给上游（15 行同构造程序链接 1,763,104 B（2026-09-27 该轮，nano 产物尺寸同样不逐字节稳定）**并跑通**，两次构建的 Closure TU `closure-f8759031b18c.o` 逐字节相同、`nm` 都是 define=0/reference=1，只有 240 目标文件那次链接死）。第二坑：**链接 ≠ 能启动**——`echo strlen(…)` 程序干净链接后仍在启动期死于 `Unable to start PHP Nano extensions`。**Phase 25 归因**：该符号只在 `phpx/src/core/extension.cc:278` 有定义而该文件不在 nano 源清单里（搬进已组合 TU 后发货后端确实链起来：6,933,344 B、`ldd` 无 libphp）；启动死的决定条件是 `ZEND_MOD_REQUIRED("Core")` 永远无法被组合数组满足（唯一叫 "Core" 的入口是 `static` 的 `zend_builtin_module`），**聚合体同样中招**——本轮"保留 `basic_functions_module` 就 satisfiable"的说法是错的（它叫 `standard`）；第三坑：nano 二进制没有 stdio 句柄（`STDIN`/`STDOUT` 未定义、`php://` 缺失、`/dev/std*` 打不开），而帧协议全走 stdio，所以 ①②补完仍发不出帧。素材已整理成 `docs/upstream-issues/`（未提交上游）。证据 `evidence/linux/24-*` 与 `evidence/linux/25-*`，`REGEN=1 bash test/posix/collect-tier6-evidence.sh` 独立重算（含 18c–18f 四条修正断言） |
| 打包产物校验 | **0 failure / 0 warning**（融合后复验，`php.exe` + 8 DLL 口径） |

---

## 目录

- [这是什么 / 为什么需要一个 shim](#这是什么--为什么需要一个-shim)
- [目录结构](#目录结构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [如何扩展](#如何扩展)
- [验证](#验证)
- [维护与升级上游](#维护与升级上游)
- [已知限制](#已知限制)

---

## 这是什么 / 为什么需要一个 shim

tinyjsapp 的结构是：**C++ launcher 宿主 WebView2，后端在另一侧应答帧**。上游的正常方向是"后端先起，再拉起 launcher"；本项目反了过来——launcher 是入口，它拉起 PHP 后端。

那么问题来了：**PHP 没法直接讲这个协议。**

- 协议通道是一个**字节模式端点**（Windows 命名管道 / POSIX unix socket）。
- PHP **没有 `pipe://` transport**，`fopen` 打不开命名管道。
- 而真正的 php-nano 运行时**连 socket API 都没有**——`stream_socket_server` / `stream_socket_client` / `fsockopen` / `proc_open` 全在 `NANO_UNSUPPORTED_FUNCTIONS` 里，编译期就 `fatalError`。`vendor/swoole/php-nano/SUPPORTED.md` 的原文是 *"Socket capability remains absent even on POSIX hosts."*

所以 **shim 在三种情形下都省不掉**：Windows 缺 transport、POSIX 真 nano 无 socket API、POSIX bin 模式虽然能服务 socket 但已经不"小巧"了。**"又小又免 shim"的组合不存在。**

`shim/backend_shell.cpp` 就是那个 shim：一个约 900 行的 C++ 小程序，launcher 拉起的其实是它，它再拉起 PHP 后端，在中间做帧转发。

```
              dev 方向                          packaged 方向
        ┌───────────────────┐            ┌───────────────────┐
        │ launcher-win.exe  │            │ <App>.exe (= shim)│  ← 双击这个
        │  (含 --typephp，已  │            │  自己是端点服务端   │
        │   并入自有源码)      │            │                    │
        └─────────┬─────────┘            └─────────┬─────────┘
                  │ 拉起并交出端点                  │ 拉起 STOCK launcher
        ┌─────────▼─────────┐                      │ <html> <endpoint> ...
        │   shim            │                      ▼
        │  帧泵 + stderr 分道│            ┌───────────────────┐
        └─────────┬─────────┘            │ launcher.exe      │
                  │ stdio（行分隔帧）      └─────────┬─────────┘
        ┌─────────▼─────────┐                      │ 匿名管道
        │ app.exe (PHP AOT) │◄─────────────────────┘
        └───────────────────┘
```

> 打包方向里 PHP 后端在 `dist/` 中叫 **`php.exe`**——`tgui build` 特意让它与入口 `<App>.exe`（= shim）**不同名**，否则两者互相覆盖、配置里的 `app=` 还会指回 shim 自己。上图中的 `app.exe` 是 `build/` 目录里的同一份二进制。
>
> `shim/backend_shell.cpp` 头部注释里有更详细的三种通道说明；`docs/` 下有完整的调研与落地记录。

---

## 目录结构

```
typephp-gui/
├── gui/                     ★ 融合后的 GUI 模块（原 tinyjsapp 已并入本仓库，
│                          不再是外部依赖，也不再打补丁）。详见 gui/README.md
│   ├── LICENSE.NOTICE        MIT 归属声明（tinyjsapp + 本项目）
│   ├── host/                 原生 GUI 宿主（vendor + 自有）
│   │   ├── src/launcher-win.cc    WebView2 宿主，--typephp 已并入源码
│   │   ├── src/launcher-{linux,macos}.cc   原生宿主（linux 仍 pristine vendor；
│   │   │       macos 已并入 --typephp 移植，见 launcher-patch-notes.md）
│   │   ├── include/               webview.h / WebView2.h / miniaudio.h
│   │   └── script/gen-client.sh   把 runtime/tiny.js 嵌进 tiny_client.h
│   ├── runtime/tiny.js         window.tiny 客户端 shim（vendor）
│   ├── php/src/Tiny/Gui/        ★ PHP 原生协议框架（融合的核心创新）
│   │   ├── Protocol / Dispatcher / Backend / State / AppRoot / Gui
│   │   └── Handlers/              Core / Win / Menu / Store；DemoApi 仅演示集
│   └── bin/tgui                 dev/build/publish/init/status CLI
│                             （替代上游 cli.js，不再需要 checkout）
├── src/backend.php           演示入口：Gui::serveDemo()
├── bin/run-backend.php       用系统 PHP 直接跑同一份逻辑（不编译也能调试）
├── shim/backend_shell.cpp    C++ 代理。Windows + POSIX 同一份源码
├── tools/
│   ├── build-all.bat          Windows：编 shim + PHP 后端 → build/
│   ├── build-launcher.sh      编 launcher（从 gui/host/src 编）→ build/runtime/
│   ├── build-macos.sh         macOS：编 shim + launcher-macos（拉 webview 头），
│   │                          --run 直接起打包方向 demo（系统 PHP 后端）
│   ├── verify-bundle.py       发布前校验 Windows dist/ 产物
│   ├── verify-bundle-macos.py 校验 macOS .app bundle（plist/Mach-O 架构/conf/资源/
│   │                          端点落点；`tgui build` 在 mac 上会自动调用它）
│   ├── mac-winlist.c          列屏上窗口的 pid/标题/尺寸（CGWindowList）；
│   │                          macos-bundle-launch.sh 用它喂 `screencapture -l<id>`
│   └── e2e/                   截图 / 点窗口 / 关窗口的小工具（ctypes，无依赖）
├── demo/                     一个完整示例（PHP 后端 + tiny.js 前端）
├── test/posix/               POSIX 验证套件（可独立拷出去用；含 macos-bundle-launch.sh
│                             与不依赖屏幕的 demo-chain-harness.js）
├── test/win/                 Windows 开发方向验收：dev-bounce 驱动 + 证据收集器
├── docs/                     调研、落地报告、融合设计 + **VuePress 文档站**
│   ├── .vuepress/config.ts    站点配置（zh-CN、五组侧栏、raw-HTML 转义插件）
│   ├── guide/                 6 页中文导览：上手/架构/协议/平台/后端 API/验证矩阵
│   ├── sync-external.sh       把本 README 与三份套件说明同步成 docs/reference/*.md
│   ├── package.json           站点独立依赖（node >= 22.18，与 PHP 构建无关）
│   ├── GUI_FUSION_DESIGN.md   迁移范围/目标/模块划分/集成/兼容/开发者友好设计
│   └── planning/             开发计划 + 踩坑记录
├── experiments/              历史探针（保留但不参与构建）
│   └── ls-bind-probe/         #21 的根因量具：三步判据（普通文件/bind//tmp bind）
│                              × 四种起法（直跑/`open` × 启动卷/外部卷）
├── evidence/                 验证证据：e2e 截图/日志 + 套件日志
├── build/                    所有生成物，git 忽略
├── composer.json             type=project 模板（非 Packagist 库）；PSR-4 + php smoke
└── .monkeycode/docs/         DeepWiki 风格架构/接口/开发者指南
```

`build/` 里有什么：

```
build/
├── backend_shell.exe   shim
├── app.exe             PHP 后端（tpc 编出来）
├── *.dll               app.exe 依赖的 6 个 PHP 运行时 DLL（约 15.5MB）
├── launcher-win.exe    原生宿主（从 gui/host/src 编，已含 --typephp）
├── runtime/            launcher + backend.exe + app.exe + 2 个 MinGW 运行时 DLL，可直接跑
├── gen/                staging 出的 launcher-win.cc、tiny_client.h
└── winrt-shim/ include/ 下载的构建依赖，跨次缓存
```

`build/` 下**唯独不包含**那份 PHP 运行时 DLL 的第二份副本——`demo/backend/` 里那份是从 `build/` 拷的，不是从 tpc 发行包再拷一次。

---

## 环境要求

| 用途 | 需要什么 |
|---|---|
| 后端编译 | aot-compiler 发行包（`tpc.exe`，本项目用 v0.9.3）+ MSVC（vcvars64） |
| shim 编译 | MinGW-w64 g++（`g++ -std=c++17`） |
| launcher 编译 | 同上 + 联网（下 WinRT 头文件和 `WebView2.h`，之后走缓存） |
| 运行 | Windows + WebView2 Runtime（Linux/macOS 走各自 WebKit） |
| 系统 PHP 调试（可选） | **PHP ≥ 8.1**（`array_is_list` 等） |
| POSIX 套件 | Linux / macOS / Cygwin + gcc/g++ + python3 |

路径都可用环境变量覆盖，不写死：

```bash
TPC_HOME=D:\git\php\tpc_v0.9.3_windows_x64   # tpc 发行包
TINYGUI_LAUNCHER=$PWD/build/runtime/launcher-win.exe   # 可选，覆盖 launcher 路径
TYPEPHP_BACKEND=$PWD/build/backend_shell.exe           # 可选，覆盖 shim 路径
TYPEPHP_APP=$PWD/build/app.exe                        # 可选，覆盖 PHP 后端
TYPEPHP_APP_ROOT=$PWD                                 # 可选，listDir/fs.* 沙箱根（默认 getcwd）
VCVARS="D:\...\VC\Auxiliary\Build\vcvars64.bat"
```

---

## 快速开始

### 0. 准备构建工具链

需要：aot-compiler 发行包（`tpc.exe`，本项目用 v0.9.3）、MSVC（`vcvars64`）、MinGW-w64 `g++`、联网（首次下 WinRT 头与 `WebView2.h`，之后走缓存）。**不再需要任何外部 tinyjsapp checkout，也不需要打补丁**——GUI 宿主已经是本仓库的 `gui/host/src/launcher-win.cc`（含 `--typephp`）。

### 1. 构建

```bash
# 原生宿主（launcher-win.exe + runtime 三件套）→ build/
bash tools/build-launcher.sh

# Windows：shim + PHP 后端 → build/
tools\build-all.bat
```

`tools/build-launcher.sh` 每次都会从 `gui/runtime/tiny.js` 重新生成 `gui/host/src/tiny_client.h`，所以改了 `tiny.js` 只需重跑它。

### 2. 开发运行

```bash
cd demo
bash ../gui/bin/tgui dev
```

`tgui dev` 会解析 `demo/tinyjs.json`、设置后端环境变量（`TYPEPHP_BACKEND` / `TYPEPHP_APP` / `TYPEPHP_CWD` / `TINYJS_ICON`），然后拉起 `launcher --typephp <html> <title> <size> <ver>`。**macOS（Phase 21b）/ Windows（Phase 21e）共用同一条生命周期链**：CLI 监视 `src/**` 与框架 PHP 源码，任何改动 kill 掉 launcher 再重拉——窗口闪一下即后端重启（含 frontend 文件，同样是整窗 bounce；shim 靠端点 EOF 自己回收 PHP，实测零残留）。Windows 侧为此还修了一个 WebView2 坑：每次 launch 用独立的 `%TEMP%/tinyjs-typephp-<pid>-<rand>` 用户数据目录（`TINY_WEBVIEW_UDF`，`gui/host/include/webview/.../win32_edge.hh` 读取），否则被硬杀的旧 host 留下的 `msedgewebview2.exe` 会锁住共享的 per-exe UDF，导致下一发 `CreateCoreWebView2Controller` 一直 `ERROR_INVALID_STATE`、最终 `webview_create` 返回 null。

调试输出**写 STDERR**：shim 给 stderr 单独一条管道，只抄进自己的日志，永远不混进帧流。看日志：

```bash
TYPEPHP_SHELL_LOG=D:/tmp/shim.log bash ../gui/bin/tgui dev
tail -f D:/tmp/shim.log
```

> 往 **STDOUT** 上写任何非帧内容都会变成协议垃圾——STDOUT 就是帧通道。

### 3. 打包发布

```bash
cd demo
bash ../gui/bin/tgui build      # → demo/dist/
bash ../gui/bin/tgui publish    # → 再压成 dist.zip（带回退 tar.gz）
python ../tools/verify-bundle.py dist \
       --launcher ../build/runtime/launcher-win.exe
```

产物（Windows）：`dist/<App>.exe`（= shim，双击入口；`tgui build` 会自动用 `launcher --embed-icon` 把图标刻进 PE 资源、并把 PE `Subsystem` console→GUI，双击不挂黑框——这两步是旧 cli.js 的出货级修法 #10，融合 CLI 已接回）、`launcher.exe`、`php.exe`（PHP 后端，与入口不同名）、8 个 DLL（6 个 PHP 运行时 + 2 个 MinGW 运行时）、`frontend/`、`dist/<App>.conf`。

**macOS（Phase 21c）**：同一条 `bash ../gui/bin/tgui build` 走 Darwin 分支，产出 `dist/<App>.app`——`Contents/MacOS/<App>`（= shim，改名不带点，因为 shim 的 `stem_of()` 在**第一个** `.` 处截断，带点会错配 conf）、`<App>.conf`、`launcher-macos`、`Resources/frontend/`、`Resources/app/`（后端 PHP 源码逐字节镜像，`__DIR__` require 链原样生效）、`Resources/AppIcon.icns`（`sips`+`iconutil`，对应 win 侧 PE 图标刻录）、`Info.plist`（含 TCC 相机/麦克风/语音用途声明）。构建末尾自动跑 `tools/verify-bundle-macos.py` 校验。注意：mac 打包走**系统 PHP**（shebang 脚本，目标机 PATH 需有 php）。曾经的外部卷限制（#21）已经修掉：LaunchServices 拉起的应用在**非启动卷**上创建第一个新文件会卡在 TCC 卷授权里，所以 shim 在 launch 模式下会先问「app 目录和 `/` 同卷吗」，不同卷就把 AF_UNIX 端点放进 per-user 临时目录（`$TMPDIR/tinyjs-typephp-<pid>.sock`）并在日志里写明搬迁原因——bundle 目录不再被写入任何东西，外部卷上的双击/`open` 与启动卷上等价（`test/posix/macos-bundle-launch.sh` 实机 22 项断言，含 pre-fix 负控）。直跑 `Contents/MacOS/<App>` 走同一条规则。

**Linux（Phase 22a–22c）**：先 `bash tools/build-linux.sh`（产出 `build/backend_shell` + `build/launcher-linux`；缺 GTK3 / webkit2gtk-4.1 / ayatana-appindicator3 时**点名缺哪个包**，appindicator 是硬依赖，见 #23），再同一条 `bash ../gui/bin/tgui build` 走 Linux 分支，产出**目录式** bundle `dist/<App>/`：`<App>`（= shim，改名后的双击入口，同样在第一个 `.` 处截断）、`<App>.conf`（`html` / `app` / `launcher` / `icon` 全是相对该目录的路径）、`launcher-linux`（**pristine——分发里不含任何 `--typephp` 补丁**）、`frontend/`、`app/`（后端 PHP 源码逐字节镜像，`__DIR__` require 链原样生效）。构建末尾自动跑 `tools/verify-bundle-linux.sh`：ELF 头/架构、exec 位 + `#!`（shim 无 argv `execv` 它，这两项是载荷性的）、conf 按 shim 语义复析、镜像完整性逐文件 `cmp`、`app.sock` 是否超 `sun_path` 108B、`ldd` 未解依赖 + 目标机 `.so` 清单。目标机需要：PATH 里有 stock php、GTK3 + webkit2gtk-4.1、一个 X display（容器里是 Xvfb；真桌面行为另在 Phase 23 的 Openbox + picom + SNI 宿主会话下验收，见验证表 tier 5）。`publish` 在没有 `zip` 的机器上出 `dist.tar.gz` 并**按真实格式命名**，不会伪装成 zip。dev 方向的 Linux 与 win/mac **方向相反**：shim 站 AF_UNIX 服务端、原版 `launcher-linux` 作客户端（`tgui dev` 内部编排，`launcher-linux.cc` 一个字节不改）。

### 4. 新建一个项目

```bash
mkdir my-app && cd my-app
bash ../gui/bin/tgui init       # → tinyjs.json + src/frontend/index.html
# 然后按上面的「构建」「开发运行」两步跑
```

---

## 工作原理

### 帧协议（逐字对齐 `runtime/bridge.js` 与 `launcher-win.cc`）

帧 = **一行**，`\n` 分隔。

**launcher → backend**

| 帧 | 含义 |
|---|---|
| `CALL <id> ["<payload>","<origin>"]` | 页面调后端。`payload` 是 `{"method":...,"params":{...}}`。能解析出 `id` 但 payload 非法时仍回 `RET <id> 1`，避免对端挂起 |
| `WINSTATE <win> <json>` | 窗口状态（通知）；后端缓存后 `EVAL` 推页面 |
| `SYS theme light\|dark` / `SYS <kind>` / `SYSLOCALE <json>` | 主题、睡眠等、语言 |
| `MENU <id>` / `TRAY <id>` / `TRAYCLICK` | 菜单、托盘点击 |
| `NAV` / `DROP` / `HOTKEY` / `GOT` / … | 核心框架忽略 |

**backend → launcher**

| 帧 | 含义 |
|---|---|
| `RET <id> <status> <json>` | 应答，`status` 0=ok 非 0=错误。`json_encode` 失败时改为 status 1，不会把字面量 `false` 写进帧 |
| `TITLE <text>` / `SIZE <w> <h>` / `QUIT` | 窗口控制。**必须在 `RET` 之前发** |
| `EVAL <js>` / `EVAL@<win> <js>` | 在页面里跑 JS（事件推送就走这条） |
| `DLG <id> <op>\t<args>` | 原生对话框 |
| `MENUBEGIN … MENU/ITEM/SEP/SUB … MENUEND` | 整块声明菜单栏 |

关键区别：`dialog.*` 只发 **`DLG`、不发 `RET`**（和 `bridge.js` 里 `if (dlg) { send(...); return; }` 一致）。`menu.set` 先发 `MENU*` 块，**再发 `RET`**。因此 shim 不能做成严格的一问一答泵，必须是**非阻塞双向轮询**。

### 三条 stdio 通道，不是两条

```
stdin   ← launcher 帧         stdout → launcher 帧      ← 这才是帧通道
stderr  → 只进 shim 日志（`[shell] backend stderr: …`），永不转发
```

这一点踩过坑：早期 `spawn_proc` 把 `stderr` 接到了 `stdout`，也就是**接到了帧通道上**。任何 PHP warning / notice / `var_dump` 都会变成协议垃圾。之所以一直没暴露，是因为 launcher 会静默忽略不认识的帧。

还有一条**机械性**理由：匿名管道没被读就会在约 **64KB** 处堵住，然后**写端永久阻塞**。所以排空 stderr 不是卫生问题，是必要条件——shim 在泵循环的每个空闲 tick 里都会排空它（带界限的自旋，避免后端刷屏饿死帧泵）。

### 开发方向 vs 打包方向

|  | dev | packaged |
|---|---|---|
| 入口 | 打了补丁的 `launcher-win.exe` | `<App>.exe`（= **shim**） |
| 谁建端点 | shim | shim |
| 谁拉起谁 | launcher 拉 shim，shim 拉 PHP | shim 拉**原始** launcher `<html> <endpoint> …`，再拉 PHP |
| launcher 补丁 | 需要 | **不需要**（走 stock 参数契约） |
| `TYPEPHP_BACKEND` | 由 launcher 传给 shim | 不需要 |

打包方向之所以不需要补丁，是因为它走的是上游本来就支持的"`<html> <endpoint>`"参数形式；补丁只是额外加了一个 `--typephp` 模式，两者互不干扰。

---

## 如何扩展

### 加一个后端方法 ← 最常见

实现一个 handler，或调用 `$d->on(...)`。**不需要改动任何中心函数**：

```php
use Tiny\Gui\{Gui, State, Dispatcher, Response, Request};

require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';

$s = new State();
$d = Gui::defaultDispatcher($s);          // 空应用：Core/Win/Menu/Store（不含 DemoApi）
$d->on('demo.greet', function (Request $req): Response {
    $who = (string)($req->params['name'] ?? 'world');
    return Response::ok("hello, {$who}");   // 结果会被 Protocol::jenc 进 RET
});
Gui::serveWith($d, $s);

// 演示 API（api.fib / api.echo / …）不要放进空应用：
// Gui::serveDemo();  或  Gui::demoDispatcher($s)
```

想一次认领多个方法，实现 `Tiny\Gui\HandlerInterface`（`methods()` 返回方法名数组，`handle()` 返回 `Response`，返回 `null` 则放行给下一个 handler）。

页面侧直接调，**不需要动任何别的东西**：

```js
const r = await tiny.api.call('demo.greet', { name: '老杨' });   // 注意是 tiny.api.call
// 或者用底层绑定（tiny.js 内部就这么包）：
await window.__invoke(JSON.stringify({ method: 'demo.greet', params: { name: '老杨' } }));
```

要推事件给页面（不是应答），在 handler 里往 `Response` 的 `frames` 里塞一条 `EVAL`：

```php
use Tiny\Gui\{Protocol, Response, Request};

$d->on('demo.progress', function (Request $req): Response {
    // 页面 tiny.api.on('progress', fn) 会收到这条 EVAL
    return Response::ok(true, [Protocol::event('progress', ['pct' => 42])]);
});
```

`Response::ok($result, $frames)` 中 `$result` 进 `RET`；`$frames` 是在 `RET` **之前**发出的裸帧（`TITLE`/`SIZE`/`EVAL`/`QUIT` 等）；抛异常 → `status=1`，异常消息进 `result`。

### 加一种帧类型

先问一句：**stock launcher 认不认这个帧？**

- **认**（`TITLE`/`SIZE`/`EVAL`/`EVAL@`/`QUIT`/`DLG`/`MENU*`）→ 在 handler 里往 `Response` 的 `frames[]` 塞对应裸帧即可。**打包方向完全不受影响。**
- **不认** → 要改 `gui/host/src/launcher-win.cc`（已是我们自有源码，直接改、不再有补丁文件），并在 `gui/php/src/Tiny/Gui/Protocol.php` 里补对应的编解码。代价：打包产物里的 `launcher.exe` 就不再是原版了。功能仍然正常——`--typephp` 模式保留了 stock 参数契约——但 `verify-bundle.py` 的"与构建源逐字节一致"只是相对我们自己而言。

所以：**能用现有帧就别加新帧。**

### 加一个页面 API（`tiny.xxx`）

`window.tiny` 是 launcher 把 `runtime/tiny.js` **编译进自身**后注入的（经 `gen/tiny_client.h` 嵌入）。这意味着：

1. 改 `runtime/tiny.js`（上游文件）加新 helper；
2. **必须重建 launcher** —— `tools/build-launcher.sh` 每次都会重新从 `runtime/tiny.js` 生成 `tiny_client.h`，所以重跑一遍就行。

如果只是"页面想调后端某个方法"，别走这条路——见上一节，`tiny.api.call()` 已经够了，加 `tiny.xxx` 只是语法糖。

### 给后端加状态 / 文件访问

框架的 `StoreHandler`（`store.get` / `store.set` / `store.all`）用的是进程内数组（演示用途）。`store.set` **必须带非空 `key`**，否则 RET status 1，不会写入空键。要持久化就自己接 SQLite / 文件——**注意**真 nano 模式下 `getenv` / `gethostname` 都在 `NANO_UNSUPPORTED_FUNCTIONS` 里、编译期就 `fatalError`，别用；读环境变量用 `$_SERVER[...] ?? $_ENV[...]`（CLI 的 `variables_order` 把环境放进 `$_SERVER`），框架内已统一成这一种写法。

`listDir` / `fs.list` / `fs.readText` / `fs.writeText` / `fs.exists` / `fs.stat` / `app.root` 走 **`AppRoot` 沙箱**：根目录为 `TYPEPHP_APP_ROOT`，未设置则 `getcwd()`。路径必须等于根或位于其下，`..` 越界拒绝。`fs.writeText` 的父目录必须已在沙箱内存在。这些方法在**空应用默认集**里（CoreHandler），与 DemoApi 无关。

### 支持一个新平台（Linux / macOS）

边界已经画好了，在 `shim/backend_shell.cpp` 里换掉三个东西：

| 抽象 | Windows | POSIX |
|---|---|---|
| `io_t` | `HANDLE` | `int` fd |
| `io_create_server` | `CreateNamedPipeW` | `socket(AF_UNIX)` + `bind`/`listen` |
| `io_accept` | `ConnectNamedPipe` | `accept` ← **返回新 fd，不是同一个句柄** |
| `io_read_avail` | `PeekNamedPipe` | `poll` + `read` |
| `spawn_proc` | `CreateProcessW` | `fork` + `dup2` + `execv` |

两个已经写进注释的坑：

- **POSIX 可见性宏必须在所有 `#include` 之前。** `-std=c++17` 会定义 `__STRICT_ANSI__`，libc 就把 `readlink`/`kill`/`setenv` 藏起来。glibc 上 g++ 会替 C++ 注入 `_GNU_SOURCE`（所以 Linux "碰巧能编"），Cygwin/newlib 不会。
- **Cygwin 的 CPython `AF_UNIX` 和原生 `AF_UNIX` 不是一回事。** 实测矩阵：C 服务端 + Cygwin-Python 客户端 → 客户端 `connect()` **成功**但服务端 `accept()` 报 `ECONNABORTED(113)`；反过来 Python 服务端 + C 客户端 → Python `accept()` "成功"但读到不相关的垃圾，C 客户端拿到 `ECONNREFUSED`。C↔C 和 Python↔Python 都正常。**所以跨运行时语言测 unix socket 会得到假结果。**

`--typephp` 现在 `launcher-win.cc` 与 `launcher-macos.cc` 都有（win 是融合时并入；mac 是 Phase 21b 按 `docs/launcher-patch-notes.md` 的 Hunk A–E 同构移植，从此 **macOS 不再是 pristine vendor**，"与上游逐字节一致"仅相对本仓库），所以 **dev 方向 Windows + macOS 都已真窗口跑通**；`launcher-linux.cc` 保持 pristine（**不**移植 `--typephp`），Linux 的 dev 方向因此**反过来**编排：`tgui dev` 让 shim 站 AF_UNIX 服务端、原版 `launcher-linux` 作客户端 —— 该方向已于 Phase 22b 在容器内 Xvfb 下真窗口跑通（14 CALL / 14 RET + `WINDOW-E2E` marker + touch→bounce 复验）。打包方向同样 macOS 已跑通：入口是 shim，拉 stock `<html> <socket>` 契约的 `launcher-macos`，后端用系统 PHP 的 shebang 脚本。一条命令：`bash tools/build-macos.sh --run`（实测 13 CALL / 13 RET、`WINDOW-E2E OK ping=pong in 48ms`；dev 方向见 `evidence/mac/dev-21b.log`）。Linux 打包方向：`bash tools/build-linux.sh` + `bash ../gui/bin/tgui build`（Phase 22c，产物布局与结构校验见上文「打包发布」）；其**真窗口端到端**在手工编排下已 PASS（tier 4：14/14 帧 + 128ms marker），用 `tgui build` 产出的 bundle 直跑也已于 **22d 在容器 Xvfb 下验收 PASS**（14/14 帧 + 109ms marker，搬出仓库 + 清空穿线 env 后仍通过，见验证表与已知限制）。

### 后端为什么还是"一个文件"编译出来

`tpc` 编译的是**单个入口文件**：`main()` 由编译器自动调用（所以系统 PHP 下要 `bin/run-backend.php` 手动调一次）。早期 `src/backend.php` 是过程式单文件；融合后它变成薄入口，逻辑拆进了 `gui/php/src/Tiny/Gui/*` 一整套类。这些类通过 `bootstrap.php` 的 `require` 被拉进同一个编译单元——**已验证 tpc 会跟着 `require` 递归编译**，所以现在既是清晰的多文件框架，又仍能编成单个 `app.exe`。

`tpc` 仍然只认入口文件的 `require`：框架靠 `bootstrap.php` 顺序装载。`composer.json` 另有 PSR-4 `Tiny\\Gui\\`，方便系统 PHP / IDE；**AOT 路径不要只靠 autoload**。本仓库是 **`type: project` 应用模板**，不是可 `composer require` 的库。

---

## 验证

### POSIX 套件（一条命令，一份证据）

```bash
php gui/php/test/smoke.php      # 或 composer test / composer smoke（Windows 可用）
bash test/posix/all.sh          # POSIX 套件（bash；未挂到 composer）
```

它在 Cygwin / Linux 上依次跑：宿主原语探测 → tier1（shim 对 mock 后端）→ tier2（对**真 PHP 后端**）→ 启动模式 → stderr 隔离。全部通过的输出是：

```
  PROBE_RC=0
  RESULT: 11 passed, 0 failed     POSIX BRANCH OK        TIER1_RC=0
  RESULT: 11 passed, 0 failed     POSIX BRANCH OK        TIER2_RC=0
  RESULT: 13 passed, 0 failed     PACKAGED-ENTRY MODE OK LAUNCH_RC=0
  RESULT: 15 passed, 0 failed     STDERR CHANNEL OK      STDERR_RC=0

ALL TIERS OK
```

退出码：`0` 全绿 / `1` 有失败 / `2` 工具链缺失（PHP、后端缺失等会**跳过**并说明怎么补，而不是拿一个你没选的路径报错）。

证据落在 `evidence/kit/<host>-all.log`，头部带 `backend_shell.cpp` 的 sha256，所以能和源码对上号。套件也可以整份拷出去独立用（它靠 `composer.json` 判断自己在不在仓库里，见 `test/posix/resolve-root.sh`）。

**最有价值的一档是 stderr 隔离**：它用一个"敌对后端"往 stderr 写一条伪装成 `RET` 的诱饵，然后断言客户端**一行都没收到**；同时跑一个把诱饵挪到 stdout 的**阳性对照**，断言客户端**必须失败**。只做前者的话，测试全绿也可能只是因为诱饵压根没发出去。

### Windows 端到端

```bash
# 开发方向
cd demo && TYPEPHP_SHELL_LOG=../evidence/e2e/dev.log bash ../gui/bin/tgui dev
# 打包方向
cd demo/dist && TYPEPHP_SHELL_LOG=D:/abs/path/packaged.log "./TypePHP-Demo.exe"
#   ^ 两个坑：name 含空格会被 tgui 净化成连字符（TypePHP-Demo.exe，无空格）；
#     TYPEPHP_SHELL_LOG 必须是原生 Windows 路径（D:/...）——原生 shim 解析不了
#     Git-Bash 的 /d/... 形式，fopen 失败时日志静默为空。
```

判定依据（都在 shim 日志里）：

- 出现 `WINDOW-E2E OK ping=pong in <ms>`；
- `backend stderr: [php-backend] "WINDOW-E2E OK …"` —— **同时证明了 stderr 隔离仍然成立**（这行是老 shim 里会变成假帧的地方）；
- `CALL` 数与 `RET` 数相等，且没有非 0 的 `RET`；
- 结尾是 `launcher closed` → `closing` → `done`，之后**无残留进程**。

### 打包产物

```bash
python tools/verify-bundle.py demo/dist --launcher build/runtime/launcher-win.exe
```

查四件 `tgui build` 自己不会告诉你、但每件都出过错的事：入口是不是 **GUI 子系统**（CUI 会让双击后一直挂个黑框）、入口有没有**图标资源**（`.conf` 里的 `icon=` 只管运行时窗口/任务栏）、`dist/launcher.exe` 是否和拷来的那份逐字节一致、`php.exe` + 8 个 DLL（6 个 PHP 运行时 + 2 个 MinGW 运行时）+ conf + frontend 是否齐全。

---

## 维护与升级上游

宿主（`gui/host/src/launcher-win.cc` 等）和客户端（`gui/runtime/tiny.js`）现在都是**本仓库自有副本**，受 MIT 约束（归属见 `gui/LICENSE.NOTICE`）。不再是外部 checkout + 树外补丁：

- `--typephp` 的 4 个 hunk 已**直接并入** `launcher-win.cc` 源码，由 git 跟踪，不再有 `patches/*.patch` 文件。
- `cli.js`（JS CLI）已被 `gui/bin/tgui`（bash）彻底取代，已从仓库移除。
- `bridge.js`（JS 后端桥）已被 `gui/php/src/Tiny/Gui/*` 取代。

**升级到新版本上游：**

```bash
TAG=v0.43.0
# 重新 vendor 宿主源码（覆盖自有副本；--typephp 改动作为普通提交 rebase 进来）
curl -fsSL "https://xget.fnthink.top/gh/tarwin/tinyjsapp/raw/$TAG/native/launcher-win.cc" \
  -o gui/host/src/launcher-win.cc
curl -fsSL "https://xget.fnthink.top/gh/tarwin/tinyjsapp/raw/$TAG/runtime/tiny.js" \
  -o gui/runtime/tiny.js
bash tools/build-launcher.sh        # 重新生成 tiny_client.h 并编译
php gui/php/test/smoke.php           # 验证线格式仍与宿主对齐
```

`xget.fnthink.top` 是 GitHub 加速，国内直连 `raw.githubusercontent.com` 不可靠。

**把 `--typephp` 改动并入新版宿主时**，用 `git` 的 3-way merge 对齐那 4 个 hunk（集中在 spawn 后端与参数解析处），一般能直接合。验证：

```bash
bash tools/build-launcher.sh && php gui/php/test/smoke.php
```

注意：早期 `--typephp` 模式依赖上游 `cli.js` 的 `ensureLauncherFresh()` 在启动时重跑 `setup.ps1`（Windows SDK 的 WinRT 头）。融合后宿主由 `tools/build-launcher.sh` 编译、`build/winrt-shim` 提供 overlay，与上游 `setup.ps1` 无关，不再有这条联动。

---

## 已知限制

- **`--typephp` 只存在于 Windows 与 macOS 的 launcher；Linux 用反向编排达到同一效果。** `launcher-win.cc` 与 `launcher-macos.cc` 都实现了 `--typephp`（mac 侧为移植，不再 pristine）；`launcher-linux.cc` 保持 pristine，所以 Linux 的 dev 方向由 **shim 当 AF_UNIX 服务端 + 原版 launcher 当客户端**（`tgui dev` 的 Linux 分支，Phase 22b）——热重启、关窗回收、socket 清零与 win/mac 同构，容器内真窗口实测 14/14 帧 + marker。打包方向的 **Linux 真窗口端到端也已于 tier 4 实测 PASS**（2026-09-27，GTK3/WebKit2GTK + 同一 shim + stock PHP，14/14 帧 + 128ms marker），不再是"只有 headless 证据"；`tgui build` 的 Linux 产物（`dist/<App>/` + `tools/verify-bundle-linux.sh` 结构校验，Phase 22c）已于 **22d 完成 bundle 直跑验收**：搬出仓库、清空 `TYPEPHP_*` env、进程 cwd 设为 `/` 仍 14/14 帧 + 109ms marker、关窗零残留。
- **`tgui build` 现已覆盖 Windows（dist/ 目录 + PE 图标/子系统补丁）和 macOS（.app bundle + icns + plist + 自动校验，Phase 21c）。** mac 侧限制：① 后端是 shebang 脚本，目标机 PATH 必须有 php（不做 win 那种 DLL 自包含）；② 不做 codesign 打包签名，而且**当前布局根本封不起来**：`<App>.conf` 和 `launcher-macos` 与入口二进制同处 `Contents/MacOS/`，`codesign --force --sign - <App>.app` 实测报 `code object is not signed at all / In subcomponent: …/Contents/MacOS/App.conf`——conf 得挪到 `Resources/`（并让 shim 两处都找）才谈得上 Developer ID + 公证，这是候选 ④ 的第一块前置砖；本机跑靠二进制自带的链接器 ad-hoc 签名。③ 曾经的"外部卷 `open` 永久挂起"（#21）**已修**：不是 `bind()` 特异，而是 LaunchServices 拉起的进程在非启动卷上**创建第一个新文件**就会阻塞在 `open(O_CREAT)` 等 TCC `kTCCServiceSystemPolicyRemovableVolumes` 授权（普通文件同样卡，`experiments/ls-bind-probe` 量过），shim 现在检测到 app 目录不在启动卷就把端点放进 `$TMPDIR` 并记日志。修完剩下的边界：Windows 侧本轮**未重编**（新代码在 `#if defined(__APPLE__)`/`#ifndef _WIN32` 内，命名管道分支不受影响，但没跑过实机）；被 `SIGTERM`/`kill -9` 打断的 shim 仍会留下端点文件（只有"关窗"这条正常路径 unlink），临时目录里的陈旧 `.sock` 由下次启动覆盖，不影响功能。
- **Windows 上 `--nano` 是死路。** 它不是真 nano，而是 `bin` 策略包装：`NanoBuildBackend::forHost('Windows')` 硬编码返回 `WINDOWS_DLL`，所以链接的不是 freestanding php-nano，而是完整 PHP/PHPX DLL。实测产物依赖与 bin 版**完全相同**（15.5MB），体积只小 1.5%，而且 teardown **必定 SIGSEGV(139)**。小巧路线只在非 Windows 存在，前置条件（后端不再调 `getenv`/`gethostname`）已于 Phase 24 满足：`AppRoot::fromEnv()` 与 `CoreHandler::backend_kind()` 都改读 `$_SERVER` → `$_ENV`，tier 6 的 `--dry` 能过 nano 前端就是这条已过验证。
- **Linux 打包（Phase 22c/22d）的验收边界与前置条件。** ① 全部 Linux 证据来自 **Apple Container 里的 Debian 12 / aarch64 + Xvfb**。Xvfb 本身没有合成器/窗口管理器/托盘，所以 Phase 23 在容器里**另起了真桌面**（Openbox + picom + 自建的 SNI `StatusNotifierWatcher`）并把"WM 管理、合成器、最小化/最大化回传、托盘注册与点击、全局快捷键、高 DPI"逐项验了（见验证表 tier 5 那行）；仍然没被证明的是**真硬件/真 DE** 行为：GPU 合成、Wayland 会话、GNOME/KDE 自带托盘里的实际观感、分数缩放（`GDK_SCALE=1.5`）、与真实桌面冲突的热键抢占。② 后端是 shebang 脚本，**目标机 PATH 必须有 stock php >= 8.1**（Linux 没有 tpc/AOT 自包含后端，见 tier 3 那条）；③ `launcher-linux` 是动态链接的，目标机必须提供 GTK3 + webkit2gtk-4.1（或 4.0）+ ayatana-appindicator3 + X11/Xtst 这一组 `.so`——`tools/verify-bundle-linux.sh` 会把这份清单直接打出来，不是"大概需要 GTK"；④ 图标走 conf `icon=` → `TINYJS_ICON`（launcher 读环境变量），没有 win 的 PE 刻录也没有 mac 的 icns；⑤ demo 页面的链路标签**不再写死 Windows 措辞**（原先是 `WebView2`、`\\.\pipe\...`、`backend_shell.exe`，在 mac/Linux 截图里属于文案而非运行时事实）：现在由 `chainFor(sysinfo.os, sysinfo.backend)` 在后端上报后填充，⑤ 那格取 shim 注入的 `TYPEPHP_APP_KIND`，所以 mac dev（stock php 直跑）会显示"未经 AOT"而不会自称 AOT。
- **Linux 桌面集成有两个产品缺口（Phase 23 实测暴露，尚未修）。** ① 后端 `gui/php/src/Tiny/Gui/Handlers/*` 有 `menu.set` / `win.*` / `fs.*` / `store.*` / `api.*`，**没有 `tray.set` 也没有 `hotkey.register`**：launcher 两端语法都实现了、shim 也会泵这两种帧，但应用层没有任何 API 能发出它们（tier 5 的 B 段因此用 `mock_shim.py` 注入"有这个 API 时会发的帧"）。② `Protocol::decode` 认 `TRAY`→`tray`、`TRAYCLICK`→`trayclick`，**却没有 `HOTKEY ` 分支**（返回 `type=ignore`），所以即使补上 ①，全局快捷键也到不了页面。另有一个已修的构建缺口：`tools/build-linux.sh` 过去链了 `-lX11 -lXtst` 却**没定义 `-DTINYJS_X11`**，而该宏门住 `parse_combo`/`xtest_display`/`x11_hotkey_register`，`#else` 是空实现——于是二进制对 `hotkey.register` 回"ok"却什么都没抓；现在宏加上了，B3 在加宏前失败、加宏后通过。
- **真 nano（Linux tier 3 实测，2026-09-27）比"函数清单"更严：语法面也砍。** `NanoSyntaxValidationVisitor` 直接拒绝 `require`/`include`、匿名类、`yield`/Fiber/Generator、反引号——所以"入口 `require` 框架"的后端**直接喂给 nano 编不过**（Windows 的 policy 包装从不报这些）。freestanding 本身是真的：5 行程序 1.16MB（strip 后 0.94MB），`ldd` 无任何 PHP 库，运行时不需要 php.ini/扩展闭包；Linux bin 模式则要背 libphp8.4.so + ini + 扩展全套。另：pristine `launcher-linux.cc` 有个上游缺陷——不定义 `TINYJS_APPINDICATOR` 编不过（`can_live_hidden()` 引用了只在宏内声明的 `g_indicator`），构建时该宏实际是必选项。
- **`require` 这条路已于 Phase 24 走通；Phase 25 把剩下的卡点量到**三个**，全在上游（tier 6）。** `tools/aggregate-backend.php` 在 token 层把 demo 后端的 `require` 链拍平成单文件（16 模块 / 41,995 B），聚合产物**被 nano 前端接受**（冷缓存 `--dry` 出 C++），所以"编不过"不再是我们的架构问题。往后依次是三道墙，每道都定位到了具体符号/字段，并本地验证过修法：① **链接**——`php::Args::get(unsigned long) const` 声明在 `phpx/include/phpx.h:2525`，**唯一定义在 `phpx/src/core/extension.cc:278`**，而该文件不在 phpx `extra.typephp-native.sources`（30 项）里，被组合的 `closure.cc` 却要它；把这两个访问器搬进已组合的 TU 后**发货后端真的链起来了**：6,933,344 B（strip 6,169,176 B）、`ldd` 无 libphp（2026-09-27 实测；nano 产物尺寸同样不逐字节稳定）。「直接把 `extension.cc` 加进清单」这条捷径**编不过**（4 个错误，见 `evidence/linux/25-naive-fix-fails.log`）。② **启动**——生成的模块入口会写 `ZEND_MOD_REQUIRED("Core")`（名字取自宿主反射里 Zend 内建函数的 `getExtensionName()`），而 php-nano 的 `dependency_state()` **只在组合数组里按 `->name` 找**；偏偏全树唯一叫 "Core" 的入口是 `Zend/zend_builtin_functions.c` 里那个 **`static`** 的 `zend_builtin_module`，composer 数组结构上不可能持有它 ⇒ 任何声明该依赖的 nano 程序**链得上也起不来**。**这条同样打在聚合体上**：Phase 24 曾推断"聚合集保留 `basic_functions_module` ⇒ 它的 Core 依赖可满足"，Phase 25 实测证伪——`basic_functions_module` 的名字是 `standard`，补完 ① 之后聚合产物照样死在 `Unable to start PHP Nano extensions`。tpc 侧 4 行（nano 模式跳过 `core`）就能让 `strlen` 程序从 rc=1 变成打印 `15`。③ **运行**——**nano 二进制拿不到自己的 stdio**：`STDIN`/`STDOUT`/`STDERR` 未定义（`fwrite(STDOUT,…)` → `Undefined constant "STDOUT"`，abort/rc=134）、`php://` wrapper 不存在、`/dev/std*` 打不开（同一个二进制开普通文件和 `/dev/null` 都正常）。我们的帧协议全在 stdin/stdout 上（`gui/php/src/Tiny/Gui/Backend.php:75/102/103`），所以 ③ 不解，`--nano` 自包含后端发不出任何一帧——聚合产物在 stock PHP 下与多文件树逐字节同帧这件事仍然成立，但它证明的是聚合正确性，不是 nano 可发货。三份可直接提的 issue 素材（最小复现、期望/实际、工具链版本、建议修法）在 [`docs/upstream-issues/`](docs/upstream-issues/README.md)，**尚未提交上游**。完整度量与负控见 `test/posix/README.md` 的 Tier 6、`evidence/linux/24-*` 与 `evidence/linux/25-*`。
- **分发体积** ≈ `shim(128KB) + php.exe(≈180KB) + launcher(≈1.9MB) + 8 个 DLL(6 个 PHP ≈15.5MB + 2 个 MinGW ≈2.4MB)` ≈ **20.7MB（实测）**，不是 tinyjsapp 那种 ~6MB 单文件。换来的是单进程自包含、目标机不需要装 PHP。
- **`php.exe` 不自身包含运行时**，DLL 必须和它同目录（Windows 先在自己的 exe 目录找非 KnownDLL，所以同目录能钉住版本、也不依赖 PATH）。MinGW 运行时（libgcc/libstdc++）是 launcher 与 shim 都依赖的，同样必须随包分发。
- **后端单文件**（理由见上）；tpc 走 `bootstrap.php`。Composer 有 PSR-4 但不替代 require 链。
- **`dev` 下后端是 exe 不是脚本**：shim 调 `execv` 时**不传参数**，所以后端必须能直接执行。POSIX 上有 shebang 的脚本可以，Windows 上必须是真 `.exe`。

---

## 文档站（VuePress 2）

`docs/` 是一个独立的 VuePress 2 站点，跟 PHP 构建**没有任何关系**（自己的 `package.json`，
不进 composer 的依赖图）。它把两样东西拼在一起：

- **新写的 6 页中文导览**（`docs/guide/`）：上手、架构、帧协议、三平台差异、后端 API 与扩展、验证矩阵。
  内容按源码逐条核对过，带 `文件:行` 出处。
- **仓库里已有的 markdown**：`docs/*.md`、`docs/planning/*`、`docs/upstream-issues/*` 直接被侧栏收录；
  `gui/README.md`、`test/posix/README.md`、`test/win/README.md` 和本 README 由 `docs/sync-external.sh`
  复制成 `docs/reference/*.md`（相对链接改写成站点路由，改不动的降级成"标签 + 仓库路径"），
  每次 `dev`/`build` 前自动跑，产物 `docs/reference/` 已在 `.gitignore` 里。

```bash
cd docs
npm install            # node_modules 约 140MB；缓存别写进启动卷：
                       #   npm_config_cache=/Volumes/data/.npm-cache-typephp npm install
npm run build          # 同步 + 构建 → docs/.vuepress/dist/（25 个页面 + 404 兜底页）
npm run dev            # 本地预览
```

两个装/配的时候踩到的硬事实，写在这里免得下次再撞：

- 版本必须配对：`vuepress@2.0.0-rc.31` ↔ `@vuepress/theme-default@2.0.0-rc.136`，且默认主题的 SCSS
  要 `sass-embedded`（缺了直接报 Preprocessor dependency not found）。
- `vuepress/cli` **不导出** `defineConfig`（只有 `defineUserConfig`），配置里别 import 它。
  更要紧的是 `@vuepress/markdown` 会强制 `html: true`，于是文档里那些 `<pid>` / `<App>` / `<html>`
  占位符会被当 HTML 交给 Vue 模板编译器，报 `Element is missing end tag` 且**无法用配置关掉**。
  解法是站内那个 `escapeRawHtml` 小插件（把 `html_block` / `html_inline` 渲染成转义文本），
  前提是全仓 markdown 不含合法 HTML 标签与 HTML 注释——目前成立，加新页时注意。

本 README 仍是**唯一权威**：文档站是它的可读视图，两边不一致时以仓库文件为准。

## 相关文档

| 文档 | 内容 |
|---|---|
| `docs/guide/` | 中文导览 6 页（上手 / 架构 / 帧协议 / 三平台差异 / 后端 API / 验证矩阵），以 VuePress 站点形式浏览：见上一节 |
| `.monkeycode/docs/INDEX.md` | DeepWiki：架构、接口、开发者指南、专有概念 |
| `docs/GUI_FUSION_DESIGN.md` | 融合设计：迁移范围/目标、模块划分、集成方式、兼容策略、开发者友好设计 |
| `gui/README.md` | `gui/` 模块说明：布局、与上游的差异、构建、扩展、兼容 |
| `test/posix/README.md` | 套件每一档在测什么、两条路径规则、怎么拿出去独立用 |
| `test/win/README.md` | Windows 开发方向的两支脚本：`dev-bounce.sh` 为什么把承重断言放在"两次 bounce 后仍 1/1/1 + 每轮换新管道"，`collect-evidence.sh` 的完整性守卫与 `REGEN=1` 独立重算 |
| `docs/feasibility-aot-compiler-backend.md` | 最初的可行性调研 |
| `docs/nano-mode-ipc-addendum.md` | nano 模式与 IPC 的补充结论 |
| `docs/aot-compiler-nano-fix.md` | `--nano` 编译缺陷的源码级根因与修法 |
| `docs/landing-report.md` | 落地报告：实测结论、能力矩阵、体积现状 |
| `docs/launcher-patch-notes.md` | launcher 补丁的逐 hunk 说明 |
| `docs/planning/` | 开发计划与踩坑记录（`task_plan.md` 阶段表、`findings.md` 调研结论、`progress.md` 逐次 session 记录）。阶段编号 `16a`/`16b-1`/`16b-2` 被这三份文档与技能文档交叉引用，**不要重编号** |
| `evidence/` | 验证证据（截图、帧日志、套件日志） |
