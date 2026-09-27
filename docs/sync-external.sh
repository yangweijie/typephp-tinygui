#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sync-external.sh — 把仓库里"真正在维护"的几份工作说明同步进文档站。
#
# 为什么是"复制"而不是软链或包含：VuePress 的 source dir 就是 docs/，站点根本
# 看不见 docs/ 之外的文件；软链在 Vite 的 fs 解析下会 realpath 到 source root
# 之外，不稳。所以每次 dev/build 前重跑一遍（docs/package.json 的脚本已经串好），
# 这样"文档站和仓库不一致"的窗口只存在于两次构建之间，不存在于磁盘上。
#
# 复制时做两件事：
#   1) 每页顶部加一段"本页从哪来、别在这儿改"的来源说明；
#   2) 重写 markdown 链接：指向 docs/ 内的改成站内路由，指向仓库其它文件的
#      降级成 `label（仓库路径 x/y）` —— 站点里没有那些文件，留着就是死链。
#      （实测这两个文件一共只有 2 条相对链接，重写代价远小于让构建报死链。）
#
# 用法：bash docs/sync-external.sh
# ---------------------------------------------------------------------------
set -euo pipefail

DOCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DOCS_DIR/.." && pwd)"
OUT="$DOCS_DIR/reference"

mkdir -p "$OUT"

# from:repo-relative  to:site filename under docs/reference/
sync_one() {
  local from="$1" to="$2"
  if [ ! -f "$ROOT/$from" ]; then
    echo "sync-external: MISSING source $from — skipped" >&2
    return 0
  fi
  ROOT="$ROOT" DOCS_DIR="$DOCS_DIR" OUT="$OUT" FROM="$from" TO="$to" \
    python3 - <<'PY'
import os, re, pathlib

root = pathlib.Path(os.environ["ROOT"])
docs = pathlib.Path(os.environ["DOCS_DIR"])
frm = os.environ["FROM"]
to = os.environ["TO"]
src = root / frm
text = src.read_text(encoding="utf-8")

LINK = re.compile(r'(?<!\!)\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)')

def site_route(md: pathlib.Path):
    """docs/x/y.md -> /x/y.html ；docs/x/README.md -> /x/ （路由要带尾斜杠）"""
    try:
        rel = md.relative_to(docs).as_posix()
    except ValueError:
        return None
    if rel.upper().endswith("README.MD"):
        return "/" + rel[: -len("README.md")]
    return "/" + rel[:-3] + ".html"

def rewrite(m):
    label, target = m.group(1), m.group(2)
    if re.match(r'^(https?:|mailto:|#)', target):
        return m.group(0)
    anchor = ""
    if "#" in target:
        target, _, anchor = target.partition("#")
        anchor = "#" + anchor
    if not target:                       # 纯锚点
        return m.group(0)
    abs_target = (src.parent / target).resolve() if not target.startswith("/") \
        else root / target.lstrip("/")
    if str(abs_target).startswith(str(docs) + os.sep):
        route = site_route(pathlib.Path(str(abs_target)))
        if route:
            return f'[{label}]({route}{anchor})'
    rel = os.path.relpath(abs_target, root) if abs_target.exists() else target
    return f'{label}（仓库路径 `{rel}`）'

text = LINK.sub(rewrite, text)

header = (
    "> 本页由 `docs/sync-external.sh` 从 `" + frm + "` **原样复制**，"
    "每次 `npm run dev` / `npm run build` 前重跑。\n"
    "> 要改内容请改 `" + frm + "`；在这里改会在下一次构建时被覆盖。\n\n"
)
out = docs / "reference" / to
out.write_text(header + text, encoding="utf-8")
print("synced %s -> docs/reference/%s (%d bytes)" % (frm, to, len(header + text)))
PY
}

sync_one "gui/README.md"          "gui.md"
sync_one "test/posix/README.md"   "posix-kit.md"
sync_one "test/win/README.md"     "win-kit.md"
sync_one "README.md"              "root-readme.md"

# 构建产物目录里的旧页面要清掉吗？不要：文件名固定，覆盖即可；但删掉的源文件会留下
# 孤儿页面（VuePress 会照样发布它）。所以在这里显式声明期望集合，多余的删。
expected="gui.md posix-kit.md win-kit.md root-readme.md"
for f in "$OUT"/*.md; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  case " $expected " in
    *" $base "*) ;;
    *) echo "sync-external: removing orphan $base (its source is gone)" >&2; rm -f "$f" ;;
  esac
done
