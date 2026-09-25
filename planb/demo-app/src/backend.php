<?php
// The TypePHP backend for this demo. In a real project this is what aot-compiler
// (tpc) compiles into backend/app.exe — see planb/backend.php for the frame
// protocol implementation (CALL/RET, DLG, MENU, EVAL pushes).
//
//   tpcd backend.php -o backend/app.exe     # or: tpc.exe backend.php -o ...
//
// `tinyjs dev --typephp` spawns native/launcher-win.exe, which spawns the shim
// (native/backend.exe), which spawns this binary over stdio. Editing this file
// restarts the backend (the window bounces); editing src/frontend/ reloads the
// window.
echo "this file is a placeholder — see planb/backend.php\n";
