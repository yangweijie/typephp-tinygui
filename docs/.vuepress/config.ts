import { viteBundler } from '@vuepress/bundler-vite'
import { defaultTheme } from '@vuepress/theme-default'

// 注意：rc.31 的 `vuepress/cli` 并不导出 defineConfig（实测 SyntaxError:
// The requested module 'vuepress/cli' does not provide an export named
// 'defineConfig'），所以这里直接 export 一个普通对象——VuePress 接受，代价是没有
// 配置字段的类型提示。
//
// 这个仓库的文档里有大量"看起来像 HTML 标签"的协议占位符：`<pid>`、`<id>`、`<json>`、
// `<App>`、`<html>`…… markdown-it 在 @vuepress/markdown 里是**强制** `html: true`
// 的（dist/index.js:274，用户传的 markdown 选项被它展开到后面，改不掉），于是这些
// 占位符被当成原始 HTML 直出，而 VuePress 页面是编译成 Vue SFC 模板的 —— 构建直接死在
// `Element is missing end tag.`（实测：docs/planning/task_plan.md 与 progress.md 各一处）。
// 所以这里把原始 HTML 一律转义成文字。代价：以后想在 md 里写真 HTML（<br>、<div>）会
// 以字面量显示——本仓库现有文档 **零** HTML 标签与注释（已 grep 确认），而协议文档里
// `<xxx>` 是日常，所以这个取舍是划算的。
const escapeRawHtml = {
  name: 'vuepress-plugin-escape-raw-html',
  extendsMarkdown: (md: any) => {
    const esc = (s: string) =>
      s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    md.renderer.rules.html_block = (tokens: any, idx: number) => esc(tokens[idx].content)
    md.renderer.rules.html_inline = (tokens: any, idx: number) => esc(tokens[idx].content)
  },
}

// typephp-tinygui 的文档站。内容分四层：
//   guide/      —— 手写的导览主干（新人从这一层进）
//   *.md 根层   —— 调研 / 融合设计 / 补丁记录，原样发布
//   reference/  —— 由 docs/sync-external.sh 从仓库里的工作说明复制进来的页面
//   upstream-issues/ planning/ —— 上游素材与开发记录（含踩坑表，别删）
export default {
  lang: 'zh-CN',
  title: 'TypePHP GUI',
  description: '用 PHP 写桌面应用业务逻辑：编译后的 PHP 后端 + 融合版 tinyjsapp 宿主（WebView2 / WKWebView / WebKitGTK）',

  head: [
    ['meta', { name: 'referrer', content: 'no-referrer' }],
  ],

  bundler: viteBundler(),

  plugins: [escapeRawHtml],

  theme: defaultTheme({
    // 仓库内文档，不假设有 GitHub 远端可点；编辑链接留给 README。
    navbar: [
      { text: '指南', link: '/guide/getting-started.html' },
      { text: '帧协议', link: '/guide/protocol.html' },
      { text: '三平台差异', link: '/guide/platforms.html' },
      { text: '验证矩阵', link: '/guide/verification.html' },
      { text: '调研与设计', link: '/GUI_FUSION_DESIGN.html' },
      { text: '套件说明', link: '/reference/posix-kit.html' },
    ],

    sidebar: {
      '/': [
        {
          text: '指南',
          collapsible: false,
          children: [
            '/guide/getting-started.md',
            '/guide/architecture.md',
            '/guide/protocol.md',
            '/guide/platforms.md',
            '/guide/backend-api.md',
            '/guide/verification.md',
          ],
        },
        {
          text: '调研与设计',
          collapsible: true,
          children: [
            '/GUI_FUSION_DESIGN.md',
            '/feasibility-aot-compiler-backend.md',
            '/landing-report.md',
            '/launcher-patch-notes.md',
            '/nano-mode-ipc-addendum.md',
            '/aot-compiler-nano-fix.md',
          ],
        },
        {
          text: '上游 issue 素材（未提交）',
          collapsible: true,
          children: [
            '/upstream-issues/',
            '/upstream-issues/phpx-nano-args-get-link-gap.md',
            '/upstream-issues/tpc-nano-core-dependency-unsatisfiable.md',
            '/upstream-issues/php-nano-missing-stdio-handles.md',
          ],
        },
        {
          text: '套件与工具（同步自仓库）',
          collapsible: true,
          children: [
            '/reference/root-readme.md',
            '/reference/gui.md',
            '/reference/posix-kit.md',
            '/reference/win-kit.md',
          ],
        },
        {
          text: '开发记录（工作记忆）',
          collapsible: true,
          children: [
            '/planning/task_plan.md',
            '/planning/findings.md',
            '/planning/progress.md',
          ],
        },
      ],
    },

    sidebarDepth: 2,
    lastUpdated: false,
    contributors: false,
    editLink: false,
  }),

  markdown: {
    // 文档里有大量反例路径（`\\.\pipe\…`、`tools/build-all.bat`），
    // 全部走 code span；这里不改写链接行为，用主题默认（外链加 rel）。
    lineNumbers: false,
  },

  shouldPrefetch: false,
}
