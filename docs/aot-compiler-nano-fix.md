# aot-compiler Windows `--nano` 编译修复（PR 就绪）

## 结论
`--nano` 在 Windows 上此前**无法编译**（MSVC `C3861: php_main: identifier not found`）。根因是代码生成缺口，已修复并提交到分支 `fix/windows-nano-policy-entry-header`（commit `eb2f551e`），改动仅 1 文件 +14 行。

## 根因（源码级）
- `--nano` 在 Windows 走 `nanoPolicyMode=true` + `nanoMode=false`（即 bin + 策略，`WINDOWS_DLL` 后端），分流点 `src/Translator.php:499-505`（`NanoBuildBackend::composesRuntimeSources('Windows')` 为 false）。
- RINIT 在 `src/Translator.php:1865-1881` 对 Windows `--nano` **直接生成 C++ 调用 `php_main()`**（不走 ZendVM 解释 `main()`），但扩展翻译单元（TU）的 includes 由 `genExtensionIncludeHeaderFiles()` 组装，**只收 stub 文件与 attribute-factory owner 的声明头**，入口 `main()` 的源文件两者都不是 → 其声明头 `php_*`_decl.h`（含 `extern void php_main();`）从未被包含 → 未声明 → C3861。
- 真 Nano 模式（非 Windows）走独立 `nano-entry-*.cc`（`1194-1208`，自带 func_decl.h）封装 `php_main()`，逻辑自洽；Windows 这条路径从未打通。

## 修复
在 `genExtensionIncludeHeaderFiles()` 内、nano-policy 模式且存在 `main()` 时，把入口函数的声明头加入扩展 TU 的 includes：

```php
if ($this->isNanoPolicyMode() && $this->hasFunction(self::ENTRY_FUNCTION)) {
    $entryHeader = $this->declarationHeaderFiles[
        $this->getFunction(self::ENTRY_FUNCTION)->sourceFile
    ] ?? null;
    if ($entryHeader !== null && !in_array($entryHeader, $declarationHeaders, true)) {
        $declarationHeaders[] = $entryHeader;
    }
}
```

门控确保：非 nano 构建（无 `--nano`）完全不受影响；真 Nano（非 Windows）仅多 include 一个纯前向声明头，无副作用。

## 验证
从源码编译（`php bin/tpc.php nano_min.php --nano -o nano_min_src.exe`）：
- 生成的 `extension-nano_min_src.cc` 第 12 行已含 `php_nano_min_src_nano_min_537d6b1434_decl.h`；
- 链接成功：`Build successful: nano_min_src.exe`；
- 运行输出 `nano-policy-build-ok`（入口 `php_main()` 已被正确派发）。

源码构建环境要点（Windows）：
- `cl` 经 `vcvars64.bat` 提供 INCLUDE/LIB；Bash 工具禁 cmd，故用 PowerShell 触发 build.bat。
- 设 `PHP_HOME`/`PHPX_HOME` 指向 tpc 发行包（如 `D:/git/php/tpc_v0.9.3_windows_x64`）。
- 源码编译器预检要求 `phpx\build\phpx.dll`（发行包该文件在顶层），需复制到 `phpx\build\phpx.dll`。

## 已知残留（非本次修复范围）
exe 打印预期输出后退出码 `0xC0000005`（teardown 阶段 access violation）。本次改动仅为多 include 一个纯前向声明头（不含代码），不可能是该崩溃根因——属 Windows nano-policy 路径此前从未跑通遗留的运行时 teardown 问题，建议作为**独立后续 PR** 跟踪。

## 提交 PR 步骤
仓库远端 `git@github.com:yangweijie/typephp.git`（aot-compiler 上游）。当前已在本地分支 `fix/windows-nano-policy-entry-header`：
```
git push -u origin fix/windows-nano-policy-entry-header
# 然后在 GitHub 对 yangweijie/typephp 开 PR
```
PR 标题建议：`Fix Windows --nano build: include entry declaration header in extension TU`

---

## 修复后的复测（session 8，用源码 tpc 实测）

修复分支上的**源码** tpc 编出的 nano 产物，与 bin 产物逐项对比（`planb/nanotest/`）：

| 维度 | `--nano`（Windows nano-policy） | `bin`（默认） |
|---|---|---|
| 编译 | ✅ 成功（修复生效） | ✅ 成功 |
| exe 体积（5 行最小程序） | 48,640 B | 54,272 B（nano 小 10%） |
| exe 体积（真实 `backend.php`） | 301,056 B | 305,664 B（nano 小 1.5%） |
| 运行时依赖 | `php8ts.dll` + `phpx.dll` + `libmpdec*.dll` **与 bin 完全一致** | 同左 |
| 分发总体积 | ≈15.5 MB | ≈15.5 MB |
| 运行退出码 | **139（SIGSEGV）** | 0 |
| 帧协议输出 | 3/3 帧全部正确 | 3/3 帧全部正确 |

**链接指令逐字相同**（`phpx.lib` + `php8ts.lib` + `php8embed.lib` + gmp/mpfr/libmpdec），因为
`NanoBuildBackend::forHost('Windows')` **硬编码**返回 `WINDOWS_DLL`（`src/Build/NanoBuildBackend.php:14-17`）。

### 残留崩溃已确认是 nano 路径固有缺陷（非本后端引起）
用 5 行程序 `nano_min.php`（只 `fwrite(STDOUT,"nano-min-ok\n")`）复现：
- nano 版：打印 `nano-min-ok` 后 **SIGSEGV（退出码 139）**
- bin 版：打印后 **退出码 0**
→ 与 `backend.php` 无关，属 Windows nano-policy 运行时 teardown 问题，建议独立 PR。

### 结论
Windows 上 `--nano` 现在是"**能编译但严格更差**"：体积省 1.5%，代价是 teardown 崩溃 +
`zend_disable_functions` 额外禁掉 `exec/proc_open/system`。**"小巧单文件"在 Windows 拿不到**——
`forHost` 的表里 Windows 永远不是 `COMPOSER_SOURCES`。
