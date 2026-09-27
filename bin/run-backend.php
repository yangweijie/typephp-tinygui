#!/usr/bin/env php
<?php
// Stock-PHP runner for the same backend logic (no tpc/AOT involved).
// src/backend.php is a thin entry that calls Gui::serveDemo() at include time,
// so requiring it is all there is. The shebang + exec bit also let the POSIX
// shim `execv` this file directly as the packaged `app=` backend (the shim
// spawns the backend with NO argv, so the script must be self-launching).
// Historical note: this wrapper once called main() explicitly — that was the
// pre-fusion procedural entry; main() no longer exists.
require __DIR__ . '/../src/backend.php';
