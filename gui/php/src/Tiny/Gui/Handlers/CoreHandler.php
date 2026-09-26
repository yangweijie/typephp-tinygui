<?php
/**
 * Built-in handlers every GUI app gets for free: liveness probes, the client
 * bootstrap call, logging, system info, real filesystem access, and the
 * pull-based state getters (theme/locale/win) backed by the cached State.
 */

declare(strict_types=1);

namespace Tiny\Gui\Handlers;

use Tiny\Gui\{HandlerInterface, Protocol, Request, Response, State};

final class CoreHandler implements HandlerInterface
{
    public function __construct(private State $state)
    {
    }

    public function methods(): array
    {
        return [
            'ping', 'client.hello', 'log', 'sysinfo', 'listDir',
            'theme.get', 'system.locale', 'win.getState',
        ];
    }

    public function handle(Request $req): ?Response
    {
        return match ($req->method) {
            'ping'         => Response::ok('pong'),
            'client.hello' => Response::ok(true),
            'log'          => $this->log($req),
            'sysinfo'      => Response::ok($this->sysinfo()),
            'listDir'      => $this->listDir($req),
            'theme.get'    => Response::ok($this->state->theme),
            'system.locale'  => Response::ok($this->state->locale),
            'win.getState'   => Response::ok($this->state->winState),
            default        => null,
        };
    }

    private function log(Request $req): Response
    {
        fwrite(STDERR, '[php-backend] ' . Protocol::jenc($req->params['msg'] ?? $req->params) . "\n");
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
            'home'    => (string)($_SERVER['USERPROFILE'] ?? $_ENV['USERPROFILE']
                                  ?? $_SERVER['HOME'] ?? $_ENV['HOME'] ?? ''),
            'os'      => (string)PHP_OS_FAMILY,
            'backend' => 'aot-compiler (tpc) AOT native',
        ];
    }

    private function listDir(Request $req): Response
    {
        $path = (string)($req->params['path'] ?? getcwd());
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
}
