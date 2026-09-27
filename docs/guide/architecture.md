---
title: 架构与调用链
description: 四个进程、一条 stdio 帧通道，以及"谁 spawn 谁"在三种形态下怎么变
---

# 架构与调用链

## 1. 四个进程，一个不变量

一个跑起来的 TypePHP GUI 应用有 **4 个进程**：

| 进程 | 是什么 | 源码 |
|---|---|---|
| WebView 里的页面 | 你的前端；调 `window.tiny.*` | `demo/src/frontend/`，运行时 `gui/runtime/tiny.js` |
| **launcher** | 宿主本体：建窗口、嵌 WebView、托盘、菜单、对话框、全局热键 | `gui/host/src/launcher-{win,macos,linux}.cc` |
| **shim** = `backend_shell` | 端点 ⇄ stdio 的翻译官，并且是 PHP 子进程的父进程 | `shim/backend_shell.cpp` |
| **PHP 后端** | `Tiny\Gui` 的 Dispatcher + Handlers | `gui/php/src/Tiny/Gui/`，入口 `bin/run-backend.php` |

**不变量（记住这一条能省很多推理）：端点的服务端永远是 shim，launcher 永远是客户端。**
launcher 侧所以要重试连接（`launcher-macos.cc` 在 typephp 模式下是 50 × 100 ms），
而 shim 在 `io_open_endpoint()` 里 `bind()+listen()`（POSIX）或 `CreateNamedPipeW()`（Windows），
再 `io_accept()` 等它进来。

那"三个平台方向不一样"指的是什么？**是父子关系（谁 spawn 谁），不是客户端/服务端角色。** 三种形态：

| 形态 | 谁起谁 | 端点名谁定 |
|---|---|---|
| 开发方向（Windows / macOS） | `tgui dev` → **launcher**（带 `--typephp`）→ spawn **shim** → spawn **PHP** | launcher 定（`tinyjs-typephp-<launcher pid>`），传给 shim |
| 打包方向（三平台一致） | 双击 **shim**（它就是入口）→ spawn **PHP** + spawn **原版 launcher** `<html> <endpoint> [title] [WxH] [ver]` | shim 定（见下面第 4 节） |
| Linux 开发方向 | `tgui dev` → **先起 shim**（它自己选端点名）→ 再起 **pristine `launcher-linux`** 连进来 | tgui/shim 定 |

Linux 之所以特殊，是因为 `launcher-linux.cc` **保持 pristine、一个字节都不改**（不移植 `--typephp`），
它没有"拉起后端"的能力，于是只能由 CLI 把两端分别起起来。这条约束是刻意的：分发出去的 launcher
必须是未修改的上游构建。

## 2. 为什么中间一定要有 shim

不是历史包袱，是能力缺口：

- launcher 说的是**字节流 IPC**（Windows 命名管道 / POSIX AF_UNIX）；
- 后端要能读的东西只有 **stdin/stdout**——PHP（尤其 tpc 编出的原生后端，甚至 php-nano）
  没有可用的 socket API；
- 所以 shim 把端点转成子进程 stdio：`socket → stdin/stdout`。

结果是一条清晰的通道纪律，整套验证体系都建立在它上面：

```
launcher  ⇄  [端点]  ⇄  shim  ⇄  (stdin/stdout)  PHP 后端
                             ↘  (stderr)  →  shim 日志（TYPEPHP_SHELL_LOG）
```

**stdout 只允许出现协议帧，后端与诊断信息只能走 stderr / shim 日志。**
这条不是风格问题：`log` 方法、PHP warning、扩展的噪音都会往 stderr 写，如果它们漏进 stdout
就会污染协议。为此套件里有一档专门的对抗测试（`test/posix/stderr-channel.sh` + `mock_backend_noisy.py`）：
让后端在被回答的**同一个 id** 上往 stderr 写一条与真实应答无法区分的诱饵 `RET <id> 0 …`，
要求客户端仍然全绿、诱饵只出现在 shim 日志里；再把诱饵信道翻成 stdout，客户端**必须**失败。

帧泵**不是**请求/应答串行泵：launcher 也会发不需要应答的通知帧（`WINSTATE` / `MENU` / …），
等 RET 会把代理死锁住。所以 shim 对两个方向做**非阻塞轮询 + 按方向重组行**，无线程、无 per-request 耦合。

## 3. 一次 `tiny.win.setTitle("hi")` 的旅程

```
页面   window.tiny.win.setTitle("hi")
        └─ tiny.js: call('win.setTitle', {…}) → window.__invoke(JSON)
宿主   launcher 把 JSON 写成一行帧送进端点
        CALL <id> ["{…}","<origin>"]
shim   读到行 → 原样写进 PHP 的 stdin
后端   Backend::run 泵 → Protocol::decode → Dispatcher 命中 WinHandler::win.setTitle
        发出 TITLE <t> 副作用帧，再回 RET <id> 0 true
shim   把 PHP stdout 的每一行送回端点
宿主   看到 TITLE 帧改窗口标题；看到 RET 把结果 resolve 回页面的 Promise
```

顺序有个硬约束：**窗口控制类帧（`TITLE` / `SIZE` / `QUIT` / `MENU*`）必须在对应 RET 之前发**，
详见 [帧协议](/guide/protocol.html)。

页面侧看到的 `tiny.*` 远多于后端注册的方法——`notify` / `dialog` / `clipboard` / `audio` / `theme` /
`win.close` 这些是 **launcher 原生实现**的，帧由宿主自己消化（对话框是 `DLG`，且**不发 RET**）；
只有需要业务逻辑的才落到 PHP。这条边界解释了为什么"后端没注册这个方法，页面却能用"。

## 4. 打包形态的产物布局与 conf

打包后 shim 就是用户双击的那个文件，它靠一个行式 `key=value` 的 `<exe_stem>.conf` 起飞
（C++ 侧不需要 JSON 解析器）。`stem_of()` 在**第一个** `.` 处截断，所以：

- mac：入口叫 `Contents/MacOS/<App>`（**不带点**），否则 conf 名会错配；
- Windows：`dist/<App>.exe` 是入口，PHP 后端刻意叫 **`php.exe`**（与入口不同名，否则互相覆盖，
  且 conf 的 `app=` 会指回 shim 自己）；
- Linux：目录式 bundle `dist/<App>/`，`<App>`（shim）+ `<App>.conf` + `launcher-linux` + `frontend/` + `app/`。

conf 的关键字段：`html` / `title` / `size` / `app`（后端）/ `launcher` / `icon`，路径全部相对 conf 所在目录。
shim 启动时把解析结果连同端点一起打进日志：

```
[shell] launch mode conf=… html=… title=… size=…
[shell] transport=unix-socket pipe=… app_kind=stock cwd=…
```

`app_kind` 是 shim 读后端二进制**首字节**分类出来的（`aot` / `stock` / `unknown`），
经 `TYPEPHP_APP_KIND` 注入后端——demo 页第 ⑤ 格显示的就是它，所以"未经 AOT"是后端自报的事实，不是文案。

## 5. 端点放在哪儿（这条改过一次，值得单独记）

打包方向的端点由 shim 决定：

- **Windows**：`\\.\pipe\tinyjs-typephp-<pid>`（命名管道，没有路径长度问题）；
- **POSIX（mac/Linux）**：默认 `<exe 目录>/app.sock`，但两种情况下必须搬走：
  1. 路径超出 `sun_path`（Linux 108 B / **mac 实测 104 B**）；
  2. **mac 专属**：exe 目录不在启动卷上——LaunchServices 拉起的进程在非启动卷上创建第一个新文件会
     阻塞在 TCC 卷授权里（bug #21）。

搬走时落到 `tmp_endpoint()`（优先 `$TMPDIR`），并且**把原因写进日志**：

```
[shell] endpoint moved off the app dir (app dir is not on the boot volume): <from> -> <to>
```

`tools/verify-bundle-macos.py` 用同一条规则镜像校验，构建时直接报出端点真实落点。
完整根因与验收见 [三平台差异](/guide/platforms.html)。

## 6. 代码地图

```
gui/
├── php/src/Tiny/Gui/        框架：Backend（泵）/ Protocol（编解码）/ Dispatcher / State /
│   └── Handlers/            AppRoot（fs 沙箱）+ Core/Win/Menu/Store/DemoApi 五个 Handler
├── runtime/tiny.js          页面侧 API；被 gen-client.sh 嵌进 tiny_client.h
├── host/src/                三个 launcher（win / macos 有 --typephp；linux 保持 pristine）
└── bin/tgui                 一条 CLI：dev / build / publish / init / status
shim/backend_shell.cpp       单文件双平台：io_t 原语 + 一份帧泵
bin/run-backend.php          后端入口（PSR-4 autoload 或 bootstrap.php）
demo/                        完整示例：src/backend.php + src/frontend/ + tinyjs.json
test/posix/ test/win/        验证套件与验收驱动（见验证矩阵）
evidence/                    实机日志、截图、manifest
```
