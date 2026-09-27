---
title: 十分钟跑起来
description: 三个平台各自的构建前置、第一条命令、日志开关，以及跑不起来时先看哪三件事
---

# 十分钟跑起来

按平台选一条路走完整套。三条路的**验收现场**都在 [验证矩阵](/guide/verification.html) 里，
每条结论都指向 `evidence/` 的日志或截图——所以如果你在自己机器上跑不出同样的帧数，那是要报的 bug，不是"文档理想化"。

## 0. 公共前置

| 依赖 | 为什么需要 | 校验 |
|---|---|---|
| PHP ≥ 8.1 | 开发方向直接用它跑后端（`bin/run-backend.php` + `Tiny\Gui`） | `php -v` |
| bash | `gui/bin/tgui` 是 bash 脚本，POSIX 套件也是 | `bash --version` |
| Python 3 | 发布前校验（`tools/verify-bundle*.py`）与 POSIX 套件的 oracle | `python3 -V` |
| Composer（可选） | 仓库是 `type: project` 模板，不是库；`composer test` 只是 `php gui/php/test/smoke.php` 的别名 | `composer test` |

框架本身**没有任何 Composer 运行时依赖**（`require` 只有 `php: >=8.1`），autoload 是
`Tiny\Gui\` → `gui/php/src/Tiny/Gui/`。

## 1. Windows（WebView2 + AOT 后端）

```bat
tools\build-all.bat            :: 编 shim + PHP 后端 → build\
```

```bash
cd demo
bash ../gui/bin/tgui dev       # 起窗口；改 src/** 或框架 PHP → 整窗 bounce 重启后端
```

打包方向：

```bash
cd demo
bash ../gui/bin/tgui build     # → demo/dist/<App>.exe + launcher.exe + php.exe + 8 个 DLL
bash ../gui/bin/tgui publish   # → dist.zip
```

需要 WebView2 运行时（本机实测 148.0.3967.54）。`tgui build` 还会把图标刻进 PE 资源、
把 PE `Subsystem` 从 console 改成 GUI——少了这一步，双击入口会一直挂一个黑框（踩坑 #10）。

## 2. macOS（WKWebView + 系统 PHP，Apple Silicon 实机）

```bash
bash tools/build-macos.sh              # 编 shim + launcher-macos（会拉 webview 头）
cd demo && bash ../gui/bin/tgui dev    # 开发方向：launcher-macos --typephp
bash tools/build-macos.sh --run        # 打包方向一条命令：系统 PHP 后端 + 真窗口
cd demo && bash ../gui/bin/tgui build  # → demo/dist/TypePHP-Demo.app（末尾自动跑 verify-bundle-macos.py）
```

mac 打包**不需要 tpc**：后端是系统 PHP 的 shebang 脚本，所以目标机 `PATH` 里必须有 `php`。
曾经外部卷（下载卷 / U 盘）上双击会永久挂起（#21），根因是 TCC 卷授权而不是 socket，
现在 shim 会把端点搬到 `$TMPDIR` 并在日志里写明原因——见 [三平台差异](/guide/platforms.html)。

## 3. Linux（WebKitGTK + 系统 PHP）

```bash
bash tools/build-linux.sh              # 缺包会点名缺哪个；appindicator3 是硬依赖（#23）
cd demo
bash ../gui/bin/tgui dev               # 需要 X display（真桌面或 Xvfb）
bash ../gui/bin/tgui build             # → demo/dist/<App>/ 目录式 bundle
```

Linux 有两个和另两个平台**方向相反**的地方，先记住能省一小时：

1. `launcher-linux` 保持 pristine（**不**移植 `--typephp`），dev 时由 shim 站 AF_UNIX **服务端**、
   原版 launcher 作**客户端**连进来；
2. 没有可用的 AOT/nano 自包含后端（上游三道卡点，见 [验证矩阵](/guide/verification.html) 与
   `docs/upstream-issues/`），打包产物靠系统 PHP。

无 X display 时直跑入口的表现是：**0 秒返回 RC=1**，shim 日志写
`launcher exited (status 768) before connecting`，不留 socket 也不留子进程（这是 #25 修好之后的回归断言）。

## 4. 日志开关与端点位置

只有一条环境变量是排查用的必需品：

```bash
TYPEPHP_SHELL_LOG=/tmp/shim.log bash ../gui/bin/tgui dev
```

shim 日志里必看四行：

```
[shell] transport=unix-socket pipe=/tmp/…-12345.sock app_kind=stock cwd=/…
[shell] endpoint moved off the app dir (app dir is not on the boot volume): <from> -> <to>   # 仅 mac 打包 + 非启动卷
[shell] launcher connected
[shell] L->P: CALL …   /   [shell] P->L: RET …
```

`app_kind` 是 shim 读后端二进制首字节分类的结果（`aot` / `stock` / `unknown`），它经
`TYPEPHP_APP_KIND` 注入后端，demo 页第 ⑤ 格显示的就是它——所以"未经 AOT"是**后端自报**，不是文案。

## 5. 跑不通时按这三步查

1. **先确认不是没编译**：`bash tools/build-<os>.sh`（mac 是 `build-macos.sh`）产物在 `build/`；
   `gui/bin/tgui status` 会打印它解析到的 launcher / shim / app 路径。
2. **再看端点**：日志里 `transport=` 那行的 `pipe=` 是不是你以为的那个位置（Windows 是
   `\\.\pipe\tinyjs-typephp-<pid>`，POSIX 是 `.sock`；打包方向才是 exe 同目录的 `app.sock`）。
3. **最后看帧是否配平**：`CALL` 与 `RET` 数量不等 → 后端抛异常或方法没注册（`Dispatcher` 会回
   `status=1`）；一条 `CALL` 都没有 → 页面侧脚本或 `tiny.js` 注入问题，跟 PHP 无关。

## 6. 验证与文档自身的构建

```bash
php gui/php/test/smoke.php          # 协议编解码的离线冒烟，不需要窗口
bash test/posix/all.sh              # POSIX 套件（tier 1–4 + 打包入口）
```

本文档站：

```bash
cd docs && npm install && npm run dev     # http://localhost:8080
cd docs && npm run build                  # → docs/.vuepress/dist/
```

`npm run dev` / `npm run build` 都会先跑 `docs/sync-external.sh`，把 `README.md`、`gui/README.md`、
`test/posix/README.md`、`test/win/README.md` 复制成 `docs/reference/*.md`（已 gitignore）。
所以**要改那些内容请改仓库里的原件**，在 `docs/reference/` 下手改会被下一次构建覆盖。
