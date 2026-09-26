# Shim

`shim/backend_shell.cpp`：launcher 拉起的进程往往是它，而不是 PHP。它连接宿主 IPC 端点与 PHP 后端 stdio。

## 什么是 Shim？

PHP 没有 `pipe://`，php-nano 编译期禁用 socket API。因此三种通道都需要代理：Windows 命名管道、POSIX unix socket、以及打包后 shim 自己当端点服务端。

**关键特征**:
- 非阻塞双向泵（因 `DLG` 不是一问一答）
- stderr 单独排空（匿名管道约 64KB 未读会堵死写端）
- 同一份源码 Windows + POSIX

## 代码位置

| 方面 | 位置 |
|---|---|
| 源 | `shim/backend_shell.cpp` |
| Windows 构建 | `tools/build-all.bat` → `build/backend_shell.exe` |
| 打包名 | `dist/<App>.exe`（入口）；PHP 后端叫 `php.exe` |

## 两种方向

| | dev | packaged |
|---|---|---|
| 入口 | 含 `--typephp` 的 `launcher-win.exe` | `<App>.exe` = shim |
| 谁建端点 | shim | shim |
| launcher 补丁 | 需要 `--typephp` | 不需要（stock `<html> <endpoint>`） |

细节以 `shim/backend_shell.cpp` 头部注释与根 README 为准。

## 不变量

1. 永不把 PHP stderr 并进 stdout。
2. 打包后 `app=` 不得指向 shim 自己（故后端改名 `php.exe`）。

## 关系

| 关联 | 描述 |
|---|---|
| [帧协议](./帧协议.md) | shim 转发的内容 |
| launcher | 对端进程 |
