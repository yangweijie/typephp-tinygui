# Shim 与 GUI 宿主

原生层：C++ launcher + shim。PHP 不出现在这一层。

## 结构

```
shim/backend_shell.cpp
gui/host/src/launcher-win.cc     # 含 --typephp
gui/host/src/launcher-linux.cc
gui/host/src/launcher-macos.cc
gui/runtime/tiny.js
gui/host/script/gen-client.sh    # tiny.js → tiny_client.h
gui/bin/tgui
```

## 关键文件

| 文件 | 目的 |
|---|---|
| `backend_shell.cpp` | 帧转发与 stderr 隔离 |
| `launcher-win.cc` | WebView2、dev 的 `--typephp` |
| `tgui` | 融合后的 CLI，替代上游 cli.js |

## 依赖

**本模块依赖**: WebView2 / WebKit；MinGW 或对应平台工具链。

**依赖本模块的**: `tgui dev/build`、演示 `demo/`。

## 规范

- 改协议字段须同时核对 PHP `Protocol` 与 launcher 读循环。
- 改 `tiny.js` 后重建 launcher。
- 不要把诊断打到 PHP stdout。
