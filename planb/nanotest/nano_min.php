<?php
// Minimal probe: does the Windows --nano (nano-policy) path crash at teardown
// even for a trivial program? Nothing here touches stdin/stdout beyond one write.
function main(): void
{
    fwrite(STDOUT, "nano-min-ok\n");
    fflush(STDOUT);
}
