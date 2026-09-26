# TypePHP GUI 文档

DeepWiki 风格说明：仓库如何把编译后的 PHP 接到融合版 tinyjsapp 宿主上。面向要改协议、扩展 handler、或打包 Windows 桌面应用的开发者。

**快速链接**: [架构](./ARCHITECTURE.md) | [接口](./INTERFACES.md) | [开发者指南](./DEVELOPER_GUIDE.md)

更长的调研与融合设计仍在仓库根 `docs/`、`README.md`（本 wiki 不替代它们）。

---

## 核心文档

### [架构](./ARCHITECTURE.md)

分层（页面 → launcher → shim → `Tiny\Gui`）、dev/packaged 两种拉起方式、技术栈。

### [接口](./INTERFACES.md)

帧语法、内置 `tiny.*` 方法、沙箱、tgui、Composer 脚本、环境变量。

### [开发者指南](./DEVELOPER_GUIDE.md)

工具链、`tgui dev/build`、加方法、smoke。

---

## 模块

| 模块 | 描述 | 文档 |
|---|---|---|
| `gui/php` | PHP 协议框架 | [Tiny-Gui](./模块/Tiny-Gui.md) |
| `shim/` + `gui/host` | C++ 代理与 WebView 宿主 | [Shim与宿主](./模块/Shim与宿主.md) |
| `tools/` + `test/` | 构建与验证 | [构建与验证](./模块/构建与验证.md) |

---

## 核心概念

| 概念 | 描述 |
|---|---|
| [帧协议](./专有概念/帧协议.md) | CALL/RET/DLG/EVAL 行协议 |
| [Shim](./专有概念/Shim.md) | IPC ↔ stdio |
| [AppRoot 沙箱](./专有概念/AppRoot沙箱.md) | listDir/fs 根 |
| [Dispatcher](./专有概念/Dispatcher.md) | method 路由与空应用/演示分集 |

---

## 入门指南

1. [架构](./ARCHITECTURE.md)
2. [核心概念](#核心概念)
3. [开发者指南](./DEVELOPER_GUIDE.md)
4. [接口](./INTERFACES.md)

集成页面 API：先读接口中的方法表。贡献 PHP：先跑 `php gui/php/test/smoke.php`。

---

## 快速参考

```bash
php gui/php/test/smoke.php
composer test
cd demo && bash ../gui/bin/tgui dev
tools\build-all.bat
python tools/verify-bundle.py
```

| 文件 | 目的 |
|---|---|
| `src/backend.php` | 演示入口 `Gui::serveDemo()` |
| `gui/php/src/Tiny/Gui/bootstrap.php` | tpc require 清单 |
| `composer.json` | project 模板，非库 |
| `README.md` | 人类上手的主文档 |
