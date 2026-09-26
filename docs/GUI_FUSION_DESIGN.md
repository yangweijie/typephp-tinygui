# GUI 融合设计文档（GUI Fusion Design）

> 配套文档：`gui/README.md`（模块说明）。本文是用户要求的**迁移设计书**：明确迁移的范围与目标、新的模块划分与集成方式、与现有代码的兼容策略、以及面向开发者的友好设计。

---

## 0. 背景与动机

早期的 typephp-gui 把 tinyjsapp 当作**外部 checkout** 来用，并通过**树外补丁**把 `--typephp` 能力塞进上游：

- `patches/cli-typephp.patch` → 改 `cli.js`
- `patches/launcher-win-typephp.patch` → 改 `native/launcher-win.cc`
- `tools/bootstrap-tinyjsapp.sh` → 在 checkout 里打补丁 / 还原

这套方式有三个硬伤：

1. **每次 clone 都要 patch。** 补丁与上游版本强耦合，上游一升版就 reject。
2. **`cli.js` 必须就地改。** 它的 `TOOL_DIR` 从自身路径 `new URL('.', import.meta.url)` 推出，CLI 只能在 checkout 里跑、也只能在 checkout 里改，污染上游工作区。
3. **后端是巨型 `switch`。** 所有方法（含 `api.fib`、`win.setTitle`、`menu.set`、对话框、事件）挤在一个 `dispatch()` 里，难测、难扩展。

目标很明确：**把 GUI 实现并入仓库本体**，去掉外部依赖与补丁步骤，保留全部核心能力，并把后端重构成可扩展、可测试的 PHP 框架——是融合（fusion），不是照搬（fork）。

---

## 1. 迁移范围与目标（Scope & Goals）

### 1.1 范围

**纳入仓库（vendor + 自有，受 MIT 约束，归属见 `gui/LICENSE.NOTICE`）：**

| 内容                         | 来源                                           | 在本仓库的位置                                                          | 备注                                                         |
| -------------------------- | -------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------- |
| WebView2 宿主（含 `--typephp`） | tinyjsapp `native/launcher-win.cc`           | `gui/host/src/launcher-win.cc`                                   | **已把 4 个 `--typephp` hunk 直接并入自有源码**                       |
| Linux / macOS 宿主           | tinyjsapp `native/launcher-{linux,macos}.cc` | `gui/host/src/`                                                  | pristine vendor                                            |
| 头文件                        | tinyjsapp `native/`                          | `gui/host/include/` (`webview.h` / `WebView2.h` / `miniaudio.h`) | vendor                                                     |
| `window.tiny` 客户端 shim     | tinyjsapp `runtime/tiny.js`                  | `gui/runtime/tiny.js`                                            | 自有副本，可改                                                    |
| 客户端代码生成                    | tinyjsapp `gen-client.sh`                    | `gui/host/script/gen-client.sh`                                  | 改写：把 `gui/runtime/tiny.js` 嵌进 `gui/host/src/tiny_client.h` |

**重写 / 替换（本融合的核心创新）：**

| 上游                                 | 本仓库替代                                           | 说明                                 |
| ---------------------------------- | ----------------------------------------------- | ---------------------------------- |
| `cli.js`（JS CLI，打补丁支持 `--typephp`） | `gui/bin/tgui`（bash 一等公民 CLI）                   | 自有 `dev/build/publish/init/status` |
| `runtime/bridge.js`（JS 后端桥）        | `gui/php/src/Tiny/Gui/*`（PHP 原生协议框架）            | 无依赖、强类型、可扩展                        |
| 扁平 `src/backend.php`（巨型 `switch`）  | `Dispatcher` + `HandlerInterface` + 内置 Handlers | 扩展点取代中心函数                          |
| `demo` 入口 `src/backend.php`        | 薄封装：加载框架后 `Gui::serve()`                        | `tpc` 编译路径不变                       |

**删除（彻底结束补丁式集成）：**

- `patches/` 整个目录
- `tools/bootstrap-tinyjsapp.sh`

**保留（角色不变）：**

- `shim/backend_shell.cpp` —— 仍是 C++ 代理，把宿主 IPC 端点（Windows 命名管道 / POSIX unix socket）与 PHP 后端的 stdio 帧互转。**线格式与之前逐字节一致。**
- 整条线协议（`CALL`/`RET`/`EVAL`/`DLG`/`MENU*`/`TITLE`/`SIZE`/`QUIT`…）。
- MIT 归属声明（`gui/LICENSE.NOTICE`）。

### 1.2 目标

- ✅ **无外部 tinyjsapp checkout**，也**无补丁步骤**。
- ✅ 核心功能全保留：窗口、`window.tiny` API、`CALL`/`RET` 帧、原生对话框、菜单栏、托盘、事件推送、`dev`/`build`/`publish`。
- ✅ 后端重构成清晰、可扩展、可测试的框架（见 §2.3），而非照搬。

---

## 2. 新的模块划分与集成方式（Module Division & Integration）

### 2.1 目录划分

```
gui/                          ★ 融合后的 GUI 模块（原 tinyjsapp 已并入，不再是外部依赖）
├── LICENSE.NOTICE            MIT 归属声明（tinyjsapp + 本项目）
├── host/                     原生 GUI 宿主（vendor + 自有）
│   ├── src/launcher-win.cc       WebView2 宿主，--typephp 已并入源码
│   ├── src/launcher-{linux,macos}.cc   原生宿主（pristine vendor）
│   ├── include/               webview.h / WebView2.h / miniaudio.h
│   └── script/gen-client.sh   把 runtime/tiny.js 嵌进 src/tiny_client.h
├── runtime/tiny.js           window.tiny 客户端 shim（自有副本）
├── php/                      ★ PHP 原生协议框架（本融合的创新核心）
│   ├── backend.php           规范入口（tpc gui/php/backend.php -o app.exe）
│   ├── src/Tiny/Gui/
│   │   ├── Request.php / Response.php   帧的 typed 值对象
│   │   ├── Protocol.php      无状态编解码（逐字节对齐 bridge.js）
│   │   ├── Dispatcher.php     分派器（add / on / onPrefix / dispatch）
│   │   ├── HandlerInterface.php   扩展点
│   │   ├── Backend.php        processLine() 纯函数 + run() 主循环
│   │   ├── State.php          缓存 theme/locale/winState
│   │   ├── Gui.php            门面（defaultDispatcher / serve / serveWith）
│   │   └── Handlers/          Core / Win / Menu / Store / DemoApi
│   └── test/smoke.php        headless 协议测试（12 项）
└── bin/tgui                  dev / build / publish / init / status CLI

shim/backend_shell.cpp        C++ 代理（Windows + POSIX 同一份源码，角色不变）
tools/build-launcher.sh       编宿主（从 gui/host/src 编）→ build/runtime/
tools/build-all.bat           Windows：编 shim + PHP 后端 → build/
```

### 2.2 集成链路

```
 开发方向 (tgui dev)                      打包方向 (tgui build → 双击 <App>.exe)
 ┌────────────────────┐                 ┌────────────────────┐
 │ launcher-win.exe   │                 │ <App>.exe (=shim)  │ ← 双击入口
 │ (gui/host/src 编出) │                 │ 自身为端点服务端   │
 └─────────┬──────────┘                 └─────────┬──────────┘
           │ --typephp <html> <title>             │ 拉起 STOCK launcher
           │   <size> <ver>                       │ <html> <endpoint> ...
           ▼                                      ▼
 ┌────────────────────┐                 ┌────────────────────┐
 │ shim (C++ 代理)    │                 │ launcher.exe       │
 │ 帧泵 + stderr 分道 │                 └─────────┬──────────┘
 └─────────┬──────────┘                           │ 匿名管道
           │ stdio（行分隔帧）                     ▼
 ┌─────────▼──────────┐                 ┌────────────────────┐
 │ app.exe (PHP AOT)  │◄────────────────│ shim → app.exe     │
 │ 跑 Gui::serve()    │                 │ (PHP 后端)         │
 └────────────────────┘                 └────────────────────┘
```

`tgui dev` 做的事：解析 `tinyjs.json` → 设置 `TYPEPHP_BACKEND` / `TYPEPHP_APP` / `TYPEPHP_CWD` / `TINYJS_ICON` → 拉起 `launcher --typephp <html> <title> <size> <ver>`。宿主在 `--typephp` 模式下 spawn shim，shim 再 spawn `app.exe`，三者用 stdio 帧对话。

### 2.3 框架组件（创新核心）

| 组件                     | 职责                                                                                                                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Request` / `Response` | 帧的 typed 值对象（`id/method/params`；`result/status/frames`）                                                                                                                                     |
| `Protocol`             | 无状态编解码：`ret()`、`event()`、`esc()`、`one()`、`extList()`、`dialogFrame()`、`decode()`。逐字节对齐 `launcher-win.cc` 的 `wire_unescape` 与 `bridge.js`（菜单/对话框帧用 TAB 分隔字段）                                  |
| `HandlerInterface`     | `methods(): array` + `handle(Request): ?Response`（返回 `null` 放行给下一个 handler）                                                                                                                 |
| `Dispatcher`           | `add(HandlerInterface)` / `on($method, $fn)` / `onPrefix($prefix, $fn)` / `dispatch()` —— **首个命中生效**，未知方法抛错                                                                                 |
| 内置 `Handlers`          | `Core`（ping/client.hello/log/sysinfo/listDir/theme.get/system.locale/win.getState）、`Win`（setTitle/setSize/quit）、`Menu`（menu.set）、`Store`（get/set/all）、`DemoApi`（version/sum/sha256/fib/now） |
| `Backend`              | `processLine($line, $d, $s): ?string`（**纯函数、可测**）+ `run($d, $s)`（stdin→stdout 主循环，启动时 emit `READY`）。对话框短接到 `DLG`（不发 `RET`）；通知写入 `State` 并发 `EVAL`；`RET` 在窗口帧之后发                             |
| `State`                | 缓存 `theme` / `locale` / `winState`                                                                                                                                                          |
| `Gui`                  | 门面：`defaultDispatcher(State)`、`serve()`、`serveWith($d, $s)`                                                                                                                                 |

### 2.4 为什么是创新，不是照搬

- 上游后端是一个 **巨型 `switch`**；本框架用 **`HandlerInterface` 扩展点 + `Dispatcher` 分派**。新增能力 = 实现一个 handler，无需改动中心函数，也不需要懂线格式细节。
- 上游没有独立的协议编解码层；本框架把线格式收敛到 `Protocol` 一个无状态类里，并**逐字节对齐** `launcher-win.cc` 与 `bridge.js`，保证新旧两端互操作。
- `Backend::processLine($line, $d, $s): ?string` 是**纯函数**——给定一行输入、一个 dispatcher、一个 state，返回要写出的帧字符串。这使得 **12 项 headless 冒烟测试**可以直接断言帧输出，而不需要起一个真的窗口。

---

## 3. 与现有代码的兼容策略（Compatibility）

| 维度                 | 策略                                                                                                                                                         |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **线格式**            | 完全不变：`CALL <id> <json>` / `RET <id> <status> <json>` / `EVAL` / `EVAL@<win>` / `DLG` / `MENU*` / `TITLE` / `SIZE` / `QUIT` 与上游一致。已并入源码的宿主无需再改；**旧前端继续可用**。 |
| **`--typephp` 特性** | 不再是独立补丁，而是**已并入自有 `launcher-win.cc` 源码**的 4 个 hunk。升级时作为普通提交并入，由 git 跟踪，不再有 `patches/*.patch` 文件。                                                          |
| **shim 角色**        | `shim/backend_shell.cpp` 不变：仍然把宿主 IPC 端点与 PHP 后端 stdio 互转。三种通道（stdin/stdout 帧、stderr 仅日志）语义不变。                                                             |
| **demo 入口**        | `src/backend.php` 仍是 `tpc src/backend.php -o build/app.exe` 的入口，现在只是薄封装（加载框架后 `Gui::serve()`），编译路径完整保留。                                                    |
| **MIT 归属**         | `gui/LICENSE.NOTICE` 显式列出 vendor 文件（tinyjsapp 派生）与自有文件（本项目原创），并附 MIT 原文。                                                                                   |
| **协议细节**           | 菜单/对话框帧仍为 **TAB 分隔字段**；`DLG` 与 `MENU*` 由后端发、**不回 `RET`**（与 `bridge.js` 的 `if (dlg) { send(...); return; }` 一致），所以 shim 必须是非阻塞双向轮询。                         |

> 兼容性的"锚点"是 **`Protocol` 类逐字节对齐 `bridge.js`**。任何对线格式的改动都必须同时改 `Protocol` 与（若涉及）`launcher-win.cc`，并跑 `gui/php/test/smoke.php` 验证。

---

## 4. 面向开发者的友好设计（Developer-Friendly Design）

### 4.1 清晰的接口

```php
// 扩展点：实现一个 handler 即可
namespace Tiny\Gui;

interface HandlerInterface
{
    /** @return string[] 本 handler 认领的方法名 */
    public function methods(): array;
    /**
     * 处理一帧。返回 Response 即应答；返回 null 放行给下一个 handler。
     */
    public function handle(Request $req): ?Response;
}
```

```php
// 分派器：三种注册方式
$d = new Dispatcher();
$d->add(new MyHandler());                 // 实现 HandlerInterface 的类
$d->on('demo.greet', fn(Request $r): Response =>
    Response::ok('hello ' . ($r->params['name'] ?? 'world')));
$d->onPrefix('admin.', fn(Request $r): Response =>
    Response::ok('admin method: ' . $r->method));
```

```php
// 门面：三步起服务
require 'gui/php/src/Tiny/Gui/bootstrap.php';
$s = new \Tiny\Gui\State();
$d = \Tiny\Gui\Gui::defaultDispatcher($s);   // 内置 Core/Win/Menu/Store/DemoApi
\Tiny\Gui\Gui::serveWith($d, $s);
```

### 4.2 可扩展 & 可维护

- **加一个方法**：实现 `HandlerInterface` 或调用 `$d->on(...)`，**零中心编辑**。
- **加一类方法**：`$d->onPrefix('admin.', ...)` 前缀路由。
- **可测试**：`Backend::processLine()` 是纯函数，`gui/php/test/smoke.php` 现成 12 项 headless 断言，改协议不用开窗口。
- **无 `autoload`**：`bootstrap.php` 顺序 `require`，`composer.json` 故意不设 `autoload`（这里没有"类图"，只有一份运行时入口）。

### 4.3 友好的 CLI 与配置

`gui/bin/tgui` 子命令：

| 命令             | 作用                                                                                      |
| -------------- | --------------------------------------------------------------------------------------- |
| `tgui dev`     | 拉起宿主 + shim + PHP 后端跑当前项目                                                               |
| `tgui build`   | 组装可移植 `dist/`（`shim`→`<App>.exe`、`launcher.exe`、`app.exe`、6 个 DLL、`frontend/`、`*.conf`） |
| `tgui publish` | 把 `dist/` 压成 zip（带回退 tar.gz）                                                            |
| `tgui init`    | 在当前目录脚手架 `tinyjs.json` + `src/frontend/index.html`                                      |
| `tgui status`  | 打印已解析的 launcher / shim / app 路径                                                         |

配置 `tinyjs.json` 支持**嵌套 JSON**（tgui 用 `php` 解析，支持点号路径如 `typephp.app` / `frontend.dir`），示例见 `demo/tinyjs.json`。所有路径可用环境变量覆盖：`TINYGUI_LAUNCHER`、`TYPEPHP_BACKEND`、`TYPEPHP_APP`。

---

## 5. 构建与升级上游

### 5.1 首次构建

```bash
# 1) 原生宿主（launcher-win.exe + runtime 三件套）—— Windows / Cygwin
bash tools/build-launcher.sh

# 2) shim (C++) + PHP 后端 (app.exe) —— Windows
tools\build-all.bat

# 3) 跑 demo
cd demo && bash ../gui/bin/tgui dev
```

`tools/build-launcher.sh` 每次都会从 `gui/runtime/tiny.js` 重新生成 `gui/host/src/tiny_client.h`，所以改了 `tiny.js` 只需重跑它。

### 5.2 升级 tinyjsapp 宿主

现在宿主是**自有源码**，升级不再走补丁文件：

1. 从上游重新 vendor `launcher-win.cc`（及其他宿主文件）到 `gui/host/src/`；
2. 把本项目的 `--typephp` 4 个 hunk 改动作为**普通提交**并入（用 `git` diff 对齐，不再有 `patches/base/*.orig` + `.patch`）；
3. 跑 `bash tools/build-launcher.sh` + `php gui/php/test/smoke.php` 验证。

`gui/runtime/tiny.js` 同理：直接覆盖自有副本即可。

---









## 6. 验证（Verification）

| 验证项                                               | 结果                   |
| ------------------------------------------------- | -------------------- |
| POSIX 套件（host probe + tier1/2 + 启动模式 + stderr 隔离） | **50 PASS / 0 FAIL** |


| PHP 协议框架 headless 冒烟（`gui/php/test/smoke.php`） | **12 PASS / 0 FAIL**（ping / api.fib / win.setTitle / menu.set / dialog / SYS·SYSLOCALE·WINSTATE 通知 / win.getState 缓存 / 未知方法报错 / store 往返 / 空行忽略） |  
| Windows 开发方向（`tgui dev`） | 窗口正常，13 CALL / 13 RET，`WINDOW-E2E OK ping=pong`（历史结论保留） |  
| Windows 打包方向（双击 `dist\<App>.exe`） | 窗口正常，13 CALL / 13 RET（历史结论保留） |  
| 打包产物校验（`tools/verify-bundle.py`） | 0 failure / 0 warning（历史结论保留） |

> 注意：本环境无法跑 Windows GUI 实时验证（缺 WebView2 + MSVC 工具链）。上面 Windows 两项为迁移**前**已通过的历史结论；融合后代码路径未触碰线格式，故兼容性由 `smoke.php` 的逐字节断言 + 宿主源码不变来保证。

---

## 7. 已知限制

- **`--typephp` 目前仅 Windows**：只有 `launcher-win.cc` 并入 `--typephp`；`launcher-linux.cc` / `launcher-macos.cc` 是 pristine vendor，tgui 在非 Windows 会拒绝启动（与上游一致）。
- **分发体积** ≈ `shim(128KB) + app.exe(~180KB) + 6 个 PHP DLL(~15.5MB)` ≈ **18.6MB**，不是 tinyjsapp 那种 ~6MB 单文件。换来单进程自包含、目标机不装 PHP。
- **`app.exe` 不自带运行时**：DLL 必须同目录（Windows 先在 exe 目录找非 KnownDLL）。
- **后端单文件**：`tpc` 编译的是单个入口；框架代码通过 `bootstrap.php` 顺序 require 并入同一编译单元，`composer.json` 因此不设 `autoload`。
- **shim 在三种情形都省不掉**：Windows 缺 `pipe://` transport、POSIX 真 nano 无 socket API、POSIX bin 模式虽能服务 socket 但已不"小巧"。"又小又免 shim"的组合不存在。
