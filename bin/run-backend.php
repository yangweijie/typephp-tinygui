<?php
// Test wrapper: aot-compiler auto-invokes main(); stock PHP CLI needs an explicit
// call. Keep backend.php pure for the compiler and use this only for local tests.
require __DIR__ . '/backend.php';
main();
