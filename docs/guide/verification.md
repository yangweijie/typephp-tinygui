# 验证矩阵

这个仓库不靠"我看着它启动了"交付。每一层验什么、在哪儿验、PASS 判据是什么、
证据落在哪个文件，这页一次说清。

## 0. 四条贯穿所有驱动器的规矩

1. **stdout 是线，stderr 是日志。** 任何验收都不看 stderr 的内容判绿，只判它有没有漏进 stdout
   （`test/posix/stderr-channel.sh` 专门用"敌意"后端 `mock_backend_noisy.py` 验这条）。
2. **重算，不复述。** 驱动器自己打印的 PASS 不算证据；`evidence/` 旁边一定有
   `test/posix/collect-*-evidence.sh`，它只读**入库的文件**重新算出 README 引用的每个数字。
3. **每轮都要有负控。** 断言必须"有牙"：把被验的那一行改回旧行为，断言必须失败。
   详见 §4。
4. ** teardown 必须归零。** 窗口关掉之后：shim 自行退出、dev socket / `app.sock` 被 unlink、
   `tasklist` 里没有残留子进程。每个真窗口驱动器都断言这一条，因为热重启的坑全在这儿。

## 1. 分层

| 层 | 验什么 | 驱动器 | 在哪儿跑 | 证据 |
|---|---|---|---|---|
| L0 | 帧协议 / 状态缓存 / 沙箱（不开进程） | `php gui/php/test/smoke.php`（24 条断言） | 任何有 PHP 的机器，<1s | 无（CI 式自检） |
| L1 | shim 的 POSIX 半：AF_UNIX、pump、fork/execv、teardown | `test/posix/run.sh`（mock 后端）、`tier2.sh`（**真 PHP 后端**）、`launch-mode.sh`（打包入口）、`stderr-channel.sh` | Linux / macOS / **Cygwin** | `evidence/kit/<host>-all.log` |
| L1.5 | 这套 fixture 自己有没有坏 | `test/posix/selftest_fixtures.py` | **任何机器，含 Windows**（不需要 AF_UNIX） | 无 |
| L2 | 宿主原语在不在 | `test/posix/host_probe.c`（`all.sh` 的第 [0] 步） | 目标机 | 同上 |
| L3 | 真 `launcher-linux` + 真 GTK/WebKit 渲染 + 真帧往返 | `test/posix/tier4-linux-window.sh` | Linux 容器（Xvfb 够） | **不入库**：写 `$WORK`（默认 `/tmp/tpgui-tier4`），数值以 README 验证表那行为准 |
| L3' | `tgui dev` 的 Linux 编排（shim 当服务端、pristine launcher 当客户端）+ 热重启 | `test/posix/linux-tgui-window.sh` | 同上 | `evidence/linux/22b-*`、`22c-*` |
| L3'' | **用户怎么跑就怎么跑**：`tgui build` 产物直开，没人编排 | `test/posix/linux-bundle-window.sh` | 同上 | `evidence/linux/22d-*` |
| L4 | 真桌面：WM reparent / 合成器 / 最小化最大化回传 / 托盘 / 全局热键 / HiDPI | `test/posix/desktop-session.sh` + `sni_host.py` | 容器里**另起**的 Openbox + picom + 自建 SNI 宿主 | `evidence/linux/23-*` |
| L5 | `tpc --nano` 能不能真的发货 | `test/posix/tier6-nano-aggregate.sh`（+ `upstream-nano-probes/`） | 容器（需 tpc + php-nano） | `evidence/linux/24-*`、`25-*` |
| L6 | 打包产物结构 | `tools/verify-bundle.py`（win）、`verify-bundle-macos.py`、`verify-bundle-linux.sh` | 各自平台 | `evidence/mac/26b-verify-bundle.txt` |
| L7 | macOS 打包方向实机启动（bug #21 的那条） | `test/posix/macos-bundle-launch.sh` | **真 mac 桌面会话** | `evidence/mac/26b-*`、`26c-macos-bundle-launch-final.txt` |
| W | Windows 热重启 + 命名管道 EOF 回收 | `test/win/dev-bounce.sh` | **真 Windows 机，Git Bash** | `evidence/win/21e-*` |
| D | demo 页"调用链"文案按平台派生 | `test/posix/demo-chain-harness.js` | 任何有 node 的机器 | `evidence/mac/26c-chain-harness.txt` |

一条命令把 L1/L2 全跑完并写成一个日志：

```bash
bash test/posix/all.sh        # → evidence/kit/<host>-all.log；退出码 0/1/2
```

`all.sh` 的步序是 `[0] host_probe → [1] run.sh → [2] tier2.sh → [3] launch-mode.sh → [4] stderr-channel.sh`。
tier 3（`--nano` 量体积）**没有脚本化**，只在容器里手工跑过，所以引用那两个多字节尺寸时必须带测量日期
——README 那行自己就写了：同一份源码重编产物尺寸不逐字节稳定。

## 2. 为什么有两套 mock 客户端

`mock_launcher.py` 和 `mock_launcher.c` 干的是同一件事（连端点、读 `READY`、
把 NOTIFICATION 和 CALL 交错发过去、要求每条都有 `RET <id> 0 …`）。为什么要再写一个 C 版：
**Cygwin 下 CPython 的 AF_UNIX 和本机原生 AF_UNIX 不在一个平面上** —— C 服务端 + Python 客户端
`accept()` 直接 `ECONNABORTED(113)`，而 C+C 正常。这是实测出来的，不是猜的。

::: warning `mock_launcher.c` 不是替代品，是并列品
在 Linux/macOS 上优先用 Python 版（断言写得清楚、改起来快）。只有 Cygwin 必须走 C 版。
:::

## 3. 非交互地验"会弹窗的后端"

后端在无人值守的验收里不能真弹 OS 对话框。两条路子：

- `TINYJS_TEST_AUTODLG=ok`：让对话框路径自答，不阻塞。
- 需要断言"到底有没有发 `DLG` 帧"时，看的是**帧**而不是屏幕 —— `smoke.php` 里那条
  `dialog.confirm -> DLG (no RET)` 就是这个用法。

`Protocol::decode` 对认不得的行返回 `type => ignore`（`NAV` / `DROP` / `HOTKEY` / `GOT`），
所以"shim 多喂了别的帧"不会把断言弄红；反过来说，`HOTKEY` 到不了页面也是个**已记录的产品缺口**，
L4 的 B3/B4 用 `mock_shim.py` 注入帧才能验（见 [后端 API](/guide/backend-api.html) §7）。

## 4. 负控：三种，别用错

断言没有牙是这个项目踩过的最贵的坑（`docs/planning/task_plan.md` 的 Errors #40）。

| 类型 | 什么时候用 | 本项目实例 |
|---|---|---|
| **一行回退** | 改的是既有文件里的一行逻辑 | `demo-chain-harness.js`：把 Darwin 的 `c.endpoint` 那一行抄回旧值 → 12 ok + **恰好 1 FAIL** |
| **自带缺陷的夹具** | 被测物是新文件，`git show HEAD:` 里根本没有它 | `mock_shim.py` 少发一帧、`host_probe.c` 缺宏 |
| **禁用某开关** | 验的是开关本身 | `macos-bundle-launch.sh` 的 `CTL_SHIM=` 负控（必须自己带上 bundle id，否则 TCC 按旧身份放行，测的就不是同一件事） |

::: danger `git show HEAD:<file>` 经常是**空控**
如果 HEAD 里压根没有这段代码（本项目 `chainFor()` 就是整块新写的），拿旧文件跑出来的
"全部通过/全部失败"不能证明任何事 —— 它证明的是 fixture 换了，不是断言有牙。
判据：**回退后必须只红掉你预期的那一条**，红两条以上就是控制本身不精确。
:::

## 5. 证据入库与独立复核

```bash
# Windows 侧（在真机上跑完驱动之后）
bash test/win/collect-evidence.sh                       # 收集 + 入库
CHECK=1 OUT="$PWD/evidence/win" bash test/win/collect-evidence.sh   # 独立重算，只读文件

# Linux 侧
REGEN=1 bash test/posix/collect-desktop-evidence.sh     # 从 evidence/linux/23-* 重写 manifest
        bash test/posix/collect-desktop-evidence.sh     # 只校验，不写
REGEN=1 bash test/posix/collect-tier6-evidence.sh       # 同上，24-*
```

先 `CHECK` 后 `REGEN`：`REGEN=1` 会按当前文件重写主张，等于自己给自己判卷。

命名约定：`evidence/<平台>/<Phase>-<来源>.<ext>`，例如 `26c-macos-bundle-launch-final.txt`。
一个 Phase 里如果补过跑，**旧文件不覆盖**，在头部写清"这份的边界是什么"
（`evidence/mac/26b-macos-bundle-launch.txt` 头部那段"本页 PNG 是改文案之前的现场"就是例子）。

## 6. macOS 抓图：三层兜底

L7 需要像素证据，而 mac 的授权不可靠。按顺序退：

1. `tools/mac-winlist.c`（CGWindowList）取 window number → `screencapture -x -o -l<id> out.png`
   按窗口抓，遮挡无关。
2. 授权掉了（症状：**退出码 0，但出一张 1920×1080 的单色图**，或 `-l<id>` 报
   `could not create image from window`）→ 用 `-R<x,y,w,h>` 按矩形抓。
3. 连矩形都不给 → 放弃像素，改跑 DOM harness（`demo-chain-harness.js`），
   并把"这一轮没有像素"写进证据文件头部。

`System Events` 取窗口标题/坐标会报 `-1719`：**Accessibility 与 Screen Recording 是两条独立授权**，
只给了后者时用不了脚本化窗口信息。另外 `sips -c h w` 是**居中**裁剪，要上/下带子得用 PIL。

## 7. 环境坑（每个都真实红过一次）

- **`pkill -f` 自匹配**：清理函数里的模式会匹配到驱动脚本自己的命令行（脚本路径里就含那个词），
  于是把整轮跑杀在打印之前。`test/posix/*.sh` 用 `'build/backend_shel[l]'` 这种字符类躲开，别"顺手清理"成直白写法。
- **Xvfb 的 stale lock**：被杀的 Xvfb 留下 `/tmp/.X99-lock` + 死 socket 节点，下次
  `could not open display`。正确做法是**用真 X client 探**，探不到才清文件再起。
- **没有 `stdbuf` 时日志会整块缓冲**：`tgui dev` 的 stdout 要等进程退出才落盘，
  于是"实时 grep"永远搜不到。`linux-tgui-window.sh` 开头那句 note 就是在提醒这件事。
- **验收产物不许落在 `test/posix/` 里**：这个目录要**逐字节**同步进外部 skill 并被 diff 校验，
  留一个临时 log 在里面会伪装成"两边不一致"。落点由 `resolve-root.sh` 统一决定。
- **Windows 磁盘**：`C:` 常年在 3% 以下余量，任何 GB 级安装前先 `df`。

## 8. 这一层之外

跑通了 ≠ 覆盖了。当前**明确没被证明**的（README 的「已知限制」有全量列表）：

- 真硬件 / 真 DE：GPU 合成、Wayland 会话、GNOME/KDE 自带托盘的实际观感、分数缩放（`GDK_SCALE=1.5`）。
- 用户会不会真的看到那个卷授权弹窗 —— bug #21 的修法是**根本不触发**弹窗，所以那条路径没被测过。
- `--nano` 自包含后端：三道卡点全在上游（`docs/upstream-issues/`，**尚未提交**）。
