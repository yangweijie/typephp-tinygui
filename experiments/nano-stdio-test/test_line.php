<?php
function main(): void {
    $line = fgets(STDIN);
    if ($line === false) {
        fwrite(STDOUT, "STDIN_EOF\n");
    } else {
        fwrite(STDOUT, "ECHO:" . rtrim($line, "\r\n") . "\n");
    }
    fwrite(STDERR, "STDERR_OK\n");
}
