# Dispatcher

`Tiny\Gui\Dispatcher` 把 `Request::$method` 交给第一个给出 `Response` 的注册项。

## 什么是 Dispatcher？

三种注册，均为先匹配先胜，handler 返回 `null` 则继续：

- `add(HandlerInterface)`：把 `methods()` 中每个名字绑到 `handle`
- `on($method, callable)`：精确方法
- `onPrefix($prefix, callable)`：前缀（如 `app.`）

无一命中：抛 `RuntimeException('unknown method: …')`，由 `Backend` 变成 RET status 1。

## 代码位置

| 方面 | 位置 |
|---|---|
| 类 | `gui/php/src/Tiny/Gui/Dispatcher.php` |
| 门面 | `gui/php/src/Tiny/Gui/Gui.php` |
| 接口 | `HandlerInterface.php` |

## 默认集 vs 演示集

- `defaultDispatcher` / `serve()`：Core、Win、Menu、Store
- `demoDispatcher` / `serveDemo()`：再加上 `DemoApiHandler`
- `src/backend.php` 调用 `serveDemo()`

后 `add` 的精确方法会覆盖 `exact` 表中同名项（`Dispatcher::add` 对 `$this->exact[$m]` 赋值）。

## 关系

| 关联 | 描述 |
|---|---|
| Request / Response | 入参与返回 |
| Backend | 唯一调用 `dispatch` 的泵 |
