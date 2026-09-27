<?php
declare(strict_types=1);

function main(): void
{
    $f = fopen("probe.txt", "r");
    if ($f === false) { echo "regular fopen FAILED\n"; return; }
    echo "regular fopen ok: " . trim((string) fgets($f)) . "\n";
    $g = @fopen("/dev/null", "r");
    echo "/dev/null: " . ($g === false ? "failed" : "ok") . "\n";
}
