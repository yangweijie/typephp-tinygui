<?php
declare(strict_types=1);

function main(): void
{
    $out = fopen("php://stdout", "w");
    if ($out === false) { echo "fopen failed\n"; return; }
    fwrite($out, "php-stdout-ok\n");
    fflush($out);
}
