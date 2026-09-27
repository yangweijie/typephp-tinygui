<?php
declare(strict_types=1);

final class Sorter
{
    public function rows(): array
    {
        $out = [["name" => "b", "isDir" => false], ["name" => "a", "isDir" => true]];
        usort($out, function ($a, $b) {
            return [$b['isDir'], $a['name']] <=> [$a['isDir'], $b['name']];
        });
        return $out;
    }
}

function main(): void
{
    $s = new Sorter();
    echo "nano-ctrl-ok ", $s->rows()[0]['name'], "\n";
}
