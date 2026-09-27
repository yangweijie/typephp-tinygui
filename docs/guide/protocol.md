---
title: 帧协议
description: 一行一帧的文本协议：语法、转义、状态码、通知帧，以及 stdout/stderr 的纪律
---

# 帧协议

launcher ⇄ shim ⇄ PHP 后端之间是**一行一帧**的文本协议（`\n` 分隔）。
编解码全部在 `gui/php/src/Tiny/Gui/Protocol.php`，泵在 `Backend.php`，
C++ 侧只做字节代理（`shim/backend_shell.cpp`），**不解析帧内容**。

存在理由见 [架构](/guide/architecture.html)：宿主不执行 PHP，PHP 不直接连命名管道。

## 1. 语法总览

```
launcher → 后端
  CALL <id> <json-array>          json-array = ["<payload>","<origin>"]
  WINSTATE <win> <json>           窗口状态变化（最小化/最大化/…）
  SYS <kind> <value>              系统事件（含 theme）
  SYSLOCALE <json>                区域设置
  MENU <id>                       菜单项被点
  TRAY <id>                       托盘项被点
  TRAYCLICK                       托盘图标本体被点

后端 → launcher
  RET <id> <status> <json>        应答；status 0 = ok，非 0 = 错误（宿主按 rejected 处理）
  TITLE <t> | SIZE <w> <h> | QUIT 窗口副作用帧
  DLG <id> <op>\t<args>           对话框：由 launcher 自己应答，后端不发 RET
  MENUBEGIN … MENU/ITEM/SEP/SUB … MENUEND   整块原生菜单栏
  EVAL <js> | EVAL@<win> <js>     向页面推事件（后端一般用 Protocol::event()）
```

`Protocol::decode()` 对**未知前缀**（`NAV` / `DROP` / `GOT` / `HOTKEY` …）返回
`['type' => 'ignore']`——不炸、不应答。

> **已记录的缺口**：`HOTKEY ` 没有分支，所以页面永远收不到全局快捷键事件；
> 后端侧也没有 `tray.set` / `hotkey.register` 两个方法（托盘/热键那部分验收是用
> `test/posix/mock_shim.py` 注入帧驱动的）。这两条是**有意未修**的产品缺口，
> 记在 `docs/planning/task_plan.md` 的 Phase 23 段。

## 2. 三条硬规则

### 字段内不许有裸换行

帧以 `\n` 分隔，所以字符串必须转义。`Protocol::esc()` 做
`\ → \\`、`tab/CR/LF → \t/\r/\n`；`Protocol::one()` 更粗暴，把 tab/CR/LF 一律换成空格，
用于"绝不能破坏帧、内容其次"的字段（标题之类）。

### 窗口副作用帧必须发在对应 RET **之前**

`Response` 因此把 `frames` 和 `result` 分开：

```php
return Response::ok(true, ['QUIT']);        // 先发 QUIT，再发 RET
return Response::ok(['php' => PHP_VERSION]);
return Response::error('unknown method');   // status=1，result 是错误文本
```

`Backend` 按 `frames…\n` + `RET …\n` 的顺序一次性写出并 `fflush`。

### stdout 只能出现帧

`READY\n` 是唯一例外——后端启动时先写它，shim 据此知道子进程活了。
其余任何输出（PHP warning、扩展噪音、`tiny.log()`）都必须走 **stderr**，
由 shim 收进日志文件（`TYPEPHP_SHELL_LOG`）。这条有专门的对抗测试档，
翻车表现是"客户端收到一条它以为来自后端的假 RET"，所以不能靠运气：
见 `docs/reference/posix-kit.html` 的 stderr-channel 一节。

## 3. JSON 与失败处理

- `Protocol::jenc()` = `json_encode(JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)`。
  抛异常是有意的：泵会把它变成 `RET status=1`，而不是发字面量 `false`。
- `Backend::safeRet()` 是最后一道：连"错误消息本身也编码不了"时退化成手写的一条
  `RET <id> 1 "json encode failed"`，保证协议层永远不会吐半帧。
- 每帧后必须 `fflush`——漏掉就是块缓冲 hang（早期真 bug 之一：`RET` 已生成但 launcher 收不到）。

## 4. 页面侧的对应物

页面不写帧，只调 `window.tiny.*`。`gui/runtime/tiny.js` 里每个方法都塌成一行：

```js
const call = (method, params) => window.__invoke(JSON.stringify({ method, params }));
```

`window.__invoke` 由宿主注入；回来的 `RET` 的 `json` 就是 Promise 的 resolve 值，
`status != 0` 走 reject。反方向（宿主 → 页面）是 `EVAL@* window.__emit({...})`，
`tiny.api.on(event, fn)` 就是它的订阅端。

## 5. 非交互验证怎么做

真窗口验证需要点菜单、弹文件对话框，CI 里没人点。两个机制：

- `TINYJS_TEST_AUTODLG=ok`：launcher 自动应答 modal 对话框（`tiny.getMedia` 之类同理），
  于是原生 UI 也能**非交互**跑完；
- `test/posix/mock_launcher.c`（C，不是 Python）：POSIX 套件里当协议客户端。
  用 Python 不行——Cygwin 上 CPython 的 AF_UNIX 和原生 Cygwin AF_UNIX 像两个平面，
  C 服务端 + Cygwin Python 客户端会 `ECONNABORTED`，报出来的"shim 失败"其实是客户端运行时假象。

## 6. 一次完整往返的样子

```
[shell] L->P: CALL 7 ["{\"method\":\"sysinfo\",\"params\":{}}","http://localhost/"]
[shell] P->L: RET 7 0 {"php":"8.5.7","backend":"stock PHP CLI (no AOT)",…}
```

demo 页里那枚 `CALL SYSINFO → RET` 面板显示的就是这两行，`WINDOW-E2E OK ping=pong in Nms`
marker 由前端在第 N 帧往返后打到 console。验收脚本一律按
`CALL=` / `RET=` **配平**来判，而不是"看到几帧"——配平失败才说明有方法没应答。
