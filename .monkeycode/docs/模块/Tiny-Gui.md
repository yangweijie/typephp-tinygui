# Tiny\Gui（`gui/php`）

PHP 侧协议框架：解码、路由、沙箱、内置窗口/菜单/存储。tpc 通过 `bootstrap.php` 打进单一入口文件。

## 结构

```
gui/php/src/Tiny/Gui/
├── bootstrap.php
├── Protocol.php / Backend.php / Dispatcher.php / Gui.php
├── AppRoot.php / Request.php / Response.php / State.php
├── HandlerInterface.php
└── Handlers/
    ├── CoreHandler.php
    ├── WinHandler.php
    ├── MenuHandler.php
    ├── StoreHandler.php
    └── DemoApiHandler.php
gui/php/test/smoke.php
```

## 关键文件

| 文件 | 目的 |
|---|---|
| `Gui.php` | `serve` / `serveDemo` / dispatcher 工厂 |
| `Backend.php` | stdin 循环、`processLine`、`safeRet` |
| `Protocol.php` | 帧文本 ↔ 值；对话框短路 |
| `AppRoot.php` | fs 沙箱 |
| `bootstrap.php` | tpc/系统 PHP 的 require 清单 |

## 依赖

**本模块依赖**: 仅 PHP 8.1+ 标准库。

**依赖本模块的**: `src/backend.php`、`bin/run-backend.php`、smoke。

## 规范

- 新 handler：实现 `HandlerInterface`，在应用入口 `add`，不要塞进 `defaultDispatcher` 除非所有空应用都需要。
- 测试：给 `Backend::processLine` 喂 CALL 行，断言 stdout 字符串。

## 添加新文件

1. 放到 `gui/php/src/Tiny/Gui/` 并加入 `bootstrap.php` 的 `require_once`（否则 tpc 编不到）。
2. PSR-4 `Tiny\\Gui\\` → `gui/php/src/Tiny/Gui/` 与目录一致。
3. 在 smoke 加用例。
