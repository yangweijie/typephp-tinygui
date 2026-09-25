# 补充：aot-compiler `--nano` 缺 socket/网络/进程能力时的桥接方案

> 对应主报告《tinyjsapp 经 aot-compiler 实现的可行性调研》"无 socket/网络/进程能力"一条的延伸分析。
> 结论来源：aot-compiler README（`--nano` 段）+ `docs/en/MIXED_CPP_PHP.md` + tinyjsapp 原生层取证。

## 1. nano 模式的实际约束（来自 README 原文）

> Use `--nano` ... the generated program uses the statically selected Nano runtime and its
> **file-only stream layer**. Native Nano may use C11, C++17, and POSIX.1-2008, but **does not
> provide socket, DNS, network, remote streams, dynamic PHP loading, and process execution**.

要点：
- 裁掉的是 **PHP 层的 `ext-sockets` / `proc_open` / 远程 stream**，不是"C++ 没有网络能力"。
- 保留了 **file-only stream 层** → `php://stdin`、`php://stdout`（fd 0/1）大概率仍可用（待实测确认）。
- `eval` / `include` / `require` / 动态加载全部被拒。

## 2. 关键陷阱：单独加 C++ 库救不了体积小

nano 剥离的是 PHP 运行时能力。即便链一个 C++ 网络库，PHP 代码也调不到它，除非走
aot-compiler 的**混合 C++/PHP** 机制（`php_*` 函数 + `.stub.php`，文档 MySQL/OpenSSL 例子同款）。
而混合 C++/PHP 的示例均为 `type: bin`，nano 是单文件 + file-only，**基本不支持挂额外 C++ 源**。

推论：**一旦用 C++ 库给 PHP 补 socket/进程 → 必须 `bin` 模式 → 链接 `libphp` → 体积本身就大，加不加库都大。**
"小库 + nano" 是伪组合。

## 3. 真正小巧的路线：launcher 当父进程 + stdio 桥接

tinyjsapp 的 C++ launcher 本来已实现 webview + 进程创建 + 管道。让 PHP 侧完全不碰 socket/进程：

- C++ launcher 作为入口/父进程：创建 webview 窗口，`CreateProcess` / `posix_spawn` 拉起 aot-compiler 编译出的 **PHP `nano` 子进程**。
- 两者通过**子进程 stdin/stdout** 通信，把 tinyjsapp 的 `CALL <id> <json>` / `RET` 帧直接走 stdio。
- PHP 侧只 `fread(STDIN)` / `fwrite(STDOUT)`，**零 socket、零 proc_open** → 可留在 `--nano`，体积接近原生 launcher（~6MB）。

待验证：确认 nano 的 file-only stream 确实暴露 `php://stdin`/`php://stdout`（建议用一个 hello-nano 测 `file_get_contents('php://stdin')`）。

## 4. 若坚持在 PHP 侧补能力：小库短名单

| 库 | 体积 | 语言 | socket/pipe | 进程 spawn | 备注 |
|---|---|---|---|---|---|
| libuv | ~1 MB (static) | C | ✅ TCP/UDP/Unix/命名管道 | ✅ `uv_spawn` | **txiki.js（tinyjsapp 运行底座）本身就用它**；要 socket+spawn 一体，唯一选择 |
| nng (nanomsg-next-gen) | ~300 KB | C | ✅ IPC 消息模式，完美匹配 `CALL/RET` 请求-应答 | ❌（进程用 OS API） | 最贴合帧通信语义，但 spawn 另写 |
| µSockets | ~150 KB | C | ✅ TCP/Unix socket 极简抽象 | ❌ | µWebSockets 内核，最小 |
| 裸 POSIX + Win32 命名管道 | 0 | — | ✅ | ✅ | launcher 已在用 `socket()`/`CreateNamedPipe`/`CreateProcess`，零依赖 |

## 5. 推荐

1. **首选方案 3（launcher 父进程 + stdio）**：不引入 C++ 库、不脱离 nano、体积可控，直接复用 tinyjsapp 现有 C++ 原生层（MIT，可改）。
2. 仅当 PHP 侧需主动发起网络/拉起外部进程时，才考虑 `bin` 模式 + libuv 混合 glue——但那已放弃"小巧"。
