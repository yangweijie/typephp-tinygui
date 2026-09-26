# AppRoot 沙箱

`Tiny\Gui\AppRoot` 把页面可达的文件系统限制在一个根目录内，供 `listDir` / `fs.*` 使用。

## 什么是 AppRoot？

默认根：`TYPEPHP_APP_ROOT`，否则 `getcwd()`。用户传入路径经 `realpath`（或对未存在路径走最近存在祖先）后，必须等于根或位于 `根 + DIRECTORY_SEPARATOR` 之下。Windows 比较时忽略大小写。

**关键特征**:
- `\0` 被剥离
- `..` 走出根则 `resolve` 返回 null
- 写文件：`mustExist=false`；父目录必须已存在且仍在沙箱内

## 代码位置

| 方面 | 位置 |
|---|---|
| 类型 | `gui/php/src/Tiny/Gui/AppRoot.php` |
| 使用 | `Handlers/CoreHandler.php` |
| 注入 | `Gui::defaultDispatcher($s, ?AppRoot $root = null)` |
| 测试 | `gui/php/test/smoke.php`（临时目录 + `..` 拒绝） |

## 不变量

1. 越界 `listDir`/`fs.readText`/`fs.stat`/`fs.writeText` → 错误 RET（文案含 outside sandbox）。
2. `fs.exists` 对越界或缺失返回 `false`，不是抛错。
3. 空应用与演示应用都带 CoreHandler，因此 **fs API 在默认集中**；DemoApi 才是可选的。

## 关系

| 关联 | 描述 |
|---|---|
| CoreHandler | 唯一调用 `resolve` 的内置 handler |
| 帧协议 | 失败表现为 RET status 1 |
