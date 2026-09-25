# 方案 B 落地报告（aot-compiler 实现 tinyjsapp 后端）

> 前置调研见 `tinyjsapp-aot-compiler-feasibility.md` 与 `tinyjsapp-nano-ipc-addendum.md`。
> 本篇记录"先实测、通过则落地"的结论与产物。

## 一、实测结论

### 1. nano 模式在 Windows v0.9.3 上无法构建（源码级根因）

`--nano` 在 Windows 与 Linux/macOS 走的是**完全不同的路径**：

| 平台 | `isNanoMode()` | 实际模式 | 链接目标 |
|---|---|---|---|
| 非 Windows | `true` | 真 nano（freestanding php-nano 运行时） | COMPOSER_SOURCES，编译 php-nano 源码 |
| Windows | `false` | bin + nano 策略 | `WINDOWS_DLL`，链接完整 PHP/PHPX 导入库 |

分流代码：`src/Translator.php:499-505`
```php
if ($this->climate->arguments->defined('nano')) {
    $this->nanoPolicyMode = true;
    if (NanoBuildBackend::composesRuntimeSources(PHP_OS_FAMILY)) {  // Windows 返回 false
        $this->nanoMode = true;          // ← Windows 上不进入
        $this->noLiteralStrings = true;
    }
}
```
`NanoBuildBackend::forHost('Windows') = WINDOWS_DLL`（`src/Build/NanoBuildBackend.php:14-17`），`composesRuntimeSources` 对非 Windows 才返回 true。

**由此触发的代码生成缺陷**（导致编译失败 `C3861: php_main 未找到`）：

- RINIT 生成逻辑 `src/Translator.php:1865-1881`：当 `!isNanoMode()`（Windows 即此情形）时，在扩展翻译单元直接生成对 C++ `php_main()` 的调用；但仅当 `isNanoPolicyMode()`（Windows `--nano` 满足，`CompilerBase.php:907` 返回 `nanoMode||nanoPolicyMode`）才走这条分支。
- 然而该扩展翻译单元（`extension-<target>.cc`）**未包含声明 `php_main` 的 func 声明头**。对比两份实际生成文件 `build/extension-test_line.cc` 与 `build/extension-test_line_bin.cc`，includes 完全一致（均无 `php_*_func_decl.h`），bin 版因通过 **ZendVM 解释执行 `main()`**（`src/Translator.php:1882+`）绕过了该引用而通过；nano 版直接引用 C++ `php_main` 故报错。
- 真 nano 模式靠独立的 `nano-entry-<target>.cc`（`src/Translator.php:1194-1208`）自带 `#include <php_<t>_func_decl.h>` 补齐声明，逻辑自洽。

> 结论：**Windows 上 `--nano` 当前是一个未完成的代码生成路径**（缺声明头包含）。即便修好，也只得到"bin + `zend_disable_functions` 禁掉 exec/shell/proc_open"的产物，**不会变小**——php-nano 的 freestanding 小巧运行时仅 "outside Windows"。tinyjsapp 那种 ~6MB 单文件在 Windows v0.9.3 上拿不到。

### 2. stdio 机制在 Windows 实测通过 ✅（用 bin 模式）

既然 nano 不可用，改用 `bin` 模式（链接完整 PHP 运行时）验证方案 B 的核心前提：**编译出的 PHP 子进程能否经 stdin/stdout 与 launcher 走 `CALL/RET` 帧**。

- 编译：`tpc.exe backend.php -o backend.exe`（`bin` 模式，MSVC/cl，vcvars 提供 INCLUDE/LIB）→ `backend.exe` **105,984 字节**。
- 实测（bash 直管道，规避 PowerShell 重定向 BOM）：输入 8 帧（含 `GOT` 异步通知与一处错误方法），输出全部正确：

  ```
  READY
  RET 1 {"ok":true,"result":"8.5.11"}        # api.version
  RET 2 {"ok":true,"result":true}            # store.set
  RET 3 {"ok":true,"result":"tinyjsapp"}      # store.get
  RET 4 {"ok":true,"result":6}               # api.sum
  RET 5 {"ok":true,"result":{"hello":"world"}} # api.echo
  RET 6 {"ok":true,"result":{"pushed":...}}   # app.push
  RET 7 {"ok":true,"result":{"name":"tinyjsapp"}} # store.all
  RET 8 {"ok":false,"error":"unknown api: nope"}   # 错误路径
  # stderr: NOTE: GOT 99 {"event":"ping"}     # 异步通知被忽略
  ```

**方案 B 的 child 侧已端到端验证可行。**

## 二、落地产物（`D:/git/php/typephp-gui/planb/`）

| 文件 | 作用 |
|---|---|
| `backend.php` | PHP 后端：讲 `CALL/RET` 帧协议（launcher→backend 请求 / backend→launcher 响应 / `GOT` 异步通知），含 `store.*` / `fetch` / `app.push` / `api.*` 分发，启动发 `READY` 握手。必须是 `function main()`（nano/bin 均要求主逻辑在函数内）。 |
| `project.yml` | tpc `bin` 模式工程配置。 |
| `build.bat` | 加载 vcvars64 + 设 `PHP_HOME/PHPX_HOME/PATH` 后调用 `tpc.exe` 编译（因 Bash 工具禁止从 bash 调 cmd，编译经 PowerShell 工具触发该 bat）。 |
| `launcher_bridge.cpp` | 可直接并入 `launcher-win.cc` 的参考实现：用 `CreateProcess` 拉起 `backend.exe` 并重定向子进程 stdin/stdout 到匿名管道；`bridgeWrite()` 替代原 `pipe_write_line()`；读线程按 `\n` 切帧，把 `RET` 喂给现有响应回调，`READY` 触发初始握手。 |
| `test_frames.txt` / `test_frames_clean.txt` | 协议测试帧（clean 版无 BOM，用于 bash 直管道实测）。 |

## 三、规模现状（必须告知）

- **Windows 上方案 B 的 PHP 子进程不是 nano 小巧二进制**，而是 `bin` 模式 exe + PHP 运行时 DLL（`php8ts.dll`/`gmp`/`mpfr`/`libmpdec` 等，随 tpc 发行包提供）。真实分发体积 ≈ exe(≈100KB) + PHP DLLs（约 15–25MB），与 tinyjsapp 原 ~6MB 单文件有差距，但**单进程自包含、无需外部 PHP 安装**。
- 若要坚持"小巧"，只能等 aot-compiler 在 Windows 上把 php-nano 的 freestanding 运行时链路打通，或改为在 Linux/macOS 上用真 nano 模式构建（那边 `--nano` 才是 freestanding 小巧二进制）。

## 四、aot-compiler nano bug 修复建议（可选，未改动仓库）

在 `src/Translator.php` 的 RINIT 生成（`isNanoPolicyMode()` 分支，约 1870-1881 行）发出 `php_main()` 调用前，确保扩展翻译单元包含入口函数的声明头。参照真 nano 模式做法（`src/Translator.php:1201-1203`），补一行 include：

```php
// 在 isNanoPolicyMode() 分支内、生成 $entryCall 之前
$entryHeader = $this->declarationHeaderFiles[$entryFunction->sourceFile]
    ?? 'php_' . $this->targetName . '_func_decl.h';
$code .= '#include <' . $entryHeader . '>' . PHP_EOL;
```

修复后 Windows `--nano` 应能构建（仍是非小巧的 bin+策略产物）。需要我直接改 `D:/git/php/aot-compiler` 验证可告知。

## 五、下一步建议

1. **继续 Windows bin 模式路线**：把 `launcher_bridge.cpp` 并入 `launcher-win.cc`，打通 webview ↔ backend.exe 的 stdio 桥接，做真实窗口联调。
2. 或评估**在 Linux/macOS 用真 nano 模式**构建后端，拿回小巧体积（需确认目标部署平台）。
3. 若选 (1)，前端 HTML/JS 仍走 tinyjsapp 现有 `runtime/tiny.js` + webview，仅替换 JS 后端为编译后的 `backend.exe`。

---

## 六、复测（session 8）：nano 修复后能否走"小巧路线"？—— 不能

前文 §一.1 判断"即便修好也非小巧"，现用修复分支上的源码 tpc 实测确认（细节见
`../aot-compiler-nano-fix.md` 末节）：nano 产物与 bin 产物**依赖完全相同**（`php8ts.dll`/
`phpx.dll`/`libmpdec*`，≈15.5MB），体积仅小 1.5%，且 teardown 必定 SIGSEGV（139）。
→ **Windows 上 nano 路线作废**，`bin` 仍是唯一可用的 Windows 后端。

### ⚠️ 更正：shim 是**跨平台必需**，不是 Windows 专有（上一版此处写错）
先前据此推测"Linux/macOS 上 PHP 可服务 unix socket，故不需要 shim"——**错**。用 `swoole/php-nano`
包内权威文档与编译器源码否掉：

- `vendor/swoole/php-nano/SUPPORTED.md`：
  "PHP Nano exposes local filesystem access through its **file-only** PHP stream layer …
   It does not expose network, process, shell, socket, remote-stream, or dynamic-loader APIs.
   **Socket capability remains absent even on POSIX hosts.**"
  另有："**Windows deliberately uses the complete PHP/PHPX DLL runtime instead of php-nano.**"
- `vendor/swoole/php-nano/REMOVED.md`：移除 "socket transports, remote and user-defined stream
  wrappers, sockets, DNS, processes, shell execution, signals, or dynamic library loading"。
- `src/CompilerBase.php:256-…` `NANO_UNSUPPORTED_FUNCTIONS` 含 `stream_socket_server` /
  `stream_socket_client` / `stream_select` / `fsockopen` / `proc_open` / `exec` / **`getenv`** / `gethostname`；
  使用点 `:951` 是 **`fatalError("Function ... is not supported in nano mode")`** → 真 nano 下**编译期就失败**。
- `src/CompilerBase.php` 明确注释：**Windows Nano 只应用 common policy**（exec 家族），
  php-nano 的更小宿主面只对 **Unix/WASI** 生效（`if (!$this->isNanoMode()) return;`）。
  这解释了为何我们的 `backend.php`（用了 `getenv`/`gethostname`）在 Windows nano **能编过**，
  在真 nano 下**编不过**。
- `src/Build/NativeSourceProjectBuilder.php:28-31`：native 目标 + Windows 直接抛
  "php-nano does not target Windows; use TypePHP --nano with the full PHP/PHPX DLL runtime"。

**修正后的能力矩阵：**

| | Windows | Linux/macOS |
|---|---|---|
| `--nano` 产物 | nano-policy（bin + 策略），链接完整 PHP/PHPX DLL | **真 freestanding**（无 libphp，小巧） |
| socket API | 有（bin 完整 PHP），但**无 `pipe://` transport** | **编译期致命错误**（nano 全部 socket 函数被移除） |
| 服务 launcher 连接 | ✗ → 需 shim | ✗ → **同样需 shim** |
| 只有 bin 模式 | — | bin 有 `unix://` transport，可行，但回到 libphp 体积 |

→ **shim 在三种情形下都省不掉**：Windows 缺 transport；POSIX 真 nano 无 socket API；
   POSIX bin 虽能服务 socket 却已不"小巧"。**"小而免 shim"的组合不存在。**

### Linux/macOS 的真实收益（不是免 shim，而是体积）
`shim(≈100KB C++) + 真 nano PHP(freestanding, 无 libphp)` 的总量远小于
Windows 的 `shim + bin PHP + 15.5MB PHP DLL`。要拿到它需要：① 写 AF_UNIX 版 shim（把
`CreateNamedPipeW` 换成 `socket(AF_UNIX)`）；② `backend.php` 去 `getenv`/`gethostname`
（仅 `sysinfo` 两行，见 `planb/backend.php:262,266`）才能过真 nano 的编译检查。

