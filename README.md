# TypePHP GUI

用**编译成原生二进制的 PHP** 当 [tinyjsapp](https://github.com/tarwin/tinyjsapp) 桌面应用的**后端**，替换掉默认的 txiki.js / JS 模块图。

WebView2 窗口、`window.tiny.*` 页面 API、`CALL`/`RET` 帧协议**全部沿用上游原样**——换掉的只有"谁来应答这些帧"：从 JS 换成 [aot-compiler](https://github.com/layterz/aot-compiler)（`tpc`）编出来的 PHP 单文件 exe。

```php
// src/backend.php —— 这段代码最终是 app.exe 里的原生机器码，而不是解释执行的脚本
case 'api.fib':
    $n = max(0, (int)($params['n'] ?? 30));
    $a = 0; $b = 1;
    for ($i = 0; $i < $n; $i++) { [$a, $b] = [$b, $a + $b]; }
    return [$a, []];
```

| 验证项 | 结果 |
|---|---|
| POSIX 套件（host probe + tier1/2 + 启动模式 + stderr 隔离） | **50 PASS / 0 FAIL** |
| Windows 开发方向（`tgui dev`） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 406ms`（融合后真机复验） |
| Windows 打包方向（双击 `dist\<App>.exe`） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 430ms`（融合后真机复验，含 PE 补丁后的入口） |
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
│   │   ├── src/launcher-{linux,macos}.cc   原生宿主（pristine vendor）
│   │   ├── include/               webview.h / WebView2.h / miniaudio.h
│   │   └── script/gen-client.sh   把 runtime/tiny.js 嵌进 tiny_client.h
│   ├── runtime/tiny.js         window.tiny 客户端 shim（vendor）
│   ├── php/src/Tiny/Gui/        ★ PHP 原生协议框架（融合的核心创新）
│   │   ├── Protocol / Dispatcher / Backend / State / Gui（facade）
│   │   └── Handlers/              Core / Win / Menu / Store / DemoApi
│   └── bin/tgui                 dev/build/publish/init/status CLI
│                             （替代上游 cli.js，不再需要 checkout）
├── src/backend.php           PHP 后端入口（薄封装，加载 gui/php 框架）
├── bin/run-backend.php       用系统 PHP 直接跑同一份逻辑（不编译也能调试）
├── shim/backend_shell.cpp    C++ 代理。Windows + POSIX 同一份源码
├── tools/
│   ├── build-all.bat          Windows：编 shim + PHP 后端 → build/
│   ├── build-launcher.sh      编 launcher（从 gui/host/src 编）→ build/runtime/
│   ├── verify-bundle.py       发布前校验 dist/ 产物
│   └── e2e/                   截图 / 点窗口 / 关窗口的小工具（ctypes，无依赖）
├── demo/                     一个完整示例（PHP 后端 + tiny.js 前端）
├── test/posix/               POSIX 验证套件（可独立拷出去用）
├── docs/                     调研、落地报告、融合设计
│   ├── GUI_FUSION_DESIGN.md   迁移范围/目标/模块划分/集成/兼容/开发者友好设计
│   └── planning/             开发计划 + 踩坑记录
├── experiments/              历史探针（保留但不参与构建）
├── evidence/                 验证证据：e2e 截图/日志 + 套件日志
├── build/                    所有生成物，git 忽略
└── composer.json             包元数据 + 快捷脚本
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

`tgui dev` 会解析 `demo/tinyjs.json`、设置后端环境变量（`TYPEPHP_BACKEND` / `TYPEPHP_APP` / `TYPEPHP_CWD` / `TINYJS_ICON`），然后拉起 `launcher --typephp <html> <title> <size> <ver>`。改后端文件（`src/backend.php` 或任意框架文件）会让后端重启（窗口闪一下）；改 `demo/src/frontend/` 只是页面重载。

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

产物：`dist/<App>.exe`（= shim，双击入口；`tgui build` 会自动用 `launcher --embed-icon` 把图标刻进 PE 资源、并把 PE `Subsystem` console→GUI，双击不挂黑框——这两步是旧 cli.js 的出货级修法 #10，融合 CLI 已接回）、`launcher.exe`、`php.exe`（PHP 后端，与入口不同名）、8 个 DLL（6 个 PHP 运行时 + 2 个 MinGW 运行时）、`frontend/`、`dist/<App>.conf`。

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
| `CALL <id> ["<payload>","<origin>"]` | 页面调后端。`payload` 是 `{"method":...,"params":{...}}` |
| `WINSTATE <win> <json>` | 窗口状态变化（通知，无需应答） |
| `NAV <json>` / `SYS <json>` / `SYSLOCALE <json>` | 导航、系统、语言变更通知 |
| `MENU <json>` / `TRAY <json>` / `TRAYCLICK <json>` / `GOT <json>` | 菜单、托盘、异步回调 |

**backend → launcher**

| 帧 | 含义 |
|---|---|
| `RET <id> <status> <json>` | 应答，`status` 0=ok 非 0=错误 |
| `TITLE <text>` / `SIZE <w> <h>` / `QUIT` | 窗口控制。**必须在 `RET` 之前发** |
| `EVAL <js>` / `EVAL@<win> <js>` | 在页面里跑 JS（事件推送就走这条） |
| `DLG <id> <op>\t<args>` | 原生对话框 |
| `MENUBEGIN … MENU/ITEM/SEP/SUB … MENUEND` | 整块声明菜单栏 |

关键区别：`DLG` 和 `MENU*` 是 **launcher 原生的帧，后端不发 `RET`**（和 `bridge.js` 里 `if (dlg) { send(...); return; }` 一致）。正因为这个，shim 不能做成严格的一问一答泵，必须是**非阻塞双向轮询**。

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
$d = Gui::defaultDispatcher($s);          // 内置 Core/Win/Menu/Store/DemoApi
$d->on('demo.greet', function (Request $req): Response {
    $who = (string)($req->params['name'] ?? 'world');
    return Response::ok("hello, {$who}");   // 结果会被 Protocol::jenc 进 RET
});
Gui::serveWith($d, $s);
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

框架的 `StoreHandler`（`store.get` / `store.set` / `store.all`）用的是进程内数组（演示用途）。要持久化就自己接 SQLite / 文件——**注意**真 nano 模式下 `getenv` / `gethostname` 都不可用（`backend.php` 里只有 `sysinfo` 用到它们，已经标注），别用。

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

另外 `launcher-linux.cc` / `launcher-macos.cc` 目前是 pristine vendor，`--typephp` 仅在 `launcher-win.cc` 实现，所以非 Windows 上暂时跑不了完整 GUI（只能跑 shim 的 POSIX 分支 + 用真 nano 量体积）。

### 后端为什么还是"一个文件"编译出来

`tpc` 编译的是**单个入口文件**：`main()` 由编译器自动调用（所以系统 PHP 下要 `bin/run-backend.php` 手动调一次）。早期 `src/backend.php` 是过程式单文件；融合后它变成薄入口，逻辑拆进了 `gui/php/src/Tiny/Gui/*` 一整套类。这些类通过 `bootstrap.php` 的 `require` 被拉进同一个编译单元——**已验证 tpc 会跟着 `require` 递归编译**，所以现在既是清晰的多文件框架，又仍能编成单个 `app.exe`。

`composer.json` 因此**故意没有 `autoload`**——框架靠 `bootstrap.php` 顺序 `require` 装载，不走 Composer 自动加载。

---

## 验证

### POSIX 套件（一条命令，一份证据）

```bash
bash test/posix/all.sh          # 或 composer run tiers
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
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/native/launcher-win.cc" \
  -o gui/host/src/launcher-win.cc
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/runtime/tiny.js" \
  -o gui/runtime/tiny.js
bash tools/build-launcher.sh        # 重新生成 tiny_client.h 并编译
php gui/php/test/smoke.php           # 验证线格式仍与宿主对齐
```

`xget.xi-xu.me` 是 GitHub 加速，国内直连 `raw.githubusercontent.com` 不可靠。

**把 `--typephp` 改动并入新版宿主时**，用 `git` 的 3-way merge 对齐那 4 个 hunk（集中在 spawn 后端与参数解析处），一般能直接合。验证：

```bash
bash tools/build-launcher.sh && php gui/php/test/smoke.php
```

注意：早期 `--typephp` 模式依赖上游 `cli.js` 的 `ensureLauncherFresh()` 在启动时重跑 `setup.ps1`（Windows SDK 的 WinRT 头）。融合后宿主由 `tools/build-launcher.sh` 编译、`build/winrt-shim` 提供 overlay，与上游 `setup.ps1` 无关，不再有这条联动。

---

## 已知限制

- **`--typephp` 目前只有 Windows。** 只有 `launcher-win.cc` 含 `--typephp`（已并入自有源码），`tgui dev` 在非 Windows 上因找不到 `launcher-win.exe` 而无法启动完整 GUI。见"支持一个新平台"。
- **Windows 上 `--nano` 是死路。** 它不是真 nano，而是 `bin` 策略包装：`NanoBuildBackend::forHost('Windows')` 硬编码返回 `WINDOWS_DLL`，所以链接的不是 freestanding php-nano，而是完整 PHP/PHPX DLL。实测产物依赖与 bin 版**完全相同**（15.5MB），体积只小 1.5%，而且 teardown **必定 SIGSEGV(139)**。小巧路线只在非 Windows 存在，且要先去 `getenv`/`gethostname`。
- **分发体积** ≈ `shim(128KB) + php.exe(≈180KB) + launcher(≈1.9MB) + 8 个 DLL(6 个 PHP ≈15.5MB + 2 个 MinGW ≈2.4MB)` ≈ **20.7MB（实测）**，不是 tinyjsapp 那种 ~6MB 单文件。换来的是单进程自包含、目标机不需要装 PHP。
- **`php.exe` 不自身包含运行时**，DLL 必须和它同目录（Windows 先在自己的 exe 目录找非 KnownDLL，所以同目录能钉住版本、也不依赖 PATH）。MinGW 运行时（libgcc/libstdc++）是 launcher 与 shim 都依赖的，同样必须随包分发。
- **后端单文件**（理由见上）；`composer.json` 因此没有 `autoload`。
- **`dev` 下后端是 exe 不是脚本**：shim 调 `execv` 时**不传参数**，所以后端必须能直接执行。POSIX 上有 shebang 的脚本可以，Windows 上必须是真 `.exe`。

---

## 相关文档

| 文档 | 内容 |
|---|---|
| `docs/GUI_FUSION_DESIGN.md` | 融合设计：迁移范围/目标、模块划分、集成方式、兼容策略、开发者友好设计 |
| `gui/README.md` | `gui/` 模块说明：布局、与上游的差异、构建、扩展、兼容 |
| `test/posix/README.md` | 套件每一档在测什么、两条路径规则、怎么拿出去独立用 |
| `docs/feasibility-aot-compiler-backend.md` | 最初的可行性调研 |
| `docs/nano-mode-ipc-addendum.md` | nano 模式与 IPC 的补充结论 |
| `docs/aot-compiler-nano-fix.md` | `--nano` 编译缺陷的源码级根因与修法 |
| `docs/landing-report.md` | 落地报告：实测结论、能力矩阵、体积现状 |
| `docs/launcher-patch-notes.md` | launcher 补丁的逐 hunk 说明 |
| `docs/planning/` | 开发计划与踩坑记录（`task_plan.md` 阶段表、`findings.md` 调研结论、`progress.md` 逐次 session 记录）。阶段编号 `16a`/`16b-1`/`16b-2` 被这三份文档与技能文档交叉引用，**不要重编号** |
| `evidence/` | 验证证据（截图、帧日志、套件日志） |
