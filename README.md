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
| Windows 开发方向（`tinyjs dev --typephp`） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 441ms` |
| Windows 打包方向（双击 `dist\<App>.exe`） | 窗口正常，**13 CALL / 13 RET**，`WINDOW-E2E OK ping=pong in 438ms` |
| 打包产物校验 | **0 failure / 0 warning** |

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
        │  (打了补丁)        │            │  自己是端点服务端   │
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

> `shim/backend_shell.cpp` 头部注释里有更详细的三种通道说明；`docs/` 下有完整的调研与落地记录。

---

## 目录结构

```
typephp-gui/
├── src/backend.php           PHP 后端。**唯一**后端源文件（见下文"为什么只有一个文件"）
├── bin/run-backend.php       用系统 PHP 直接跑同一份逻辑（不编译也能调试）
├── shim/backend_shell.cpp    C++ shim。Windows + POSIX 同一份源码
├── patches/                  上游补丁 + 它们要打的那个原始基线
│   ├── base/cli.js.orig            tinyjsapp v0.42.0 原始 cli.js
│   ├── base/launcher-win.cc.orig   tinyjsapp v0.42.0 原始 launcher-win.cc
│   ├── cli-typephp.patch           给 CLI 加 --typephp
│   └── launcher-win-typephp.patch  让 launcher 变成入口
├── tools/
│   ├── bootstrap-tinyjsapp.sh 把 checkout 在 pristine / patched 之间切换
│   ├── build-all.bat          Windows：编 shim + PHP 后端 → build/
│   ├── build-launcher.sh      编 launcher（离树，不碰 checkout）→ build/runtime/
│   ├── verify-bundle.py       发布前校验 dist/ 产物
│   └── e2e/                   截图 / 点窗口 / 关窗口的小工具（ctypes，无依赖）
├── demo/                     一个完整的 tinyjsapp 项目，用 PHP 后端
│   ├── tinyjs.json               "typephp" 块告诉 CLI 怎么构建
│   ├── build.bat                 构建钩子：把 build/ 的产物部署进 demo/backend/
│   └── src/frontend/index.html   页面，用 tiny.* 调后端
├── test/posix/               POSIX 验证套件（可独立拷出去用）
├── docs/                     调研、落地报告、补丁说明
│   └── planning/             开发计划 + 踩坑记录（task_plan / findings / progress）
├── experiments/              历史探针（保留但不参与构建）
├── evidence/                 验证证据：e2e 截图/日志 + 套件日志
├── build/                    所有生成物，git 忽略
└── composer.json             包元数据 + 快捷脚本（也是套件找仓库根的标记）
```

`build/` 里有什么：

```
build/
├── backend_shell.exe   shim
├── app.exe             PHP 后端（tpc 编出来）
├── *.dll               app.exe 依赖的 6 个 PHP 运行时 DLL（约 15.5MB）
├── launcher-win.exe    打了补丁的 launcher（dev 用）
├── runtime/            launcher + backend.exe + app.exe 三件套，可直接跑
├── gen/                由 base + 补丁派生出的 launcher-win.cc、tiny_client.h
├── winrt-shim/ include/ 下载的构建依赖，跨次缓存
└── checkout-residue/  restore 时从 checkout 里搬出来的东西（不删）
```

`build/` 下**唯独不包含**那份 PHP 运行时 DLL 的第二份副本——`demo/backend/` 里那份是从 `build/` 拷的，不是从 tpc 发行包再拷一次。

---

## 环境要求

| 用途 | 需要什么 |
|---|---|
| 后端编译 | aot-compiler 发行包（`tpc.exe`，本项目用 v0.9.3）+ MSVC（vcvars64） |
| shim 编译 | MinGW-w64 g++（`g++ -std=c++17`） |
| launcher 编译 | 同上 + 联网（下 WinRT 头文件和 `WebView2.h`，之后走缓存） |
| 运行 | tinyjsapp checkout（v0.42.0）+ WebView2 Runtime |
| 系统 PHP 调试（可选） | **PHP ≥ 8.1**（`array_is_list` 等） |
| POSIX 套件 | Linux / macOS / Cygwin + gcc/g++ + python3 |

路径都可用环境变量覆盖，不写死：

```bash
TPC_HOME=D:\git\php\tpc_v0.9.3_windows_x64   # tpc 发行包
TINYJSAPP=D:\git\web\tinyjsapp-0.42.0        # tinyjsapp checkout
VCVARS="D:\...\VC\Auxiliary\Build\vcvars64.bat"
```

---

## 快速开始

### 0. 准备 tinyjsapp checkout

```bash
git clone https://github.com/tarwin/tinyjsapp -b v0.42.0 D:/git/web/tinyjsapp-0.42.0
```

`bin/tjs.exe`（CLI 的运行器）由上游 `setup.ps1` 下载。

### 1. 给 checkout 打补丁

```bash
bash tools/bootstrap-tinyjsapp.sh status     # 先看看它现在是什么状态
bash tools/bootstrap-tinyjsapp.sh patch      # pristine + 我们的补丁
```

只有 **`cli.js` 必须就地打补丁**：`TOOL_DIR` 是从它自身位置推出来的（`new URL('.', import.meta.url)`），所以 CLI 只能在 checkout 里跑，也就在只能在 checkout 里改。

**`native/launcher-win.cc` 保持原始**——`tools/build-launcher.sh` 会自己从 `patches/base/` + 补丁派生一份来编译，不需要动 checkout。想恢复原样：

```bash
bash tools/bootstrap-tinyjsapp.sh restore    # 两个文件都还原，并把我们的产物搬出 checkout
```

### 2. 构建

```bash
# Windows：shim + PHP 后端 → build/
tools\build-all.bat

# launcher（离树编译）→ build/runtime/
bash tools/build-launcher.sh

# 想让 checkout 里也装好三件套、`tinyjs dev --typephp` 免环境变量就能跑：
bash tools/build-launcher.sh --install
```

### 3. 开发运行

```bash
cd demo
D:/git/web/tinyjsapp-0.42.0/bin/tjs.exe run D:/git/web/tinyjsapp-0.42.0/cli.js dev --typephp
```

不想往 checkout 里装东西的话，用 `TINYJS_LAUNCHER` 指到我们自己的产物：

```bash
TINYJS_LAUNCHER="$PWD/../build/runtime/launcher-win.exe" \
  D:/git/web/tinyjsapp-0.42.0/bin/tjs.exe run D:/git/web/tinyjsapp-0.42.0/cli.js dev --typephp
```

改 `src/backend.php` 会让后端重启（窗口闪一下）；改 `demo/src/frontend/` 只是页面重载。

调试输出**写 STDERR**：shim 给 stderr 单独一条管道，只抄进自己的日志，永远不混进帧流。看日志：

```bash
TYPEPHP_SHELL_LOG=D:/tmp/shim.log ... dev --typephp
tail -f D:/tmp/shim.log
```

> 往 **STDOUT** 上写任何非帧内容都会变成协议垃圾——STDOUT 就是帧通道。

### 4. 打包发布

```bash
cd demo
.../cli.js build   --typephp      # → demo/dist/
.../cli.js publish --typephp      # → 再压成 zip
python ../tools/verify-bundle.py dist \
       --launcher ../build/runtime/launcher-win.exe
```

产物：`<App>.exe`（= shim，双击入口，已置 GUI 子系统并嵌图标）、`launcher.exe`、`app.exe`、6 个 DLL、`frontend/`、`<App>.conf`。

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

一处改完：`src/backend.php` 的 `dispatch()` 里加个 `case`。

```php
case 'api.greet':                      // method 名随便起，页面按同名字符串调
    $who = (string)($params['name'] ?? 'world');
    return ["hello, {$who}", []];      // [结果, 要额外发的帧数组]
```

页面侧可直接调，**不需要动任何别的东西**：

```js
const r = await tiny.api.call('api.greet', { name: '老杨' });   // 注意是 tiny.api.call
// 或者用底层绑定（tiny.js 内部就是这么包的）：
await window.__invoke(JSON.stringify({ method: 'api.greet', params: { name: '老杨' } }));
```

`dispatch()` 返回 `[result, frames]`：
- `result` 会被 `jenc()` 成 JSON 放进 `RET`；
- `frames` 是在 `RET` **之前**发出去的裸帧（`TITLE`/`SIZE`/`EVAL`/`QUIT` 等）；
- 抛异常 → `status=1`，异常消息进 `result`。

想推事件给页面（不是应答），用 `emitEvent()`——它会生成一条 `EVAL` 帧：

```php
$frames[] = emitEvent('progress', ['pct' => 42]);   // 页面 tiny.api.on('progress', fn)
```

### 加一种帧类型

先问一句：**stock launcher 认不认这个帧？**

- **认**（`TITLE`/`SIZE`/`EVAL`/`EVAL@`/`QUIT`/`DLG`/`MENU*`）→ 只改 `src/backend.php`，往 `$frames[]` 里塞即可。**打包方向完全不受影响。**
- **不认** → 要同时改 `launcher-win.cc`，也就是往 `patches/launcher-win-typephp.patch` 里加 hunk（或新开一个 patch 文件）。代价：打包产物里的 `launcher.exe` 就不再是原版了。功能仍然正常——补丁保留了 stock 参数契约——但 `verify-bundle.py` 的"与构建源逐字节一致"只是相对我们自己而言。

所以：**能用现有帧就别加新帧。**

### 加一个页面 API（`tiny.xxx`）

`window.tiny` 是 launcher 把 `runtime/tiny.js` **编译进自身**后注入的（经 `gen/tiny_client.h` 嵌入）。这意味着：

1. 改 `runtime/tiny.js`（上游文件）加新 helper；
2. **必须重建 launcher** —— `tools/build-launcher.sh` 每次都会重新从 `runtime/tiny.js` 生成 `tiny_client.h`，所以重跑一遍就行。

如果只是"页面想调后端某个方法"，别走这条路——见上一节，`tiny.api.call()` 已经够了，加 `tiny.xxx` 只是语法糖。

### 给后端加状态 / 文件访问

`src/backend.php` 里的 `store.*` 用的是进程内数组（演示用途）。要持久化就自己接 SQLite / 文件——**注意**真 nano 模式下 `getenv` / `gethostname` 都不可用（`backend.php` 里只有 `sysinfo` 用到它们，已经标注），别用。

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

另外 `launcher-linux.cc` / `launcher-macos.cc` 目前**没有打过补丁**，`cli.js` 的 `dev --typephp` 也明确在非 Windows 上拒绝启动。所以 Linux 上目前能做的是：跑 shim（POSIX 分支已经 50/50 通过）+ 用真 nano 量体积，而不是跑完整 GUI。

### 为什么后端只有一个文件

`src/backend.php` 是**单文件、过程式**的，这不是偷懒：`tpc` 编译的是**单个入口文件**，`main()` 由编译器自动调用（所以系统 PHP 下要 `bin/run-backend.php` 手动调一次）。拆成 `Protocol.php` + `Backend.php` 那种"像样"的类结构，需要先验证 tpc 会不会跟着 `require` 递归编译——**没有验证过，所以没拆**。

`composer.json` 因此**故意没有 `autoload`**——这里没有类，加了是假的。

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
cd demo && TYPEPHP_SHELL_LOG=../evidence/e2e/dev.log .../cli.js dev --typephp
# 打包方向
cd demo/dist && TYPEPHP_SHELL_LOG=.../packaged.log "./TypePHP Demo.exe"
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

查四件 `tinyjs build --typephp` 自己不会告诉你、但每件都出过错的事：入口是不是 **GUI 子系统**（CUI 会让双击后一直挂个黑框）、入口有没有**图标资源**（`.conf` 里的 `icon=` 只管运行时窗口/任务栏）、`dist/launcher.exe` 是否和拷来的那份逐字节一致、`app.exe` + 6 个 DLL + conf + frontend 是否齐全。

---

## 维护与升级上游

两个文件是上游的，我们改了它们——但**都不是手改的**，各自有一份原始基线：

| 文件 | 基线 | 补丁 | 规模 |
|---|---|---|---|
| `cli.js` | `patches/base/cli.js.orig`（75,888 B，sha256 `07c78612…`） | `cli-typephp.patch` | 8 hunk，+324 / 改 3 行 |
| `native/launcher-win.cc` | `patches/base/launcher-win.cc.orig`（306,252 B，sha256 `d2fb5fed…`） | `launcher-win-typephp.patch` | 4 hunk |

两者都验证过：**基线 + 补丁 = 当前在用文件的 sha256**。launcher 的派生结果 `b940d4b1…` 与跑过全套验证的那份逐字节相同。

`cli.js` 那 3 行改写是**真的修 bug**，不是噪音：上游打包用 `tar -a -cf x.zip`，但 Windows 上的 `tar.exe` 可能是 GNU tar，而 **GNU tar 写不了 zip**——`-a` 配 `.zip` 名字会静默产出一个未压缩的 POSIX tar，直到用户打不开才发现。补丁加了 `zipTar()`（找 `%SystemRoot%\System32\tar.exe`，即 bsdtar 3.7.7）和 `assertRealZip()`（不是 zip 就报错）。

**升级到新版本上游：**

```bash
TAG=v0.43.0
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/cli.js" \
  -o patches/base/cli.js.orig
curl -fsSL "https://xget.xi-xu.me/gh/tarwin/tinyjsapp/raw/$TAG/native/launcher-win.cc" \
  -o patches/base/launcher-win.cc.orig
bash tools/bootstrap-tinyjsapp.sh patch     # 直接试打；有 reject 再修
```

hunk 少且集中在几处，一般能 rebase。`xget.xi-xu.me` 是 GitHub 加速，国内直连 `raw.githubusercontent.com` 不可靠。

**两个必须知道的联动**（都踩过）：

1. `cli.js` 的 `ensureLauncherFresh()`：当 `native/launcher-win.cc` 看起来比 `native/launcher-win.exe` 新时，`tinyjs dev` 会在启动前重跑 `setup.ps1`。**我们还原原始 `.cc` 正好会触发它**——而 MinGW 上这个重建**必然失败**（上游的 `setup.ps1` 指望 Windows SDK 的 WinRT 头，我们的 overlay 是故意放在 `build/winrt-shim` 的）。所以 `bootstrap patch` 会把我们编好的 launcher 装过去并把 mtime 顶到 `.cc` 之后。

2. 打了补丁的 CLI **硬编码**了 `TOOL_DIR + 'native/backend.exe'`，`dev` 和 `build` 都要用（**shim 兼作打包入口**，会改名成 `<App>.exe` 发出去）。所以 shim 也必须装在 checkout 里——128KB，而且那本来就是上游布局期望它待的地方。

---

## 已知限制

- **`--typephp` 目前只有 Windows。** 只有 `launcher-win.cc` 打了补丁，`cli.js` 在非 Windows 上会明确拒绝。见"支持一个新平台"。
- **Windows 上 `--nano` 是死路。** 它不是真 nano，而是 `bin` 策略包装：`NanoBuildBackend::forHost('Windows')` 硬编码返回 `WINDOWS_DLL`，所以链接的不是 freestanding php-nano，而是完整 PHP/PHPX DLL。实测产物依赖与 bin 版**完全相同**（15.5MB），体积只小 1.5%，而且 teardown **必定 SIGSEGV(139)**。小巧路线只在非 Windows 存在，且要先去 `getenv`/`gethostname`。
- **分发体积** ≈ `shim(128KB) + app.exe(≈180KB) + 6 个 PHP DLL(≈15.5MB)` ≈ **18.6MB**，不是 tinyjsapp 那种 ~6MB 单文件。换来的是单进程自包含、目标机不需要装 PHP。
- **`app.exe` 不自身包含运行时**，DLL 必须和它同目录（Windows 先在自己的 exe 目录找非 KnownDLL，所以同目录能钉住版本、也不依赖 PATH）。
- **后端单文件**（理由见上）；`composer.json` 因此没有 `autoload`。
- **`dev` 下后端是 exe 不是脚本**：shim 调 `execv` 时**不传参数**，所以后端必须能直接执行。POSIX 上有 shebang 的脚本可以，Windows 上必须是真 `.exe`。

---

## 相关文档

| 文档 | 内容 |
|---|---|
| `patches/README.md` | 两个补丁各改了什么、为什么这么存、怎么给新版上游重建基线 |
| `test/posix/README.md` | 套件每一档在测什么、两条路径规则、怎么拿出去独立用 |
| `docs/feasibility-aot-compiler-backend.md` | 最初的可行性调研 |
| `docs/nano-mode-ipc-addendum.md` | nano 模式与 IPC 的补充结论 |
| `docs/aot-compiler-nano-fix.md` | `--nano` 编译缺陷的源码级根因与修法 |
| `docs/landing-report.md` | 落地报告：实测结论、能力矩阵、体积现状 |
| `docs/launcher-patch-notes.md` | launcher 补丁的逐 hunk 说明 |
| `docs/planning/` | 开发计划与踩坑记录（`task_plan.md` 阶段表、`findings.md` 调研结论、`progress.md` 逐次 session 记录）。阶段编号 `16a`/`16b-1`/`16b-2` 被这三份文档与技能文档交叉引用，**不要重编号** |
| `evidence/` | 验证证据（截图、帧日志、套件日志） |
