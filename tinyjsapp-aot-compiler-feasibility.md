# 使用 aot-compiler 实现 tinyjsapp 的可行性与实施方案调研报告

> 调研对象：
> - **tinyjsapp**（https://github.com/tarwin/tinyjsapp）—— 轻量跨平台桌面应用框架（txiki.js 后端 + 原生 webview 前端）。
> - **aot-compiler**（本地 `D:/git/php/aot-compiler`，即 Swoole TypePHP）—— PHP→C++17→原生机器码的 AOT 编译器。
>
> 调研时间：2026-09-25 ｜ 结论先行：**可行，但本质是“用 aot-compiler 重写后端与 CLI、复用 tinyjsapp 的 C++ 原生层”，而非“用 aot-compiler 编译 tinyjsapp”**。

---

## 1. 可行性结论（TL;DR）

| 维度 | 结论 |
|---|---|
| 能否“直接编译 tinyjsapp 的源码” | ❌ 不能。tinyjsapp 是用 **JavaScript（txiki.js）** 写的，aot-compiler 只编译 **PHP**。`src/main.js`、前端 `*.js`、`cli.js` 都需**用 PHP 重写**后由 tpc 编译。 |
| 能否复用 tinyjsapp 的“原生桌面能力” | ✅ 能，且几乎零成本。其全部原生能力（窗口/菜单/托盘/对话框/剪贴板/音频/钥匙串/Touch ID/OCR/AppleScript/录屏/通知/热键…）都在 **C++ launcher**（`native/launcher-*.cc`）里实现，与语言无关，可直接复用（MIT 许可证）。 |
| aot-compiler 在其中的角色 | 把**后端业务 + CLI 脚手架**编译为原生二进制；并通过 `embedded-files` 把前端 HTML/JS 打包进产物。 |
| 体积优势（~6MB 单文件） | ⚠️ 丧失。aot-compiler 的 `bin` 模式链接 `libphp`+PHPX，产物远大于 6MB；`--nano` 模式虽小但**无 socket/网络/进程执行能力**，无法承载桥接协议。 |
| 总体判定 | **技术可行，工程量大、风险中等**。最具性价比的路径是：保留 tinyjsapp 的 C++ launcher 作为原生层，仅用 aot-compiler 重写 Node/JS 侧的“后端宿主 + CLI”，并复刻其 `CALL`/`RET` 换行协议。 |

---

## 2. 项目一：tinyjsapp 分析

### 2.1 整体架构（三层 + 原生桥）

```
┌─────────────────────────────────────────────────────────────┐
│  CLI 层 (cli.js, 运行于 txiki.js)                            │  new/dev/build/publish/update
├─────────────────────────────────────────────────────────────┤
│  后端运行时层 (txiki.js 运行 src/main.js)                    │  导出 api{} + init(app)；app.push() 推事件
├───────────────────────┬─────────────────────────────────────┤
│  原生 Launcher (C++)   │  前端渲染层 (webview 内的 HTML/JS)   │
│  native/launcher-*.cc │  src/frontend/ + runtime/bridge.js   │
│  webview.h + 系统 API │  window.tiny.* 调用                  │
│  ★实现全部原生 tiny.* │                                      │
└───────────┬───────────┴──────────────────┬──────────────────┘
            │   换行协议: CALL <id> <json> / RET / GOT / DLG    │
            └───────────────  unix socket / named pipe ────────┘
```

关键事实（来自实际源码 `cli.js` / `runtime/tiny.js` / `native/launcher-win.cc`）：

1. **Launcher 拥有全部原生能力。** `launcher-win.cc` 顶部 `#include "webview/webview.h"` 并引入 `windows.h`、`shlobj`、`wincred`（钥匙串）、`mmdeviceapi`（音频 tap）、`windows.ui.notifications.h`、`windows.security.credentials.ui.h`（Windows Hello）等；macOS 版 `launcher-macos.cc`（393KB）同理。前端 `tiny.*` 里数十个 API（`win.*`、`menu.*`、`tray.*`、`dialog.*`、`clipboard.*`、`app.secrets`、`app.authenticate`、`macos.ocr`、`macos.recorder`、`app.captureScreen`…）**全部在 launcher 的 C++ 里直接实现**，并不经过 JS 后端。
2. **JS 后端的职责很薄。** 它只负责：`api.*` 方法分发、`app.push()` 事件推送、`tiny.fetch`（HTTP，由 txiki 发起）、`tiny.store`（持久化）、`system.info` 等少数“后端感知”的调用。其余 `tiny.*` 由 launcher 自行应答。
3. **通信协议是换行分隔的文本**，不是 HTTP。Launcher 源码注释明确：
   > “speaking the identical newline-delimited wire protocol, but over a named pipe”
   - Launcher → 后端：`` CALL <id> <json-args> ``（前端触发原生 op 或 `api.call` 时转发）。
   - 后端 → Launcher：`` RET <id> <json> ``（应答 `CALL`）、`` GOT <qid> <json> ``（应答带 qid 的原生 op）、`` DLG `` / `` SECRET ``（对话框/钥匙串回写）。
   - 后端还可主动推送事件，由 launcher 注入页面 `window.__emit({event, data})`。
4. **进程模型灵活**：dev 模式下 CLI 拉起后端（txiki），后端建好 pipe 再 `spawn` launcher；打包模式下 launcher 是主可执行文件，自己 `spawn` 后端（launcher 的 `--run` 分支接收 `html 路径 / pipe 名 / 标题 / 尺寸` 并 `CreateProcess` 拉起 `exe`+`arg`）。**谁父谁子可互换，协议对称。**

### 2.2 核心功能
脚手架/热重载、原生 UI（菜单/托盘/右键菜单/对话框/通知）、窗口管理（多窗口/无边框/透明/vibrancy/拖拽/录屏/PDF 打印）、系统深度集成（剪贴板/全局热键/键击合成/shell 动词/钥匙串/Touch ID/OCR/AppleScript/本地 LLM）、音频（sampler 混音、audioTap PCM、audio.filters DSP）、数据通信（`tiny.fetch` 无 CORS、`tiny.proxyURL`、`tiny.store`）、分发与更新（签名打包、自动更新、单实例、URL Scheme/文件关联）。

### 2.3 运行机制与依赖
- **运行时依赖**：txiki.js（JS 运行时，提供系统调用 + SQLite）、webview 库（macOS WebKit / Windows WebView2 / Linux WebKitGTK）、系统库（WebAudio、GStreamer 等）。**明确排除** Electron/Node/Chromium。
- **构建依赖**：esbuild（打包 TS 后端）、可选 Vite（前端 HMR）、MinGW-w64（Windows 编译 txiki + launcher）、cmake/ninja（txiki 源码编译）。
- **语言**：JS（后端/前端/CLI/桥）、C/C++（launcher）、Shell/PowerShell（安装）、TypeScript（类型与可选模板）、HTML/CSS。

---

## 3. 项目二：aot-compiler（TypePHP）分析

### 3.1 功能定位
将 **PHP 源码** 翻译为 **C++17** 再编译为原生机器码，生成 `bin`（可执行文件）/ `ext`（PHP 扩展）/ `lib`（共享库）/ **nano**（无 libphp 的极简程序）/ **WASI** / iOS / Android 产物。纯 PHP 实现、可自举。保留 PHP 语法并引入编译期类型信息；动态值/内置函数/反射通过 **PHPX + Zend runtime** 互操作，用户函数编译后不再以 Zend opcode 执行。

### 3.2 处理流程
```
PHP 源码 + .stub.php 声明 + 可选 C/C++ 源码
   → 解析/校验/收集声明（prepare 阶段只建符号模型）
   → 函数体 + 常量表达式降级为 C++17（convert 阶段）
   → 原生编译器 + 可复用对象/PCH 缓存
   → 可执行文件 | PHP 扩展 | 共享库 | WASI Component
```

### 3.3 支持的输入/输出形式
- **输入**：PHP 源文件（受支持的子集）、`.stub.php`（声明 Zend/C++ ABI）、可选 `.cc/.cpp`（混合 C++）。
- **输出**：`bin` / `ext` / `lib`；`--nano` 单文件极简程序；WASI 0.2 / 浏览器（Jco）；iOS / Android 原生。
- **资源打包**：`embedded-files`（仅 `mode: bin`）可将 Composer 依赖、前端资源（HTML/JS/JSON/模板）以 opcode/字节形式打包进二进制。
- **C++ 互操作**：`.cc` 文件 + `.stub.php`，暴露 `php_*` 函数给 PHP（`php::Box` 管理对象生命周期），可绑定任意 C/C++ 库。

### 3.4 使用限制（与本次目标强相关，取自 `docs/en/INCOMPATIBLE_PHP_FEATURES.md`）
- 全局作用域不允许可执行语句；必须定义全局 `main()`（无参或 `(int $argc, array $argv)`，返回 `void`）。
- 不支持可变变量 `$$var`；`Closure::bind/bindTo/call` 不支持；动态类名/函数名走 Zend 回退、不被原生优化。
- 严格类型始终开启（`declare(strict_types=1)` 冗余，`:0` 被拒）。
- `match` 臂不能是 `match`；`switch` 非空分支必须以 `return/break/continue/exit/throw` 结束。
- 生成器用 `FiberGenerator`，不等于 Zend `Generator`；WASI 不支持 Fiber/Generator。
- **`--nano` 模式无 socket、DNS、网络、远程 stream、动态 PHP 加载、进程执行能力**；WASI 能力子集更小。

> 关键约束：**本方案必须采用 `bin` 模式**（链接 libphp，拥有完整 PHP 的 socket/proc_open 能力）。`--nano` 虽小但缺网络/进程能力，无法承载 launcher 桥接协议。代价是产物需随附 `libphp`+PHPX 运行时，体积远大于 tinyjsapp 的 ~6MB。

---

## 4. 可行性评估

### 4.1 哪些部分可由 aot-compiler 直接/经重写实现
| tinyjsapp 部件 | 是否可由 aot-compiler 承担 | 说明 |
|---|---|---|
| **CLI（`new`/`dev`/`build`/`publish`/`update`）** | ✅ 重写后编译 | 纯编排逻辑（建目录、写模板、调构建、复制文件、spawn 进程）。在 PHP 子集内可写，由 `tpc` 编为原生 `bin`。 |
| **后端宿主（建 pipe、spawn/连接 launcher、应答 `CALL`/`RET`）** | ✅ 重写后编译 | `bin` 模式有 unix socket / named pipe + `proc_open`，完全胜任。 |
| **用户 `api` 分发 + `app.push` 事件** | ✅ 重写后编译 | 即把 `src/main.js` 的 `api{}`/`init(app)` 改写为 PHP 等价物（如 `TinyApp` 类 + `registerApi()` + `push()`）。 |
| **`tiny.fetch` / `tiny.store` / `system.info` 等后端感知调用** | ✅ 重写后编译 | 用 PHP 的 `stream_socket`/`file_*` 实现；`embedded-files` 可打包前端资源。 |
| **前端 HTML/JS + `runtime/tiny.js`/`bridge.js`** | ✅ 直接复用 | 在 webview 内运行，与语言无关；保持不变即可。可由 `embedded-files` 打包进二进制。 |
| **C++ Launcher（`native/launcher-*.cc`，全部原生 `tiny.*`）** | ➖ 不归 aot-compiler 管 | 它是独立 C++ 工程（cmake 构建），**直接复用**（MIT）。不要尝试用 aot-compiler 重写它——毫无收益且高危。 |
| **打包/签名/公证/自动更新** | ➖ 不归 aot-compiler 管 | `tpc` 只产出 PHP 侧二进制；`.app`/`.msix`/`.deb` 打包与_notarize 仍需 cmake/CI 处理（可部分用 PHP CLI 编排）。 |

### 4.2 能力缺失或需改造
1. **语言不匹配（最根本）**：tinyjsapp 是 JS，aot-compiler 只吃 PHP。所有 JS 代码必须**语义重写**为 PHP，再编译。这不是“移植编译”，而是“重新实现”。
2. **原生 UI/OS 能力不是 aot-compiler 提供的**：窗口、菜单、托盘、对话框、音频、钥匙串、Touch ID、OCR、录屏、通知、热键…全部在 C++ launcher。aot-compiler 至多通过 `php_*` 绑定“调用”它们，但绑定本身不创造能力——能力来自复用的 launcher。
3. **体积优势丧失**：`bin` 模式链接 libphp+PHPX，产物数十 MB 起；无法复现 tinyjsapp ~6MB 两文件形态。
4. **动态特性受限于 PHP 子集**：若 CLI/后端用到 `eval`、运行时动态 `include`、可变变量、`Closure::bind`、动态类名等，需改造为静态可编译形态。
5. **协议细节未文档化**：`CALL`/`RET`/`GOT`/`DLG` 的精确字段、事件推送动词、握手顺序，需从 `launcher-*.cc`（300–400KB）反推，属实现期风险。

### 4.3 需要的适配
- **接口适配**：在 PHP 端实现 `BackendHost`，读写换行文本协议：解析 `` CALL <id> <json> ``，按 `method`（如 `api.call`、`fetch`、`store.get`、`system.info`、`app.paths`…）路由到 PHP handler，回写 `` RET <id> <json> ``；用 launcher 规定的事件推送动词把 `app.push()` 注入页面。需先确认 launcher 把哪些 method **转发给后端**（多数是 `api.*` 与 fetch/store 等少数），其余由 launcher 自答。
- **数据结构适配**：`tinyjs.json`（应用配置）可原样复用（JSON）；`.build/app/app.json` 清单与 `tiny.*` 方法名需与 launcher 期望一致；`api` 方法签名（`{name, params}`）在 PHP 侧重新建模。
- **构建与运行流适配**：
  - 旧：`setup.sh` 构建 txiki.js + launcher；`tinyjs dev` → txiki → launcher。
  - 新：**launcher 用 cmake 单独构建（复用 tinyjsapp 的构建，仅把“被 spawn 的后端 exe”指向 aot 产物）**；**后端+CLI 用 `tpc project.yml` 编为 `bin`**。CLI 的 `dev`/`build` 改为调用 `tpc` 与 launcher 二进制。
  - 进程模型：保持对称——dev 时 PHP CLI 拉起 PHP 后端宿主，后端建 pipe 后 spawn launcher（传 pipe 名）；打包时 launcher（父）spawn PHP 后端（子，从 argv 读 pipe 名）。launcher 的 `--run` 分支本就接收 `exe`+`arg`，**很可能零改动 launcher** 即可指向 PHP 二进制。

---

## 5. 关键差异与潜在风险

1. **“实现” vs “编译”的概念陷阱**：把 tinyjsapp 当“可被 aot-compiler 编译的项目”是错误前提。正确前提是“用 aot-compiler 作为工具链，重写其 JS 侧为 PHP 原生二进制”。
2. **原生层必须外部复用**：任何试图用 aot-compiler 重建窗口/菜单/音频/钥匙串的尝试都会失败或成本爆炸；这些是 C++（webview + OS API），只能复用 `launcher-*.cc`。
3. **体积/分发倒退**：libphp 链接使单文件优势不再；且 `bin` 产物须随附 libphp/PHPX 运行时（或静态链接配置），打包体积与依赖管理比 tinyjsapp 重。
4. **协议耦合风险**：launcher 与后端通过隐式换行协议耦合，字段顺序/握手未正式文档化；改错一端即整链路失效。需先做协议嗅探（Phase 0 探针）。
5. **编译器成熟度风险**：aot-compiler 自述“仍在积极开发中，提供边界明确、可测试的 PHP 子集，而非宣称无修改替代所有动态 PHP”。在其上承载一个生产级桌面框架，需把后端逻辑控制在受支持子集内，并保留“回退到 ZendVM 执行未编译代码”（`embedded-files` 机制）的退路。
6. **跨平台构建矩阵**：launcher 的 mac/linux/win 三套 C++ 仍需分别在对应平台用 cmake 构建；aot-compiler 也需在三平台各自用匹配版本的 libphp 编译。CI 复杂度加倍。
7. **许可证合规**：tinyjsapp 为 **MIT**（已确认），复用/修改 launcher 合法，但须保留版权声明；aot-compiler 为 **GPL-3.0**（README 标注），若将其编译器产物用于闭源分发需评估 GPL 传染性（编译出的应用二进制是否触发 GPL 需法务确认）。

---

## 6. 需要改动的具体位置清单

| 编号 | 位置（tinyjsapp 仓库） | 改动动作 | 是否归 aot-compiler |
|---|---|---|---|
| A1 | `cli.js` | 重写为 `cli.php`（`new/dev/build/publish/update`），由 `tpc` 编译为原生 bin；内部调用 `tpc` 与 launcher 构建 | ✅ 是 |
| A2 | `src/main.js`（用户后端模板） | 提供 PHP 等价模板 `src/main.php`（`api{}` + `init(app)` → PHP `TinyApp` API） | ✅ 是 |
| A3 | （新增）后端宿主 | 新建 PHP `BackendHost`：建 unix socket/named pipe、spawn/连接 launcher、解析 `CALL`、回 `RET`/`GOT`、推送事件 | ✅ 是 |
| A4 | `project.yml`（aot-compiler） | 新建：声明 PHP 源、设置 `mode: bin`、`embedded-files` 包含前端 HTML/JS 与模板；`cxx-flags` 本方案不需（launcher 独立构建） | ✅ 是 |
| A5 | `runtime/tiny.js` / `bridge.js` | **不改**，直接复用；可经 `embedded-files` 打包 | ➖ 否 |
| A6 | `src/frontend/**`（用户页面） | **不改**，直接复用 | ➖ 否 |
| A7 | `native/launcher-win.cc` / `launcher-macos.cc` / `launcher-linux.cc` | **基本不改**；仅确认 `--run` 分支的 `exe`+`arg` 能指向 aot 产物（大概率零改动） | ➖ 否（C++） |
| A8 | `native/tiny_client.h`（由 `runtime/tiny.js` 经 gen-client 生成） | **不改**，随 launcher 构建 | ➖ 否 |
| A9 | `setup.sh` / `setup.ps1` | 拆分为两步：① launcher 的 cmake 构建（保留）② 后端+CLI 的 `tpc` 构建（新增） | 部分 |
| A10 | `template/`（脚手架模板，原产 JS/TS） | 改为产 PHP 后端模板与 `tinyjs.json` 之外的 `project.yml` 片段 | ✅ 是 |
| A11 | 打包/签名/公证/自动更新脚本 | 保留 tinyjsapp 的 `build`/`publish` 逻辑，把“后端 exe”替换为 aot 产物；签名/notarize 仍走原流程 | ➖ 否 |

> 核心改动集中在 **A1–A4、A10**（PHP 侧，由 aot-compiler 编译）；A5–A9、A11 基本复用或仅做轻量接线。

---

## 7. 分阶段实施建议

**Phase 0 — 协议与能力探针（1–2 周）**
- 写一个最小 PHP `bin`（aot-compiler 编译）：建立 unix socket/named pipe，监听并 `echo` 收到的 `` CALL `` 行，记录字段。
- 用原版 tinyjsapp launcher（不改）spawn 该 PHP 探针，抓包确认 `CALL`/`RET`/`GOT`/`DLG` 的真实字段、握手顺序、事件推送动词。
- 验证 aot-compiler `bin` 模式的 `proc_open` + socket + `embedded-files` 三项能力可用（已有同类证据：用户自研的 aot-compiler WebSocket 代理二进制即依赖 bin 模式的 socket 能力）。

**Phase 1 — 三角连通（2–3 周）**
- 实现 `BackendHost`：应答 `client.hello` 与 `api.echo`，支持 `app.push` 回推事件。
- 用复用 launcher + PHP 后端跑通“页面按钮 → `tiny.api.call` → launcher `CALL` → PHP 应答 `RET` → 页面更新”的最小闭环。
- 确认 dev 模式（PHP 父 spawn launcher）与打包模式（launcher 父 spawn PHP 子）两种进程模型都成立。

**Phase 2 — CLI 与脚手架（2–3 周）**
- 把 `cli.js` 的 `new/dev/build/publish` 重写为 PHP 并由 `tpc` 编译。
- `template/` 改为生成 PHP 后端模板 + `project.yml` 片段；`embedded-files` 打包前端资源。
- 验证 `tinyjs dev` 热重载链路（后端进程重启、前端就地重渲染）。

**Phase 3 — 后端能力对齐（3–4 周）**
- 实现 launcher 转发给后端的方法子集：`api.call`、`tiny.fetch`、`tiny.store`、`system.info`、`app.paths` 等（以 Phase 0 抓包为准）。
- 其余 `tiny.*`（窗口/菜单/托盘/对话框/音频/钥匙串…）**无需 PHP 工作**，来自 launcher。
- 在该阶段即可获得与原版对等的应用开发体验（除极少数 macOS-only / Windows-only 特性）。

**Phase 4 — 打包硬化（2–4 周）**
- 单实例、URL Scheme / 文件关联、自动更新、`build`/`publish` 的 `.app`/`.msix`/`.deb` 打包与签名/notarize——复用 tinyjsapp 原流程，仅替换后端 exe。
- 体积优化评估：若必须缩小，可研究“nano 模式 + 自写 C++ socket 层经 `php_*` 绑定”的路线（高风险，留作备选）。

**Phase 5（可选/延伸）**
- 把 tinyjsapp 个别未覆盖的原生特性（如某平台特定音频 EQ）按需补进复用的 launcher。
- 评估 GPL-3.0 分发合规（见风险 7）。

---

## 8. 证据与参考文件
- tinyjsapp 实际源码（经 xget 代理获取）：`cli.js`、`runtime/tiny.js`、`native/launcher-win.cc`（含 `#include "webview/webview.h"`、各 OS API 头、`CALL`/`RET`/`GOT`/`DLG` 协议注释）、`LICENSE`（MIT）。
- aot-compiler 文档（本地）：`README-CN.md`（工作原理/三种构建模式/nano 限制）、`docs/en/INCOMPATIBLE_PHP_FEATURES.md`（PHP 子集限制）、`docs/en/MIXED_CPP_PHP.md`（C++ 互操作）、`docs/en/EMBEDDED_FILES.md`（资源打包）、`project.yml`（cxx-flags / sources 配置示例）。
- 旁证：用户既有项目“自研单文件 WebSocket 代理（aot-compiler 编译为原生二进制）作为浏览器↔MySQL 桥接层”——印证 `bin` 模式的 socket/网络能力可用于此类桥接场景。

---

### 一句话总结
**aot-compiler 能做的是“把 tinyjsapp 的 JS 后端与 CLI 重写并编译为 PHP 原生二进制”，而 tinyjsapp 真正的价值——原生 webview 窗口与全套 OS 集成——早已在它的 C++ launcher 里，可直接复用。因此可行方案是“PHP 后端（aot-compiler 编译）+ 复用 C++ launcher + 复刻换行协议”，代价是失去 ~6MB 单文件优势并接受 GPL-3.0 合规约束。**
