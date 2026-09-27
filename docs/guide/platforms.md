---
title: 三平台差异
description: Windows / macOS / Linux 各自的渲染引擎、传输、后端形态、打包布局，和每个平台真正踩过的坑
---

# 三平台差异

同一套 `Tiny\Gui` + 同一个 shim + 同一条帧协议，三个平台上**只有四件事不同**：
渲染引擎、端点形状、后端形态、launcher 是否被打过补丁。搞混这四点，排查就会跑偏
（mac 上那个 #21 挂起就是因为把"端点落点"当成了"AF_UNIX 特异问题"）。

## 1. 一览表

| | Windows | macOS (Apple Silicon) | Linux |
|---|---|---|---|
| 渲染引擎 | WebView2 | WKWebView | WebKitGTK（webkit2gtk-4.1，或 4.0） |
| launcher 源码 | `launcher-win.cc`，**含 `--typephp`** | `launcher-macos.cc`，**含 `--typephp`**（Phase 21b 按 Hunk A–E 同构移植） | `launcher-linux.cc`，**pristine，不移植 `--typephp`** |
| 端点 | `\\.\pipe\tinyjs-typephp-<pid>`（命名管道） | AF_UNIX sock | AF_UNIX sock |
| 打包方向 dev 方向 | launcher 拉 shim | launcher 拉 shim | **tgui 分别拉两端**（shim 先起、持端点；原版 launcher 连进来） |
| 后端形态 | tpc 编出的原生 exe（`php.exe`，bin 模式：链接 PHP DLL） | **系统 PHP**（shebang 脚本，`app_kind=stock`） | **系统 PHP**（同左；没有可用的自包含后端） |
| 图标 | 刻进 PE 资源 + PE `Subsystem` console→GUI | `Resources/AppIcon.icns`（`sips` + `iconutil`） | conf `icon=` → `TINYJS_ICON` 环境变量（launcher 读） |
| 打包产物 | `dist/<App>.exe` + `launcher.exe` + `php.exe` + 8 个 DLL + `frontend/` + conf | `dist/<App>.app` bundle | `dist/<App>/` 目录式 bundle |
| 发布前校验 | `tools/verify-bundle.py` | `tools/verify-bundle-macos.py`（`tgui build` 末尾自动跑） | `tools/verify-bundle-linux.sh`（同上） |
| 分发签名 | （未做） | **Developer ID + 公证未做**，且当前 bundle 布局签不起来（见第 3 节） | （未做） |

`8 个 DLL` = 6 个 PHP 运行时 + 2 个 MinGW 运行时。

## 2. 每个平台真正咬过人的地方

### Windows

- **PE 子系统与图标**：`tgui build` 必须把入口 PE 的 `Subsystem` 从 console 改成 GUI，
  否则双击后一直挂个黑框；图标要刻进 PE 资源，`.conf` 里的 `icon=` 只管运行时窗口/任务栏（#10）。
- **WebView2 用户数据目录锁死**（Phase 21e 真机才暴露）：被硬杀的旧 host 留下的
  `msedgewebview2.exe` 会锁住共享的 per-exe UDF，下一发 `CreateCoreWebView2Controller`
  一直 `ERROR_INVALID_STATE`，最终 `webview_create` 返回 null（表现是
  `launcher: failed to create webview`）。修法：每次 launch 用独立
  `%TEMP%/tinyjs-typephp-<pid>-<rand>` UDF（`tinyjs_prepare_webview_udf()` 置
  `TINY_WEBVIEW_UDF`，`win32_edge.hh` 读取，未设则回退原行为）。
- **dev 的进程回收只靠管道 EOF**：Windows 侧没有 POSIX 的 `dev_reap_shim` 兜底，
  kill 掉 launcher 又不跑 `atexit`，shim 自杀只能靠端点 EOF——所以验收必须断言
  "两次 bounce 后 launcher/backend/app 仍是 1/1/1"，不然泄漏会逐次累积。
- Cygwin/Git Bash 的方言坑（`stat -f` vs `-c`、CPython AF_UNIX 与原生 AF_UNIX 不通）
  写在 `docs/reference/posix-kit.html`。

### macOS

- **#21：外部卷上的双击挂起**。LaunchServices（`open`）拉起的进程在**非启动卷**上
  **创建第一个新文件**就阻塞在 `open(O_CREAT)` 等 TCC `kTCCServiceSystemPolicyRemovableVolumes`
  授权（`AUTHREQ_PROMPTING` 长期 pending）。跟 socket 无关——旧记录里"AF_UNIX `bind()` 特异"
  是**错归因**，`__bind` 只是 shim 第一个碰文件系统的调用。
  修法：launch 模式下先问「exe 目录和 `/` 同卷吗」（`stat` 两处 `st_dev`，
  `#if defined(__APPLE__)` 包住），不同卷或 `sun_path` 装不下就搬到 `tmp_endpoint()`
  （优先 `$TMPDIR`）并写日志说明原因 → **bundle 目录不再被写入任何东西**。
  判据：`stat -f %d /` 与 `stat -f %d <bundle>` 不同即为该场景（这台机器上 16777234 vs 16777241）。
- **`sun_path` 在 mac 是 104 B**（Linux 108 B），别照抄。
- **TCC 授权按 bundle identifier 记账**：同一个 id 答过一次就不再阻塞。所以做负控
  必须用**自己的 id**（`CTL_ID`），复用产品 id 会让"挂起"断言假绿；
  另外 Privacy 面板日志里那行 `loadAuthorizationStates(…) … full` **不能当已授权读**。
- **当前布局签不起来**：`codesign` 会把 `Contents/MacOS/` 下**每个**条目当嵌套代码，
  而 `<App>.conf` 是文本 → `code object is not signed at all / In subcomponent: …/App.conf`。
  本机不影响运行（二进制带链接器 ad-hoc 签名就够），但它是 Developer ID + 公证的**第一块前置砖**：
  conf 得挪进 `Resources/`（shim 两处都找）。本机 `security find-identity -v -p codesigning`
  报 **0 valid identities**，所以这条路在当前环境里连验收都做不了。
- **截图取证**：`screencapture -x -o -l<windowid>` 按窗口号抓（`tools/mac-winlist.c` 用
  `CGWindowListCopyWindowInfo` 列 window number），但 Screen Recording 授权**会在同一个
  shell 里自己掉**——掉了以后 `-l` 报 `could not create image from window`，且整屏抓取
  退化成单色图。所以文案类断言要有不依赖屏幕的第二层证据。

### Linux

- **`launcher-linux` 保持 pristine 是刻意的**，代价是 dev 方向必须由 CLI 编排两端，
  与 win/mac 的"launcher 拉 shim"看起来相反（角色其实没变：shim 仍是端点服务端）。
- **ayatana-appindicator3 是硬依赖**（#23）：`tools/build-linux.sh` 缺包时会点名缺哪个，
  不会给你一个链接不上的产物。
- **没有 X display 时不能挂起**（#25）：直跑入口必须**0 秒返回 RC=1**，
  shim 日志写 `launcher exited (status 768) before connecting` + `launcher never connected, aborting`，
  不留 socket 不留子进程。这是 `io_accept_watching()`（accept 与子进程存活同轮询）换来的。
- **后端只能靠系统 PHP**：`tpc --nano` 那条路量到底了，卡在三道**上游**卡点
  （链接缺 `php::Args::get` 定义、启动期 `ZEND_MOD_REQUIRED("Core")` 不可满足、
  nano 二进制拿不到自己的 stdio 句柄）。素材在 `docs/upstream-issues/`，**尚未提交上游**。
- **真桌面 ≠ Xvfb**：容器里 Xvfb 没有 WM/合成器/托盘。Phase 23 在容器内起了
  Openbox + picom + 自建的 SNI `StatusNotifierWatcher`（Bookworm 没有可用的 SNI 宿主，
  而 ayatana-appindicator3 是 **SNI-only**，XEmbed systray 根本挂不上我们的条目），
  才把"WM 管理、合成、最小化/最大化回传、托盘注册与点击、全局热键、HiDPI"逐项验出来。
  仍未证明的是**真硬件/真 DE**：GPU 合成、Wayland 会话、GNOME/KDE 自带托盘的观感、分数缩放。

## 3. 三个平台共同的边界

1. `SIGTERM` / `kill -9` 打断仍会留下端点文件（只有正常关窗路径会 unlink）——与 Phase 23 的 #28 同源，未改。
2. 托盘/热键的**后端侧方法缺失**（`tray.set` / `hotkey.register`），且 `Protocol::decode` 没有
   `HOTKEY` 分支 → 页面收不到全局快捷键。有意未修，已记录。
3. demo 页的调用链文案**由后端上报的事实派生**（`chainFor(sysinfo.os, sysinfo.backend)`，
   第 ⑤ 格取 `TYPEPHP_APP_KIND`），不会在 mac/Linux 上自称 "WebView2 / 命名管道 / AOT"。
