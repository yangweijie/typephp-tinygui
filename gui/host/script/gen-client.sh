#!/bin/sh
# Embed gui/runtime/tiny.js into the launcher as gui/host/src/tiny_client.h
# (generated; not committed). Run before compiling the launcher.
# This is the OWNED copy — no external tinyjsapp checkout involved.
cd "$(dirname "$0")/../.."   # -> repo root
python3 - <<'EOF'
import os
base = os.path.dirname(os.path.abspath(__file__))
js_path = os.path.join(base, 'gui', 'runtime', 'tiny.js')
out_path = os.path.join(base, 'gui', 'host', 'src', 'tiny_client.h')
js = open(js_path, encoding='utf-8').read()
assert ')TINYJS' not in js, 'raw-string delimiter collision in tiny.js'
with open(out_path, 'w', encoding='utf-8') as f:
    f.write('// GENERATED from gui/runtime/tiny.js by gui/host/script/gen-client.sh — do not edit.\n')
    f.write('static const char TINY_CLIENT_JS[] = R"TINYJS(' + js + ')TINYJS";\n')
EOF
