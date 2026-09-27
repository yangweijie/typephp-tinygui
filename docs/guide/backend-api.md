# 后端 API 与扩展

这一页讲"我要给页面加一个 `tiny.xxx` 方法，该改哪儿"，以及框架自带哪些方法。

帧格式本身在[协议页](/guide/protocol.html)，这里只讲 PHP 侧的编程模型。

## 1. 入口在哪

```
bin/run-backend.php          ← shim 直接 execv 的文件（无 argv，所以必须自带 shebang）
  └─ require src/backend.php ← 真正的入口，只做一件事：Gui::serveDemo()
       └─ gui/php/src/Tiny/Gui/bootstrap.php  ← PSR-4 之前用的显式 require 链
```

`src/backend.php` 全文核心就一行：

```php
require __DIR__ . '/../gui/php/src/Tiny/Gui/bootstrap.php';
Gui::serveDemo();
```

`Gui::` 的三个门面（`gui/php/src/Tiny/Gui/Gui.php`）：

| 门面 | 注册什么 | 什么时候用 |
|---|---|---|
| `Gui::serve()` | Core + Win + Menu + Store | 正式 app。**不带 `api.*`** |
| `Gui::serveDemo()` | 上面 + `DemoApiHandler` | 本仓库的 demo 页 |
| `Gui::serveWith($d, $s)` | 你自己拼好的 Dispatcher | 要加自己的方法时 |

`defaultDispatcher()` / `demoDispatcher()` 都接受第二个参数 `?AppRoot`，传 `null` 时走 `AppRoot::fromEnv()`。

::: warning `demo/src/backend.php` 是 0 字节，而且这是对的
真实后端入口只有仓库根的 `src/backend.php`。`gui/bin/tgui` 的 dev/watch 逻辑监听的是
`$PWD/src`（`gui/bin/tgui:241-242`），而 Linux 真窗口验收是以 `cd demo && tgui dev`
跑的（`test/posix/linux-tgui-window.sh:118,147`），所以 `demo/src/` 必须存在，
`demo/src/backend.php` 就是那个"改一下触发热重启"的**触碰靶子**
（`test/posix/linux-tgui-window.sh:73` 的报错原文即 "the touch target"）。
Windows 侧的驱动对此写得更直白：`test/win/dev-bounce.sh:250` —
"demo/src/backend.php is a 0-byte stub; the real backend is at repo src/"。
看到它是空的不要慌，也不要删。
:::

## 2. 三种注册方式

`Dispatcher`（`gui/php/src/Tiny/Gui/Dispatcher.php`）里只有两张表：`$exact` 和 `$prefix`，
**都是首匹配即返回**；处理器返回 `null` 就继续往下落，所以"只旁听不回答"的观察者是合法的。

```php
use Tiny\Gui\{Gui, State, Dispatcher, Request, Response};

$s = new State();
$d = Gui::defaultDispatcher($s);          // 先拿到 24 个内置方法

// ① 一个方法一个闭包
$d->on('demo.greet', fn(Request $r) => Response::ok('hello ' . $r->param('name', 'world')));

// ② 一组前缀（注意：exact 表先于 prefix 表，所以 ① 能盖住 ②）
$d->onPrefix('myapp.', fn(Request $r) => Response::ok(['m' => $r->method]));

// ③ 一个 handler 类，自己声明它负责哪些方法
$d->add(new MyHandler());

Gui::serveWith($d, $s);
```

`HandlerInterface` 就两个方法：

```php
public function methods(): array;                 // 精确方法名列表
public function handle(Request $req): ?Response;  // null = 让给别人
```

::: tip 两处源码注释是旧的，别照着抄
- `HandlerInterface.php` 的 docblock 写 "call `Dispatcher::addHandler()`" —— 实际方法名是 `add()`。
- `Handlers/DemoApiHandler.php::methods()` 里写 "Any 'app.\*' method is also accepted via the
  prefix registration in bootstrap.php" —— `bootstrap.php` 里**没有**任何 `onPrefix()` 调用。
  实测：反射读出 `demoDispatcher()` 的 prefix 表是**空的**，exact 表 27 条。
:::

## 3. 内置方法全表

下面 27 个是 `Gui::demoDispatcher()` 真正注册的名字（反射读出来的，不是文档抄来的）：
Core/Win/Menu/Store 四个内置 handler 共 21 个，`DemoApiHandler` 6 个。

### CoreHandler（`Handlers/CoreHandler.php`）

| 方法 | 入参 | 返回 | 备注 |
|---|---|---|---|
| `ping` | — | `'pong'` | 存活探针 |
| `client.hello` | — | `true` | 页面 bootstrap 握手 |
| `log` | `msg` | `true` | 写到 **stderr**，前缀 `[php-backend] `，payload 走 `Protocol::jenc` |
| `sysinfo` | — | 见下 | |
| `listDir` / `fs.list` | `path`（默认 `.`） | `{path, entries:[{name,isDir}]}` | 目录优先、名字排序，**最多 200 条** |
| `theme.get` | — | `State::$theme` 或 `null` | 拉缓存，见 §5 |
| `system.locale` | — | `State::$locale` 或 `null` | |
| `win.getState` | — | `State::$winState` 或 `null` | |
| `app.root` | — | 沙箱根绝对路径 | |
| `fs.readText` | `path` | 文件内容字符串 | 越界/不是文件 → status 1 |
| `fs.writeText` | `path`, `content` | `true` | 父目录必须已存在且在沙箱内 |
| `fs.exists` | `path` | `bool` | 越界**不报错**，只返回 `false` |
| `fs.stat` | `path` | `{path,isDir,isFile,size,mtime}` | |

`sysinfo()` 的返回字段（逐个对得上源码）：

```json
{ "runtime": "PHP 8.3.x", "host": "uname -n", "cpu": "arm64", "pid": 1234,
  "cwd": "...", "root": "...", "home": "...", "os": "Darwin",
  "backend": "aot-compiler (tpc) native" }
```

`backend` 这一项是**老实的**：值来自 shim 分类 app 二进制头两字节后注入的
`TYPEPHP_APP_KIND`，可能是 `aot-compiler (tpc) native` / `stock PHP CLI (no AOT)` /
`unknown (shim could not classify…)` / `unknown (TYPEPHP_APP_KIND not set)`。
在 stock PHP 下谎报 "tpc-AOT" 曾是真 bug，别把它改回硬编码。

### WinHandler / MenuHandler / StoreHandler / DemoApiHandler

| 方法 | 入参 | 发给 launcher 的帧（在 RET 之前） |
|---|---|---|
| `win.setTitle` | `title` | `TITLE <title>`（标题里的 `\r\n` 被换成空格） |
| `win.setSize` | `width`, `height` | `SIZE <w> <h>`（默认 960×640） |
| `quit` | — | `QUIT` |
| `menu.set` | `menus`（数组） | `MENUBEGIN … MENU/ITEM/SEP/SUB/SUBEND/ROLEITEM/MENUROLE … MENUEND` |
| `store.get` | `key` | — |
| `store.set` | `key`, `value` | — |
| `store.all` | — | — |
| `api.version` | — | — |
| `api.sum` | 任意个数字参数 | — |
| `api.sha256` | `text` | — |
| `api.fib` | `n`（默认 30） | — |
| `api.now` | — | — |
| `api.echo` | 任意 | — |

`api.*` 的返回值：`api.version` → `{php, backend}`（`backend` 是**原始**的
`TYPEPHP_APP_KIND` 字符串）；`api.now` → `{iso, epoch, caller}`，其中
`caller` = `Request::$callerWin`；`api.echo` 原样返回 `params`。

`store.*` 是**纯内存**数组，活到后端进程结束为止；`MenuHandler` 的 `role` 白名单是
`standard undo redo cut copy paste selectAll`，不在表里的 `role` 会被丢掉。

## 4. Response：结果和帧是两件事

```php
Response::ok($result = true, array $frames = []);   // status 0
Response::error($message,   array $frames = []);   // status 1，message 就是 RET 里的 JSON
```

**handler 里只有 `win.*` / `quit` / `menu.set` 会带帧**；帧一定排在 RET 前面（`Backend::run()` 逐条
`fflush`）。这条顺序是硬的：launcher 收到 RET 就认为这一轮结束。
（唯一的例外是 §7 的 `DLG`：那条路径由 `Backend` 自己发帧，压根不产生 RET。）

抛异常不会被吞：`Backend` 用 `safeRet()` 三段兜底，最终一定会吐出一条 status 1 的 RET，
页面那个 Promise 是 reject 而不是永久挂起。所以处理器里 `throw` 是安全的偷懒写法，
但错误信息会进 launcher 的 console，不会进 `[php-backend]` 日志。

## 5. State：launcher 先推、页面后拉

`theme.get` / `system.locale` / `win.getState` 读的是 `State` 里的缓存，不是实时问 launcher。
为什么要缓存：launcher 在页面注册监听器**之前**就把 WINSTATE / SYS / SYSLOCALE 推过来了，
错过就没了（这套行为和 tinyjsapp 的 `bridge.js` 一致）。

`State::apply()` 认的三个事件名：`theme`、`locale`、`window-state`。
所以页面打开时立刻 `await tiny.win.getState()` 可能拿到 `null` —— 首次 push 还没到。

## 6. AppRoot：页面能碰哪些文件

`AppRoot`（`AppRoot.php`）是 `fs.*` 和 `listDir` 的沙箱：

- 根 = `TYPEPHP_APP_ROOT`，没有就用 `getcwd()`；两者都不可解析时**直接抛**，不会静默降级。
- 每个用户传进来的路径都 `realpath()`，然后必须 **等于根** 或 **严格在根之下**。
- 路径不存在时：`resolve($p, true)` 返回 `null`；`resolve($p, false)`（写操作用）会向上找
  最近的存在祖先，要求那个祖先在沙箱内，并且剩余段里不许出现 `.` 或 `..`。
- Windows 下 `contains()` 对整个路径做 `strtolower()` 再比（盘符大小写不敏感）。
- `\0` 会被剥掉。

越界的行为按方法不同：读/写/统计返回 status 1，`fs.exists` 只返回 `false`。**这是有意的**
—— `exists` 的语义就是"能不能被解析成沙箱内路径"。

::: danger nano 下不能用 `getenv()`
`getenv()` 在 tpc 的 `NANO_UNSUPPORTED_FUNCTIONS` 里，nano 编译出来的后端调它会直接编译失败。
读环境一律走 `$_SERVER['X'] ?? $_ENV['X']`（CLI 的 `variables_order` 会把环境放进 `$_SERVER`）。
`AppRoot::fromEnv()` 和 `CoreHandler::backend_kind()` 都是这么写的，照抄这个模式。
:::

## 7. 页面能调 ≠ 后端会答

`gui/runtime/tiny.js` 里 `call('<字面量>')` 一共出现 **141 个**不同方法名（动态拼名字的调用不在这个
统计里）。后端真正会回的只有 **19 个**：

| 谁来回 | 数量 | 怎么回的 |
|---|---|---|
| Dispatcher（§3 那 27 个里有 12 个被 tiny.js 调到） | 12 | 正常 `RET` |
| `Protocol::dialogFrame()` 短路 | 7 | 只发 `DLG` 帧、**不发 RET**，页面那个 Promise 由 launcher 落地 OS 面板后解决 |
| 没人回 | **122** | `Dispatcher::dispatch()` 抛 `unknown method: X` → status 1 |

短路发生在 `Backend::processLine()` **进 Dispatcher 之前**（`Backend.php:46-50`），认的 7 个名字是
`dialog.openFile` / `openFiles` / `pickFolder` / `saveFile` / `alert` / `confirm` / `prompt`
（`Protocol.php:96-125`）。所以 `tiny.dialog.*` 开箱可用，不用你注册；其余 122 个
（`fetch`、`win.open`、`system.info`、`tray.set`、`hotkey.register`、`clip.*`、`macos.*` ……）
现在全都是 `unknown method`。

**launcher 不会替你回答那 122 个。** 它只是转发：
`gui/host/src/launcher-win.cc:4740` / `:7642` 把页面的 `__invoke` payload 原封不动写成
`CALL <winid>:<seq> [payload, origin]`；`launcher-macos.cc:5992-5996` 的注释说的是同一件事。
两个 launcher 里都 grep 不到按方法名分支的原生派发（`method == "…"` 零命中）——
唯一由 launcher 自答的就是上面那 7 个原生对话框。

那 122 个在 upstream tinyjsapp 里是谁实现的？是嵌在 shim 里的 **JS 后端运行时**，不是 launcher。
后端换成 PHP 之后，只有这 19 个落了地，其余是**已知产品缺口**，其中两组已经正式记录：

- `tray.set` / `hotkey.register`：Phase 23 真桌面验收时确认为"有意未修"，
  `Protocol::decode` 连 `HOTKEY` 分支都还是 `type => ignore`（`TRAYCLICK` 是有解码的，在 `Protocol.php:225`）。
- `menu.update` / `menu.get`：`menu.set` 是全量重发声明块，没有增量更新。

要给页面加能力，正确姿势就是 §2 的三种注册之一 —— 加完之后 `tiny.xxx()` 立刻就能用，
`tiny.js` 不需要改（`tiny.api.call('xxx', …)` 是通用出口）。

## 8. 怎么验

不开窗口的两层：

```bash
php gui/php/test/smoke.php          # 24 条断言，直接喂帧进 Backend::processLine()
composer test                        # 同上（composer.json 的 scripts.test）
```

`smoke.php` 里已经覆盖到 `store.set` 缺 key 的报错、`win.setTitle` 的帧序、以及
"空 app 不该有 `api.fib`"（即 `defaultDispatcher` 与 `demoDispatcher` 的差集）。
**加新 handler 就在这里补一条断言**，这是全仓库最快的反馈回路（<1s，无依赖）。

往上还有 mock 链路和真窗口两层，见[验证矩阵](/guide/verification.html)。
