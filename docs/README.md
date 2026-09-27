---
home: true
title: 文档首页
heroText: TypePHP GUI
tagline: 用 PHP 写桌面应用的桌面 GUI 模板：编译后的 PHP 后端 + 融合版 tinyjsapp 宿主（WebView2 / WKWebView / WebKitGTK）
actions:
  - text: 十分钟跑起来
    link: /guide/getting-started.html
    type: primary
  - text: 先看架构与调用链
    link: /guide/architecture.html
  - text: 三平台差异（含踩过的坑）
    link: /guide/platforms.html
features:
  - title: 后端就是 PHP，不是 JS
    details: >-
      页面仍在 WebView 里跑，但应答 `tiny.*` 调用的是 PHP：`gui/php` 的 `Tiny\Gui` 框架 +
      `bin/run-backend.php`。开发时用系统 PHP ≥ 8.1 直跑同一套逻辑，发布时可以走 aot-compiler（tpc）编成的原生后端。
  - title: 中间一定有一层 C++ shim
    details: >-
      宿主与 PHP 说不了同一种 IPC（Windows 命名管道 / POSIX AF_UNIX，php-nano 甚至连 socket API 都没有），
      所以 `shim/backend_shell.cpp` 把宿主端点翻译成后端的 stdio 帧通道：stdout 只走协议帧，stderr 只进日志。
  - title: 三个平台的实机验收都在仓库里
    details: >-
      Windows 真机、macOS Apple Silicon 真机、Linux 在 Apple Container 的 Debian 12/aarch64 里（含 Xvfb
      + Openbox + picom + 自建 SNI 宿主的真桌面档）。每条结论都指向 `evidence/` 里的日志或截图，
      跑法见「验证矩阵」。
  - title: 缺口是记录在案的，不是没写
    details: >-
      `tray.set` / `hotkey.register` 后端侧未实现、`Protocol::decode` 没有 `HOTKEY` 分支、
      `--nano` 单文件后端卡在三道上游卡点……这些都写在文档与 `docs/planning/task_plan.md` 的踩坑表里，
      并标了「有意未修」还是「上游阻塞」。
---

## 这个站和仓库里的 README 什么关系

仓库根 [`README.md`](/reference/root-readme.html) 是**项目门面 + 验证矩阵**，`docs/` 是**调研、设计、开发记录**。
本站不替代它们：`reference/` 下的页面由 `docs/sync-external.sh` 在每次构建前从仓库原样复制，
`guide/` 下是把这些材料按"新人要从哪儿读"重排的导览主干。

| 想干什么 | 去哪儿 |
|---|---|
| 第一次跑起来（Windows / macOS / Linux 三套命令） | [指南 · 十分钟跑起来](/guide/getting-started.html) |
| 理解一个 `tiny.win.setTitle()` 调用经过了哪些进程 | [指南 · 架构与调用链](/guide/architecture.html) |
| 加一个后端方法、或自己实现一个 `HandlerInterface` | [指南 · 后端 API 与扩展](/guide/backend-api.html) |
| 排查"连不上 / 卡住 / 端点在哪儿" | [指南 · 帧协议](/guide/protocol.html)、[指南 · 三平台差异](/guide/platforms.html) |
| 想知道某条结论的实机证据 | [指南 · 验证矩阵](/guide/verification.html) → `evidence/` |
| 读调研与融合设计原文 | 侧栏「调研与设计」6 篇 |
| 看踩坑记录（40 条，含根因改判过程） | 侧栏「开发记录」`docs/planning/` |

## 一句话链路

```
页面 (WebView)
  → window.tiny.*  ── CALL <id> <json> ──┐
                                         ↓
                    launcher（C++，宿主本体：窗口 / WebView / 托盘 / 热键）
                                         ↑
                    shim  backend_shell（C++）：端点 ⇄ stdio
                                         ↓
                    PHP 后端（Tiny\Gui：Dispatcher + Handlers）→ RET <id> <status> <json>
```

传输形状按平台不同（Windows 命名管道、macOS/Linux AF_UNIX），且**打包与开发两种拉起方式的方向不一样**——
这正是 mac 上那个挂起 bug（#21）的来处，细节在 [三平台差异](/guide/platforms.html)。
