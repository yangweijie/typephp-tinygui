<?php
/**
 * Built-in handlers every GUI app gets for free: liveness probes, the client
 * bootstrap call, logging, system info, sandboxed filesystem access, and the
 * pull-based state getters (theme/locale/win) backed by the cached State.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{AppRoot, HandlerInterface, Protocol, Request, Response, State};

final class CoreHandler implements HandlerInterface
{
    public function __construct(
        private State $state,
        private AppRoot $root,
    ) {
    }

    public function methods(): array
    {
        return [
            'ping', 'client.hello', 'log', 'sysinfo', 'listDir',
            'theme.get', 'system.locale', 'win.getState',
            'app.root',
            'fs.list', 'fs.readText', 'fs.writeText', 'fs.exists', 'fs.stat',
        ];
    }

    public function handle(Request $req): ?Response
    {
        return match ($req->method) {
            'ping'           => Response::ok('pong'),
            'client.hello'   => Response::ok(true),
            'log'            => $this->log($req),
            'sysinfo'        => Response::ok($this->sysinfo()),
            'listDir', 'fs.list' => $this->listDir($req),
            'theme.get'      => Response::ok($this->state->theme),
            'system.locale'  => Response::ok($this->state->locale),
            'win.getState'   => Response::ok($this->state->winState),
            'app.root'       => Response::ok($this->root->path()),
            'fs.readText'    => $this->readText($req),
            'fs.writeText'   => $this->writeText($req),
            'fs.exists'      => $this->exists($req),
            'fs.stat'        => $this->stat($req),
            default          => null,
        };
    }

    private function log(Request $req): Response
    {
        try {
            $payload = Protocol::jenc($req->params['msg'] ?? $req->params);
        } catch (\JsonException $e) {
            $payload = '{"error":"unencodable log payload"}';
        }
        fwrite(STDERR, '[php-backend] ' . $payload . "\n");
        return Response::ok(true);
    }

    private function sysinfo(): array
    {
        return [
            'runtime' => 'PHP ' . PHP_VERSION,
            'host'    => (string)(php_uname('n') ?: 'localhost'),
            'cpu'     => (string)php_uname('m'),
            'pid'     => (int)getmypid(),
            'cwd'     => (string)getcwd(),
            'root'    => $this->root->path(),
            'home'    => (string)($_SERVER['USERPROFILE'] ?? $_ENV['USERPROFILE']
                                  ?? $_SERVER['HOME'] ?? $_ENV['HOME'] ?? ''),
            'os'      => (string)PHP_OS_FAMILY,
            'backend' => 'aot-compiler (tpc) AOT native',
        ];
    }

    private function listDir(Request $req): Response
    {
        $raw = (string)($req->params['path'] ?? '.');
        $path = $this->root->resolve($raw, true);
        if ($path === null || !is_dir($path)) {
            return Response::error('path outside sandbox or not a directory: ' . $raw);
        }
        $dh = @opendir($path);
        if ($dh === false) {
            return Response::error("cannot open dir: {$path}");
        }
        $out = [];
        while (($e = readdir($dh)) !== false) {
            if ($e === '.' || $e === '..') {
                continue;
            }
            $out[] = ['name' => $e, 'isDir' => is_dir($path . DIRECTORY_SEPARATOR . $e)];
            if (count($out) >= 200) {
                break;
            }
        }
        closedir($dh);
        usort($out, fn($a, $b) => ($b['isDir'] <=> $a['isDir']) ?: strcmp($a['name'], $b['name']));
        return Response::ok(['path' => $path, 'entries' => $out]);
    }

    private function readText(Request $req): Response
    {
        $raw = (string)($req->params['path'] ?? '');
        $path = $this->root->resolve($raw, true);
        if ($path === null || !is_file($path)) {
            return Response::error('path outside sandbox or not a file: ' . $raw);
        }
        $data = @file_get_contents($path);
        if ($data === false) {
            return Response::error('cannot read: ' . $raw);
        }
        return Response::ok($data);
    }

    private function writeText(Request $req): Response
    {
        $raw = (string)($req->params['path'] ?? '');
        $path = $this->root->resolve($raw, false);
        if ($path === null) {
            return Response::error('path outside sandbox: ' . $raw);
        }
        $parent = dirname($path);
        if (!is_dir($parent) || !$this->root->contains((string)realpath($parent))) {
            return Response::error('parent directory is outside sandbox or missing: ' . $raw);
        }
        $ok = @file_put_contents($path, (string)($req->params['content'] ?? ''));
        if ($ok === false) {
            return Response::error('cannot write: ' . $raw);
        }
        return Response::ok(true);
    }

    private function exists(Request $req): Response
    {
        $raw = (string)($req->params['path'] ?? '');
        $path = $this->root->resolve($raw, true);
        return Response::ok($path !== null);
    }

    private function stat(Request $req): Response
    {
        $raw = (string)($req->params['path'] ?? '');
        $path = $this->root->resolve($raw, true);
        if ($path === null) {
            return Response::error('path outside sandbox or missing: ' . $raw);
        }
        $st = @stat($path);
        if ($st === false) {
            return Response::error('cannot stat: ' . $raw);
        }
        return Response::ok([
            'path'  => $path,
            'isDir' => is_dir($path),
            'isFile'=> is_file($path),
            'size'  => (int)$st['size'],
            'mtime' => (int)$st['mtime'],
        ]);
    }
}
