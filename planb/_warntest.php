<?php
// Where does each stream end up? Write a marker to each, then cause a warning.
fwrite(STDOUT, "MARK-OUT\n");
fwrite(STDERR, "MARK-ERR\n");
$x = @$undefined;                 // notice (suppressed)
trigger_error("MARK-NOTICE", E_USER_NOTICE);
$y = 1 / 0;                       // warning-ish (division by zero -> DivisionByZeroError in 8)
