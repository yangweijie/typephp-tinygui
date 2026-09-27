<?php
declare(strict_types=1);

function main(): void
{
    $in = fopen("/dev/stdin", "r");
    $out = fopen("/dev/stdout", "w");
    if ($in === false || $out === false) { echo "fopen failed\n"; return; }
    $l = fgets($in);
    fwrite($out, "devio-ok:" . (string) $l);
    fflush($out);
}
