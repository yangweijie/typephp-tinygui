// demo-chain-harness.js — assert what the demo page's chain chips SAY, without a
// display, a window, or a Screen Recording grant.
//
// Why: `demo/src/frontend/index.html` derives its five chips, the footer and the
// success banner from `chainFor(sysinfo.os, sysinfo.backend)`. A pixel check
// proves a chip only for the platform whose window you happened to photograph,
// and it needs the Screen Recording grant (which this machine has revoked and
// re-granted on its own schedule). The harness runs the REAL function out of the
// REAL file, so a wrong label fails on every host, and it comes with a negative
// control: the same assertions against an old build of the page must fail, or the
// assertions have no teeth.
//
// usage:  node test/posix/demo-chain-harness.js [path/to/index.html]
// Exit:   0 = every assertion passed, 1 = at least one failed.
//
// The control: `git show HEAD:<file>` is only a valid control for changes that
// HEAD already contains. It is NOT valid here — HEAD predates chainFor()
// entirely, so the whole run dies with "chainFor() not found", which proves the
// files differ but says nothing about any single assertion. To control one label,
// copy the current page and revert JUST that line, then require exactly the one
// matching assertion to fail. See evidence/mac/26c-chain-harness.txt for the
// worked example (Darwin `c.endpoint` put back to the pre-Phase-26
// "packaged endpoint always sits next to the exe" claim ⇒ 12 ok / 1 fail).

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const FILE = process.argv[2] ||
  path.join(__dirname, '..', '..', 'demo', 'src', 'frontend', 'index.html');
const html = fs.readFileSync(FILE, 'utf8');

// Pull chainFor() out by brace matching: a regex over the whole function body
// would silently stop at the first `}` inside a string.
function extract(src, sig) {
  const at = src.indexOf(sig);
  if (at < 0) return null;
  let depth = 0, i = src.indexOf('{', at);
  const start = i;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  return src.slice(at, i + 1);
}

const fnSrc = extract(html, 'function chainFor(');
if (!fnSrc) {
  console.log('FAIL chainFor() not found in ' + FILE);
  process.exit(1);
}
const chainFor = vm.runInNewContext(fnSrc + '; chainFor');

let pass = 0, fail = 0;
function eq(label, got, want) {
  if (got === want) { console.log('  ok   ' + label); pass++; }
  else {
    console.log('  FAIL ' + label + '\n        got : ' + JSON.stringify(got) +
                '\n        want: ' + JSON.stringify(want));
    fail++;
  }
}
function has(label, got, needle) {
  if (typeof got === 'string' && got.includes(needle)) { console.log('  ok   ' + label); pass++; }
  else {
    console.log('  FAIL ' + label + '\n        got : ' + JSON.stringify(got) +
                '\n        expected to contain: ' + needle);
    fail++;
  }
}

console.log('== chainFor fixtures, from ' + FILE);

const win = chainFor('Windows', 'aot-compiler app.exe');
eq('Windows: engine', win.engine, 'WebView2 渲染');
has('Windows: endpoint is a named pipe', win.endpoint, '\\\\.\\pipe\\tinyjs-typephp');
has('Windows: banner names the AOT backend the shim reported', win.banner, 'tpc 编出的原生后端');

const lin = chainFor('Linux', 'stock PHP CLI (no AOT)');
eq('Linux: engine', lin.engine, 'WebKitGTK 渲染');
has('Linux: notes the inverted direction', lin.note, '方向相反');
has('Linux: does not claim AOT', lin.banner, '系统 PHP');

const mac = chainFor('Darwin', 'stock PHP CLI (no AOT)');
eq('macOS: engine', mac.engine, 'WKWebView 渲染');
eq('macOS: launcher', mac.launcher, 'launcher-macos');
// The one that Phase 26 changed: the packaged endpoint is <exe dir>/app.sock
// ONLY while that dir is on the boot volume; otherwise the shim moves it to the
// per-user temp dir (bug #21). A label that omits the second half is a lie on
// every bundle that ships on a download volume.
has('macOS: endpoint names the packaged default', mac.endpoint, '<exe 目录>/app.sock');
has('macOS: endpoint names the off-boot-volume move', mac.endpoint, '$TMPDIR');
has('macOS: does not claim AOT', mac.banner, '系统 PHP');

// Unknown os must not silently read as Windows — that was the whole bug.
const unk = chainFor('FreeBSD', '');
eq('unknown os: falls back to the WKWebView branch, not WebView2', unk.engine, 'WKWebView 渲染');
has('unknown os + empty backend: admits it is unreported', unk.app, '未上报');

console.log('== harness: ' + pass + ' ok / ' + fail + ' fail');
process.exit(fail ? 1 : 0);
