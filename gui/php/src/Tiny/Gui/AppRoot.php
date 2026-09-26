<?php
/**
 * Filesystem sandbox root for page-facing fs / listDir APIs.
 *
 * Resolved once at startup (TYPEPHP_APP_ROOT, else getcwd()). Every user-supplied
 * path is realpath'd and must equal the root or live strictly under it.
 */

declare(strict_types=1);

namespace Tiny\Gui;

final class AppRoot
{
    public function __construct(private string $root)
    {
        $this->root = self::normalize($root);
    }

    public static function fromEnv(): self
    {
        $raw = getenv('TYPEPHP_APP_ROOT');
        if (!is_string($raw) || $raw === '') {
            $cwd = getcwd();
            $raw = is_string($cwd) && $cwd !== '' ? $cwd : '.';
        }
        $real = realpath($raw);
        if ($real === false) {
            throw new \RuntimeException('TYPEPHP_APP_ROOT / cwd is not a resolvable directory: ' . $raw);
        }
        return new self($real);
    }

    public function path(): string
    {
        return $this->root;
    }

    /**
     * Resolve $path (relative to root if not absolute) and return the real path
     * only if it is inside the sandbox. $mustExist=false still requires the
     * nearest existing ancestor to be inside, then appends the remainder
     * without allowing ".." after the last existing segment.
     */
    public function resolve(string $path, bool $mustExist = true): ?string
    {
        $path = str_replace(["\0"], '', $path);
        if ($path === '') {
            $path = $this->root;
        }
        $abs = $this->absolutize($path);
        $real = realpath($abs);
        if ($real !== false) {
            return $this->contains($real) ? self::normalize($real) : null;
        }
        if ($mustExist) {
            return null;
        }
        return $this->resolveNonExisting($abs);
    }

    public function contains(string $resolved): bool
    {
        $root = self::normalize($this->root);
        $path = self::normalize($resolved);
        if (PHP_OS_FAMILY === 'Windows') {
            $root = strtolower($root);
            $path = strtolower($path);
        }
        return $path === $root || str_starts_with($path, $root . DIRECTORY_SEPARATOR);
    }

    private function absolutize(string $path): string
    {
        $path = str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path);
        if ($this->isAbsolute($path)) {
            return $path;
        }
        return $this->root . DIRECTORY_SEPARATOR . $path;
    }

    private function isAbsolute(string $path): bool
    {
        if (PHP_OS_FAMILY === 'Windows') {
            return (bool)preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) || str_starts_with($path, '\\\\');
        }
        return str_starts_with($path, DIRECTORY_SEPARATOR);
    }

    private function resolveNonExisting(string $abs): ?string
    {
        $cur = rtrim($abs, '\\/');
        $suffix = [];
        while ($cur !== '' && realpath($cur) === false) {
            $base = basename($cur);
            $parent = dirname($cur);
            if ($base === '' || $parent === $cur) {
                break;
            }
            if ($base === '..' || $base === '.') {
                return null;
            }
            array_unshift($suffix, $base);
            $cur = $parent;
        }
        $real = realpath($cur);
        if ($real === false || !$this->contains($real)) {
            return null;
        }
        foreach ($suffix as $seg) {
            if ($seg === '..' || $seg === '.' || str_contains($seg, "\0")) {
                return null;
            }
        }
        $final = $suffix === []
            ? $real
            : rtrim($real, '\\/') . DIRECTORY_SEPARATOR . implode(DIRECTORY_SEPARATOR, $suffix);
        $final = self::normalize($final);
        return $this->contains($final) ? $final : null;
    }

    private static function normalize(string $p): string
    {
        $p = str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $p);
        $p = rtrim($p, DIRECTORY_SEPARATOR);
        if (PHP_OS_FAMILY === 'Windows' && preg_match('/^[A-Za-z]:$/', $p)) {
            $p .= DIRECTORY_SEPARATOR;
        }
        if ($p === '') {
            $p = DIRECTORY_SEPARATOR;
        }
        return $p;
    }
}
