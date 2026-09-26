# 开发者指南

## 项目目的

TypePHP GUI 是「PHP AOT 后端 + 融合版 tinyjsapp 宿主」的应用模板，不是 Packagist 可复用库（`composer.json` 已声明）。

**核心职责**:
- 用 `Tiny\Gui` 应答 tinyjsapp 帧协议
- 用 shim 连接 launcher IPC 与 PHP stdio
- 提供 `tgui` 开发/打包路径

**相关系统**:
- aot-compiler（`tpc`）— 把 `src/backend.php` 编成 `app.exe` / 打包名 `php.exe`
- tinyjsapp 上游协议 — 帧格式保持兼容；宿主源码在 `gui/host`

## 环境搭建

### 前置条件

- Windows 桌面方向：WebView2 Runtime、MinGW-w64 g++、MSVC vcvars64、tpc（文档口径 v0.9.3）
- 系统 PHP ≥ 8.1：无窗口调试与 `composer test`
- POSIX 套件：Linux/macOS/Cygwin、gcc/g++、python3、bash
- 首次编 launcher：联网（WinRT / WebView2 头，之后缓存）

不再需要外部 tinyjsapp checkout。

### 安装

```bash
git clone <本仓库 URL>
cd typephp-gui
# 无 composer install 运行时依赖；autoload 仅便于系统 PHP 加载 Tiny\Gui
```

AOT 与 shim：

```bash
bash tools/build-launcher.sh
tools\build-all.bat
```

### 环境变量

见 [INTERFACES.md](./INTERFACES.md) 表格。示例：`TPC_HOME`、`VCVARS`、`TYPEPHP_SHELL_LOG`。

⚠️ 不要提交密钥。本仓库无 `.env.example`。

### 运行

```bash
cd demo
bash ../gui/bin/tgui dev
```

不编译跑后端逻辑：

```bash
php bin/run-backend.php
```

（仍需 shim/launcher 才能出窗口。）

测试：

```bash
php gui/php/test/smoke.php
composer test
python tools/verify-bundle.py
```

打包：

```bash
cd demo
bash ../gui/bin/tgui build
bash ../gui/bin/tgui publish
python ../tools/verify-bundle.py dist --launcher ../build/runtime/launcher-win.exe
```

## 开发工作流

### 代码质量工具

| 工具 | 命令 | 目的 |
|---|---|---|
| 协议 smoke | `php gui/php/test/smoke.php` | CALL/RET、沙箱、坏帧 |
| POSIX 套件 | `bash test/posix/all.sh` | shim/启动/stderr（非 Windows composer） |
| 产物校验 | `python tools/verify-bundle.py` | dist PE/DLL |

仓库未配置 ESLint/Prettier/PHPUnit。无记载的 git hook。

### 分支策略

当前默认分支为 `master`（会话开始时 git 状态）。未在代码中强制 GitFlow。

### 编码约定（从现有 PHP 归纳）

- `declare(strict_types=1);`、namespace `Tiny\Gui`
- 类 PascalCase；方法 camelCase
- 调试只写 **STDERR**；STDOUT 只能是帧
- tpc 路径用 `bootstrap.php` 的 `require_once`，不要只依赖 Composer autoload

## 常见任务

### 加一个后端方法

**文件**: `src/backend.php` 或自建 `HandlerInterface` 实现。

```php
$s = new \Tiny\Gui\State();
$d = \Tiny\Gui\Gui::defaultDispatcher($s); // 不含 api.*
$d->on('demo.greet', function (\Tiny\Gui\Request $req): \Tiny\Gui\Response {
    return \Tiny\Gui\Response::ok('hello ' . ($req->params['name'] ?? 'world'));
});
\Tiny\Gui\Gui::serveWith($d, $s);
```

页面：`tiny.api.call('demo.greet', { name: '…' })`。

演示 API 用 `Gui::serveDemo()` / `demoDispatcher()`。

### 使用沙箱文件 API

`listDir` / `fs.*` 相对 `TYPEPHP_APP_ROOT` 或 cwd。越界返回错误 RET（`fs.exists` 越界为 false）。

### 改 tiny.js

重跑 `tools/build-launcher.sh`（会重生 `tiny_client.h`）。

### 修协议/帧

改 `Protocol.php` + `Backend.php`，补 `gui/php/test/smoke.php`。JSON 不可编码值必须变成 RET status 1，不能把 `false` 写进帧。

## 构建与发布

- `build/app.exe`：tpc 输出；`dist` 中改名为 `php.exe`，避免与入口 `<App>.exe`（shim）撞名。
- `tgui build` 会对入口做 PE 图标嵌入与 Subsystem console→GUI（根 README）。

## 已知限制（根 README / 代码）

- php-nano 无 socket；免 shim 且小巧的组合不存在。
- `StoreHandler` 不跨进程持久化。
- POSIX composer 脚本已从 `composer.json` 移除，套件仍在 `test/posix/`。
