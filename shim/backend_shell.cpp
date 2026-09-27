// backend_shell.cpp — TypePHP bridge SHIM for tinyjsapp.  (Windows + POSIX)
//
// Problem: the launcher talks to its backend over a byte-mode IPC endpoint —
// a Windows NAMED PIPE, or an AF_UNIX socket on macOS/Linux. But stock PHP (and
// aot-compiler's bundled libphp) cannot *serve* either one:
//   * Windows: PHP has no `pipe://` socket transport;
//   * true php-nano (POSIX/WASI): the whole socket API is gone at compile time
//     (`socket_`/`stream_socket_*` are in CompilerBase::NANO_UNSUPPORTED_*`).
// PHP does handle stdio perfectly, though.
//
// Solution: this tiny shim is what the launcher actually spawns (as `backend.exe`
// or via TYPEPHP_BACKEND). It:
//   1. creates the IPC endpoint SERVER (named pipe / unix socket) under the name
//      the launcher hands it,
//   2. spawns the real PHP backend (aot-compiler `app.exe`, or `php backend.php`
//      for testing) with inherited stdio,
//   3. proxies frames between the launcher endpoint and the PHP backend's stdio.
//
// The protocol is request/response and line-framed (CALL <id> <json> ->
// RET <id> <status> <json>), so the proxy is SINGLE-THREADED and strictly
// line-oriented. A threaded version was tried first and deadlocked on the
// named-pipe write under load, so we keep this deliberately simple: no threads.
// It is NOT a strict request/response pump either — the launcher also sends
// *notification* frames (WINSTATE, MENU, …) that the backend never answers, so
// a "read a CALL then wait for its RET" loop would stall forever. Instead both
// directions are polled non-blockingly and whatever bytes are available get
// forwarded, with per-direction line reassembly.
//
// The child's three stdio channels are kept separate, and this matters:
//   stdin  <- launcher frames, stdout -> launcher frames  (the frame channel)
//   stderr -> drained by us and written to the SHIM LOG ONLY, never forwarded.
// stderr must not share stdout: PHP's error routing differs between builds (7.x
// and 8.x disagree on whether a notice goes to stdout or stderr), so merging the
// two would let a stray PHP notice appear as a malformed frame in the middle of
// the conversation. Draining it also stops a chatty backend from filling the
// pipe buffer and blocking on its own write.
//
// Cross-platform notes
//   * transport  : Windows CreateNamedPipeW/ConnectNamedPipe/PeekNamedPipe
//                  POSIX   socket(AF_UNIX)/bind/listen/accept + poll()+read()
//   * child spawn: Windows CreateProcessW (STARTF_USESTDHANDLES)
//                  POSIX   fork()+dup2()+execv(); all our fds are FD_CLOEXEC so
//                          the launcher child inherits nothing (the POSIX peer of
//                          passing bInheritHandles=FALSE on Windows).
//   * The socket path follows runtime/bridge.js: it is a FILESYSTEM path
//     (`<workDir>/app.sock`), so we unlink a stale file before bind() and again
//     on exit — a socket left by a crashed instance would block listen().
//
// Build (Windows):
//   g++ -std=c++17 -O2 -o backend_shell.exe backend_shell.cpp -ladvapi32
// Build (Linux/macOS):
//   g++ -std=c++17 -O2 -o backend_shell backend_shell.cpp
// Run (what the launcher does): backend_shell "\\.\pipe\tinyjs-typephp-<pid>"
//                               backend_shell /run/user/1000/app.sock
//
// Diagnostics: the launcher spawns us with no console (CREATE_NO_WINDOW, no
// inherited handles), so stdout is useless. Set TYPEPHP_SHELL_LOG=<file> to log
// to that file; otherwise we log to stdout when a console is present.

// Feature-test macro — MUST precede every #include to have any effect.
// `-std=c++17` makes the compiler define __STRICT_ANSI__, and libc then hides
// POSIX declarations unless a visibility macro asks for them. On glibc the g++
// driver injects _GNU_SOURCE for C++ automatically, which is why this went
// unnoticed for a while; on Cygwin/newlib it does NOT, and readlink(), kill()
// and setenv() come back as "not declared in this scope". Ask for it ourselves
// so the source builds the same way on every libc instead of relying on a
// driver default. (No-op on Windows: it only guards the POSIX header block.)
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h> // _NSGetExecutablePath
#include <limits.h>     // PATH_MAX (realpath)
#endif
#endif

// ---------------------------------------------------------------------------
// Platform types
// ---------------------------------------------------------------------------
#ifdef _WIN32
typedef HANDLE io_t;      // both the launcher endpoint and a child pipe end
typedef HANDLE proc_t;
typedef std::wstring path_t;
static const io_t IO_BAD = INVALID_HANDLE_VALUE;
static const proc_t PROC_BAD = nullptr;
static const wchar_t *const SEP = L"\\/";
#else
typedef int io_t;
typedef pid_t proc_t;
typedef std::string path_t;
static const io_t IO_BAD = -1;
static const proc_t PROC_BAD = (pid_t)-1;
static const char *const SEP = "/";
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
static FILE *g_log = nullptr;

static void logf_(const char *fmt, ...) {
  if (!g_log) return;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(g_log, fmt, ap);
  va_end(ap);
  fflush(g_log);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
static std::string narrow_(const path_t &p) {
#ifdef _WIN32
  if (p.empty()) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, p.c_str(), (int)p.size(), nullptr, 0,
                              nullptr, nullptr);
  std::string s((size_t)n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, p.c_str(), (int)p.size(), &s[0], n, nullptr,
                      nullptr);
  return s;
#else
  return p;
#endif
}

static path_t widen_(const std::string &s) {
#ifdef _WIN32
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
  return w;
#else
  return s;
#endif
}

// Literal helper so the same source reads the same on both platforms.
static path_t lit(const char *s) { return widen_(std::string(s)); }

static bool is_abs_(const path_t &p) {
#ifdef _WIN32
  if (p.size() >= 2 && p[1] == L':') return true; // C:\...
#endif
  return !p.empty() && (p[0] == SEP[0] || (SEP[1] != '\0' && p[0] == SEP[1]));
}

// Resolve a possibly-relative path against a base directory.
static path_t resolve(const path_t &base, const path_t &rel) {
  if (rel.empty()) return rel;
  if (is_abs_(rel)) return rel;
  return base + rel;
}

static path_t exe_path() {
#ifdef _WIN32
  wchar_t buf[32768];
  DWORD n = GetModuleFileNameW(nullptr, buf, 32768);
  return std::wstring(buf, (size_t)n);
#else
#if defined(__APPLE__)
  // macOS has no /proc/self/exe — dyld is the portable answer there.
  char buf[PATH_MAX];
  uint32_t n = sizeof(buf);
  if (_NSGetExecutablePath(buf, &n) != 0) return std::string("app");
  char real[PATH_MAX];
  if (realpath(buf, real)) return std::string(real); // drop symlinks
  return std::string(buf);
#else
  char buf[4096];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return std::string("app");
  buf[n] = '\0';
  return std::string(buf, (size_t)n);
#endif
#endif
}

static path_t dir_of(const path_t &p) {
  size_t sl = p.find_last_of(SEP);
  return sl == path_t::npos ? path_t() : p.substr(0, sl + 1);
}

static path_t stem_of(const path_t &p) {
  size_t sl = p.find_last_of(SEP);
  path_t base = (sl == path_t::npos) ? p : p.substr(sl + 1);
#ifdef _WIN32
  size_t dot = base.find_last_of(L'.');
#else
  size_t dot = base.find_last_of('.');
#endif
  return dot == path_t::npos ? base : base.substr(0, dot);
}

// ---------------------------------------------------------------------------
// Where the packaged endpoint may live (POSIX only)
// ---------------------------------------------------------------------------
#ifndef _WIN32
#if defined(__APPLE__)
// True when `dir` shares a file system with `/`. st_dev is the mount id on both
// BSD and Linux, so one comparison answers "is the app bundle on the boot
// volume?". On failure we say true: the caller then keeps the historical
// behaviour (socket next to the bundle) instead of inventing a new one.
// Apple-only caller, so Apple-only definition — a Linux build would otherwise
// carry an unused static and -Wall would say so.
static bool on_boot_volume(const std::string &dir) {
  struct stat root_st, dir_st;
  if (stat("/", &root_st) != 0) return true;
  if (stat(dir.c_str(), &dir_st) != 0) return true;
  return root_st.st_dev == dir_st.st_dev;
}
#endif

// Per-process endpoint path in a directory we know a GUI-launched process may
// create files in. `pid` comes from the caller so the Windows build (which has
// no use for this) does not drag in unistd.
static std::string tmp_endpoint(long pid) {
  std::string dir = "/tmp";
#ifdef __APPLE__
  // Prefer the per-user $TMPDIR (0700, on the boot volume): /tmp is world
  // writable, and an endpoint name that survives across a reboot is a
  // handover waiting to happen. Only if it is missing or too fat for sun_path
  // do we take /tmp.
  const char *t = getenv("TMPDIR");
  if (t && *t) {
    std::string s = t;
    while (s.size() > 1 && s[s.size() - 1] == '/') s.erase(s.size() - 1);
    if (s.size() + 40 < sizeof(((struct sockaddr_un *)nullptr)->sun_path)) dir = s;
  }
#endif
  return dir + "/tinyjs-typephp-" + std::to_string(pid) + ".sock";
}
#endif

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
static bool env_path(const char *key, path_t &out) {
#ifdef _WIN32
  wchar_t buf[32768];
  std::wstring k = widen_(key);
  DWORD n = GetEnvironmentVariableW(k.c_str(), buf, 32768);
  if (n == 0 || n >= 32768) return false;
  out.assign(buf, (size_t)n);
  return true;
#else
  const char *v = getenv(key);
  if (!v || !*v) return false;
  out = v;
  return true;
#endif
}

static bool env_str(const char *key, std::string &out) {
  path_t p;
  if (!env_path(key, p)) return false;
  out = narrow_(p);
  return true;
}

// ---------------------------------------------------------------------------
// IO primitives
// ---------------------------------------------------------------------------
static void sleep_ms(int ms) {
#ifdef _WIN32
  Sleep((DWORD)ms);
#else
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, nullptr);
#endif
}

// Non-blocking availability probe.
//   true  + *got>0 -> that many bytes were read into buf
//   true  + *got==0 -> nothing available right now
//   false           -> peer closed / hard error
static bool io_read_avail(io_t in, char *buf, size_t cap, size_t *got) {
  *got = 0;
#ifdef _WIN32
  DWORD avail = 0;
  if (!PeekNamedPipe(in, nullptr, 0, nullptr, &avail, nullptr))
    return false; // launcher/backend gone
  if (avail == 0) return true;
  DWORD want = avail < (DWORD)cap ? avail : (DWORD)cap, g = 0;
  if (!ReadFile(in, buf, want, &g, nullptr) || g == 0) return false;
  *got = (size_t)g;
  return true;
#else
  struct pollfd pfd;
  pfd.fd = in;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int r = poll(&pfd, 1, 0);
  if (r < 0) {
    if (errno == EINTR) return true;
    return false;
  }
  if (r == 0) return true; // nothing yet
  ssize_t n = read(in, buf, cap);
  if (n < 0) {
    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return true;
    return false;
  }
  if (n == 0) return false; // EOF
  *got = (size_t)n;
  return true;
#endif
}

static bool io_write_all(io_t out, const char *p, size_t len) {
  size_t off = 0;
  while (off < len) {
#ifdef _WIN32
    DWORD w = 0;
    if (!WriteFile(out, p + off, (DWORD)(len - off), &w, nullptr) || w == 0)
      return false;
    off += (size_t)w;
#else
    ssize_t w = write(out, p + off, len - off);
    if (w < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (w == 0) return false;
    off += (size_t)w;
#endif
  }
  return true;
}

static bool io_write_line(io_t out, const std::string &s) {
  std::string t = s;
  t.push_back('\n');
  return io_write_all(out, t.data(), t.size());
}

// Create the server side of the launcher transport.
//   Windows: `name` is a full pipe name (\\.\pipe\...)
//   POSIX  : `name` is a filesystem socket path
static io_t io_open_endpoint(const std::string &name) {
#ifdef _WIN32
  SECURITY_ATTRIBUTES sa_noinh = {sizeof(sa_noinh), nullptr, FALSE};
  return CreateNamedPipeW(widen_(name).c_str(), PIPE_ACCESS_DUPLEX,
                          PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
                          65536, 65536, 0, &sa_noinh);
#else
  if (name.size() >= sizeof(((struct sockaddr_un *)nullptr)->sun_path)) {
    logf_("[shell] socket path too long (%zu): %s\n", name.size(), name.c_str());
    return IO_BAD;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    logf_("[shell] socket() failed: %s\n", strerror(errno));
    return IO_BAD;
  }
  int fl = fcntl(fd, F_GETFD);
  if (fl >= 0) fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, name.c_str(), sizeof addr.sun_path - 1);
  // A socket file left behind by a crashed instance blocks bind(). bridge.js
  // clears it the same way.
  unlink(name.c_str());
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    logf_("[shell] bind(%s) failed: %s\n", name.c_str(), strerror(errno));
    close(fd);
    return IO_BAD;
  }
  if (listen(fd, 1) != 0) {
    logf_("[shell] listen(%s) failed: %s\n", name.c_str(), strerror(errno));
    close(fd);
    return IO_BAD;
  }
  return fd;
#endif
}

// Block until the launcher connects. Returns the connected endpoint (== server
// handle on Windows; a new fd on POSIX), or IO_BAD.
static io_t io_accept(io_t srv) {
#ifdef _WIN32
  BOOL ok = ConnectNamedPipe(srv, nullptr);
  DWORD err = ok ? 0 : GetLastError();
  if (!ok && err != ERROR_PIPE_CONNECTED) {
    logf_("[shell] ConnectNamedPipe rc=%d err=%lu\n", (int)ok, err);
    return IO_BAD;
  }
  return srv;
#else
  while (true) {
    int fd = accept(srv, nullptr, nullptr);
    if (fd >= 0) {
      int fl = fcntl(fd, F_GETFD);
      if (fl >= 0) fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
      return fd;
    }
    // A signal (SIGCHLD of our own children is the common one) must not read as
    // "the launcher will never come".
    if (errno == EINTR) continue;
    logf_("[shell] accept() failed: %s\n", strerror(errno));
    return IO_BAD;
  }
#endif
}

// Launch-mode variant of io_accept: OURS is the parent, so the launcher we
// spawned can die BEFORE it ever connects — no X display, a missing GTK/WebKit
// lib, bad args. A bare accept() then blocks forever: the PHP child, the listen
// socket and the socket FILE all linger with it (shipped-bug #25). So poll the
// endpoint and watch the launcher in the same loop; whichever comes first wins.
// `*launcher_died` distinguishes "gave up because it vanished" from "accept
// broke". Windows keeps the blocking ConnectNamedPipe: this loop's waitpid
// semantics do not port, and the Windows packaged direction is covered by
// real-machine tests where this hang has not been seen.
static io_t io_accept_watching(io_t srv, proc_t launcher, bool *launcher_died) {
  *launcher_died = false;
#ifdef _WIN32
  (void)launcher;
  return io_accept(srv);
#else
  while (true) {
    struct pollfd pfd;
    pfd.fd = srv;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int r = poll(&pfd, 1, 100);
    if (r > 0) return io_accept(srv); // POLLIN on a listener means a connect is up
    if (r < 0 && errno != EINTR) {
      logf_("[shell] poll(listen) failed: %s\n", strerror(errno));
      return IO_BAD;
    }
    if (launcher == PROC_BAD) continue; // dev mode: nothing to watch
    int st = 0;
    pid_t w = waitpid(launcher, &st, WNOHANG);
    if (w == launcher) { // reaped here — the caller must NOT kill it again
      *launcher_died = true;
      logf_("[shell] launcher exited (status %d) before connecting\n", st);
      return IO_BAD;
    }
    if (w < 0 && errno != EINTR) {
      *launcher_died = true; // ECHILD: it is already gone in every real case
      return IO_BAD;
    }
  }
#endif
}

static void io_close(io_t h) {
  if (h == IO_BAD) return;
#ifdef _WIN32
  CloseHandle(h);
#else
  close(h);
#endif
}

// POSIX: remove the socket file so the next run can bind. Windows: no-op.
static void io_cleanup_endpoint(const std::string &name) {
#ifndef _WIN32
  unlink(name.c_str());
#else
  (void)name; // named pipes vanish with the last handle
#endif
}

// ---------------------------------------------------------------------------
// Child stdio pipes
// ---------------------------------------------------------------------------
// Creates a ONE-WAY pipe pair: `read_end` reads, `write_end` writes. The caller
// decides which end the child holds — note the two directions use OPPOSITE
// halves (child stdin = read end, child stdout = write end).
static bool make_pipe(io_t &read_end, io_t &write_end) {
#ifdef _WIN32
  SECURITY_ATTRIBUTES sa_noinh = {sizeof(sa_noinh), nullptr, FALSE};
  HANDLE r = nullptr, w = nullptr;
  if (!CreatePipe(&r, &w, &sa_noinh, 0)) return false;
  read_end = r;
  write_end = w;
  return true;
#else
  int fds[2];
  if (pipe(fds) != 0) return false;
  read_end = fds[0];
  write_end = fds[1];
  // Everything starts close-on-exec so the launcher child inherits nothing; we
  // clear the flag on the child ends we actually hand over.
  for (int i = 0; i < 2; ++i) {
    int fl = fcntl(fds[i], F_GETFD);
    if (fl >= 0) fcntl(fds[i], F_SETFD, fl | FD_CLOEXEC);
  }
  return true;
#endif
}

#ifdef _WIN32
// The child's inherited ends must have HANDLE_FLAG_INHERIT set.
static bool make_child_inheritable(io_t h) {
  return SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) != 0;
}
#endif

// ---------------------------------------------------------------------------
// Process spawn / kill
// ---------------------------------------------------------------------------
// Child stdio is THREE channels, and keeping them apart is a correctness
// requirement, not tidiness:
//   stdout = THE WIRE        (frames only — the launcher parses this)
//   stderr = diagnostics     (PHP warnings, and backend.php's `log` case)
//   stdin  = the wire, other direction
// An earlier version merged the child's stderr into stdout "so nothing is lost".
// That put diagnostics on the frame channel. Worse, PHP only routes CLI errors to
// stderr from 8.0 — PHP 7.x prints them to STDOUT (verified on both), so a single
// notice would have injected a bogus line mid-protocol. Diagnostics now go to our
// own log with a `[backend] ` prefix; the wire stays clean.
//
// `child_in`/`child_out`/`child_err` are the CHILD's ends (IO_BAD ×3 to spawn
// with no stdio wiring — used for the launcher, which must not hold our pipe ends
// open or the PHP backend would never see EOF).
static proc_t spawn_proc(const path_t &exe, const std::vector<std::string> &args,
                         io_t child_in, io_t child_out, io_t child_err,
                         const path_t &cwd) {
#ifdef _WIN32
  std::wstring cmd = L"\"" + exe + L"\"";
  for (size_t i = 0; i < args.size(); ++i)
    cmd += L" \"" + widen_(args[i]) + L"\"";
  STARTUPINFOW si;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  PROCESS_INFORMATION pi;
  memset(&pi, 0, sizeof pi);
  BOOL inherit = FALSE;
  DWORD flags = 0;
  if (child_in != IO_BAD || child_out != IO_BAD || child_err != IO_BAD) {
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = child_in;
    si.hStdOutput = child_out;
    si.hStdError = child_err; // NEVER child_out — see the note above
    inherit = TRUE;
  } else {
    flags = CREATE_NO_WINDOW;
  }
  if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, inherit, flags,
                      nullptr, cwd.empty() ? nullptr : cwd.c_str(), &si, &pi)) {
    logf_("[shell] CreateProcessW failed: %lu\n", GetLastError());
    return PROC_BAD;
  }
  CloseHandle(pi.hThread);
  return pi.hProcess;
#else
  pid_t pid = fork();
  if (pid < 0) {
    logf_("[shell] fork() failed: %s\n", strerror(errno));
    return PROC_BAD;
  }
  if (pid == 0) {
    if (!cwd.empty()) {
      if (chdir(cwd.c_str()) != 0) {
        std::string m = "[shell] chdir failed\n";
        (void)!write(2, m.data(), m.size());
      }
    }
    if (child_in != IO_BAD) dup2(child_in, 0);
    if (child_out != IO_BAD) dup2(child_out, 1);
    if (child_err != IO_BAD) dup2(child_err, 2);
    else if (child_out != IO_BAD) dup2(child_out, 2);
    // dup2 clears FD_CLOEXEC on the target, but the identical-fd case is a
    // no-op, so make sure 0/1/2 survive exec unconditionally.
    for (int fd = 0; fd <= 2; ++fd) {
      int f = fcntl(fd, F_GETFD);
      if (f >= 0) fcntl(fd, F_SETFD, f & ~FD_CLOEXEC);
    }
    if (child_in != IO_BAD && child_in > 2) close(child_in);
    if (child_out != IO_BAD && child_out > 2) close(child_out);
    if (child_err != IO_BAD && child_err > 2) close(child_err);
    std::vector<char *> av;
    av.push_back(const_cast<char *>(exe.c_str()));
    for (size_t i = 0; i < args.size(); ++i)
      av.push_back(const_cast<char *>(args[i].c_str()));
    av.push_back(nullptr);
    execv(exe.c_str(), av.data());
    std::string m = "[shell] execv failed\n";
    (void)!write(2, m.data(), m.size());
    _exit(127);
  }
  return pid;
#endif
}

static void kill_proc(proc_t p) {
  if (p == PROC_BAD) return;
#ifdef _WIN32
  TerminateProcess(p, 0);
  CloseHandle(p);
#else
  kill(p, SIGTERM);
  for (int i = 0; i < 50; ++i) {
    int st = 0;
    pid_t r = waitpid(p, &st, WNOHANG);
    if (r == p || r < 0) return;
    sleep_ms(10);
  }
  kill(p, SIGKILL);
  int st = 0;
  waitpid(p, &st, 0);
#endif
}

// ---------------------------------------------------------------------------
// Packaged-app mode (`--launch`)
// ---------------------------------------------------------------------------
// In dev the LAUNCHER spawns us (its `--typephp` mode) and hands us a pipe/socket
// name on the command line. A packaged app has no such parent: this exe is what
// the user double-clicks, so it takes the opposite — upstream-normal — direction.
// It creates the endpoint server and spawns the STOCK launcher with
// `<html> <endpoint> [title] [WxH] [version]`. That keeps the shipped launcher a
// byte-for-byte upstream build (no --typephp patch in the distribution), and
// --typephp stays a dev-only convenience for `tinyjs dev`.
//
// Per-app metadata comes from `<exe_dir>/<exe_stem>.conf` (one key=value per
// line, `#` comments, relative paths resolve against the exe dir):
//
//   html=frontend/index.html
//   title=My App
//   size=1100x760
//   version=0.1.0
//   icon=icon.png            # optional
//   app=app.exe              # optional; the compiled PHP backend
//   launcher=launcher.exe    # optional

static std::string trim_(const std::string &s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos) return "";
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

struct LaunchConf {
  std::string html = "frontend/index.html";
  std::string title = "tinyjs";
  std::string size = "960x640";
  std::string version = "0.0.0";
  std::string icon;     // optional
  std::string app;      // optional: the PHP backend, relative to the exe dir
  std::string launcher; // optional: relative to the exe dir
};

// Classify the backend binary by its first 2 bytes so the PHP side can report
// the TRUTH in sysinfo: "#!" = stock PHP CLI script (shebang), "MZ" = tpc AOT
// native PE. Unreadable/other = "unknown".
static std::string app_kind_of(const path_t &p) {
#ifdef _WIN32
  FILE *f = _wfopen(p.c_str(), L"rb");
#else
  FILE *f = fopen(p.c_str(), "rb");
#endif
  if (!f) return "unknown";
  unsigned char b[2] = {0, 0};
  size_t got = fread(b, 1, 2, f);
  fclose(f);
  if (got < 2) return "unknown";
  if (b[0] == '#' && b[1] == '!') return "stock";
  if (b[0] == 'M' && b[1] == 'Z') return "aot";
  return "unknown";
}

static LaunchConf read_conf(const path_t &path) {
  LaunchConf c;
#ifdef _WIN32
  FILE *f = _wfopen(path.c_str(), L"rb");
#else
  FILE *f = fopen(path.c_str(), "rb");
#endif
  if (!f) return c;
  std::string text;
  char b[1024];
  size_t got;
  while ((got = fread(b, 1, sizeof(b), f)) > 0)
    text.append(b, got);
  fclose(f);
  size_t pos = 0;
  while (pos < text.size()) {
    size_t nl = text.find('\n', pos);
    std::string line = trim_(text.substr(
        pos, nl == std::string::npos ? std::string::npos : nl - pos));
    pos = (nl == std::string::npos) ? text.size() : nl + 1;
    if (line.empty() || line[0] == '#') continue;
    size_t eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string k = trim_(line.substr(0, eq)), v = trim_(line.substr(eq + 1));
    if (k == "html") c.html = v;
    else if (k == "title") c.title = v;
    else if (k == "size") c.size = v;
    else if (k == "version") c.version = v;
    else if (k == "icon") c.icon = v;
    else if (k == "app") c.app = v;
    else if (k == "launcher") c.launcher = v;
  }
  return c;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
#ifdef _WIN32
  const char *logpath = std::getenv("TYPEPHP_SHELL_LOG");
  g_log = logpath ? std::fopen(logpath, "a") : stdout;
#else
  // Writes to a socket whose peer is gone must not kill the proxy.
  signal(SIGPIPE, SIG_IGN);
  const char *logpath = getenv("TYPEPHP_SHELL_LOG");
  g_log = logpath ? fopen(logpath, "a") : stdout;
#endif

  // No args = packaged app launched by double-click; `--launch [conf]` says so
  // explicitly. The dev path ALWAYS passes an endpoint name as argv[1] (the
  // launcher spawns us with it), so argc==1 can never mean "dev".
  const bool launch_mode =
      argc == 1 || (argc > 1 && std::strcmp(argv[1], "--launch") == 0);
  const path_t base = dir_of(exe_path());
  LaunchConf conf;
  if (launch_mode) {
    path_t confPath;
    if (argc > 2) {
      confPath = widen_(argv[2]);
    } else {
      confPath = base + stem_of(exe_path()) + lit(".conf");
    }
    conf = read_conf(confPath);
    logf_("[shell] launch mode conf=%s html=%s title=%s size=%s\n",
          narrow_(confPath).c_str(), conf.html.c_str(), conf.title.c_str(),
          conf.size.c_str());
  }

  std::string name;
  if (launch_mode) {
    // We are the parent here, so we pick the endpoint name ourselves.
#ifdef _WIN32
    name = "\\\\.\\pipe\\tinyjs-typephp-" +
           std::to_string((unsigned long)GetCurrentProcessId());
#else
    name = narrow_(base) + "app.sock";
    // Two measured reasons to move the endpoint off the app dir; the log says
    // which one fired.
    //   1. sun_path holds 107 usable bytes, so a deeply nested bundle simply
    //      cannot fit "<dir>/app.sock" (bug #15; re-measured 2026-09-27: 113 B
    //      for this repo's own bundle dir).
    //   2. APPLE ONLY: a LaunchServices-spawned process that creates its FIRST
    //      new file on a volume other than the boot volume blocks inside
    //      open(O_CREAT) — no errno, no timeout — until the user answers
    //      kTCCServiceSystemPolicyRemovableVolumes, and that request can sit
    //      pending forever (bug #21, measured 2026-09-27 in
    //      experiments/ls-bind-probe: 786/786 samples in __open at the plain
    //      file step, so it is NOT socket-specific; the old "__bind" stack was
    //      just where the shim happened to write first). Reading the bundle is
    //      unaffected, so relocating the socket is enough to make a .app on an
    //      external volume launch. Linux keeps the socket next to the bundle:
    //      there is no such gate there, and the tier evidence expects it.
    const size_t sun_cap = sizeof(((struct sockaddr_un *)nullptr)->sun_path);
    const char *why = nullptr;
    if (name.size() >= sun_cap) why = "sun_path full";
#if defined(__APPLE__)
    else if (!on_boot_volume(narrow_(base))) why = "app dir is not on the boot volume";
#endif
    if (why) {
      std::string fb = tmp_endpoint((long)getpid());
      if (fb.size() < sun_cap) {
        logf_("[shell] endpoint moved off the app dir (%s): %s -> %s\n", why,
              name.c_str(), fb.c_str());
        name = fb;
      } else {
        logf_("[shell] no endpoint fallback fits sun_path (%zu): %s\n",
              fb.size(), fb.c_str());
      }
    }
#endif
  } else if (argc > 1) {
    name = argv[1];
  } else {
    std::string pb;
    if (env_str("TYPEPHP_PIPE_NAME", pb)) {
#ifdef _WIN32
      // Bare name (no backslashes) — handy for testing from shells that mangle
      // backslashes; we add the \\.\pipe\ prefix here.
      name = "\\\\.\\pipe\\" + pb;
#else
      name = pb;
#endif
    } else {
#ifdef _WIN32
      name = "\\\\.\\pipe\\tinyjs-typephp-test";
#else
      name = "/tmp/tinyjs-typephp-test.sock";
#endif
    }
  }

  // Real PHP backend binary: conf `app=` (launch mode) > env TYPEPHP_APP >
  // "<exe_dir>/app.exe".
  path_t app;
  {
    path_t from_env;
    if (launch_mode && !conf.app.empty())
      app = resolve(base, widen_(conf.app));
    else if (env_path("TYPEPHP_APP", from_env))
      app = from_env;
    else
      app = base + lit("app.exe");
  }

  // Tell the backend what KIND of runtime it is (see app_kind_of). The child
  // inherits our environment (CreateProcessW passes nullptr; POSIX fork+execv
  // likewise), so a parent-side set lands in $_SERVER['TYPEPHP_APP_KIND'].
  std::string app_kind = app_kind_of(app);
#ifdef _WIN32
  SetEnvironmentVariableW(L"TYPEPHP_APP_KIND", widen_(app_kind).c_str());
#else
  setenv("TYPEPHP_APP_KIND", app_kind.c_str(), 1);
#endif

  // Working directory for the PHP backend. The launcher deliberately chdirs to
  // the temp dir before spawning us (it must not pin the app folder — a cwd
  // handle there blocks the auto-updater's directory swap), and a PHP backend
  // with getcwd()==temp breaks every relative path. The CLI therefore tells us
  // the project dir in TYPEPHP_CWD; honour it, else inherit the launcher's cwd.
  path_t wd;
  if (!env_path("TYPEPHP_CWD", wd) && launch_mode)
    wd = base; // packaged app: the app root is the exe's own folder

  logf_("[shell] transport=%s pipe=%s app=%s app_kind=%s cwd=%s\n",
#ifdef _WIN32
        "named-pipe",
#else
        "unix-socket",
#endif
        name.c_str(), narrow_(app).c_str(), app_kind.c_str(),
        wd.empty() ? "(inherit)" : narrow_(wd).c_str());

  // --- child stdio pipes ---
  //   stdin  : child reads r1, WE write w1
  //   stdout : child writes w2, WE read r2   <- the FRAME channel
  //   stderr : child writes w3, WE read r3   <- diagnostics only, never forwarded
  io_t r1 = IO_BAD, w1 = IO_BAD, r2 = IO_BAD, w2 = IO_BAD, r3 = IO_BAD, w3 = IO_BAD;
  if (!make_pipe(r1, w1) || !make_pipe(r2, w2) || !make_pipe(r3, w3)) {
    logf_("[shell] pipe() failed\n");
    return 1;
  }
  io_t hWriteStdin = w1, cStdin = r1; // parent writes -> child's stdin
  io_t hReadStdout = r2, cStdout = w2; // child's stdout -> parent reads (frames)
  io_t hReadStderr = r3, cStderr = w3; // child's stderr -> parent reads (log only)
#ifdef _WIN32
  if (!make_child_inheritable(cStdin) || !make_child_inheritable(cStdout) ||
      !make_child_inheritable(cStderr)) {
    logf_("[shell] SetHandleInformation failed: %lu\n", GetLastError());
    return 1;
  }
#endif

  // --- launcher-facing endpoint (NOT inherited by the child) ---
  io_t srv = io_open_endpoint(name);
  if (srv == IO_BAD) {
    logf_("[shell] endpoint create failed for %s\n", name.c_str());
    return 1;
  }

  // --- spawn the PHP backend with inherited stdio ---
  proc_t php = spawn_proc(app, std::vector<std::string>(), cStdin, cStdout, cStderr, wd);
  if (php == PROC_BAD) {
    logf_("[shell] could not spawn backend %s\n", narrow_(app).c_str());
    return 1;
  }
  io_close(cStdin);
  io_close(cStdout);
  io_close(cStderr);

  // Packaged mode: spawn the STOCK launcher as our endpoint client, in the
  // upstream (normal) direction — `launcher <html> <endpoint> [title] [WxH]
  // [version]`. It must NOT inherit our child-stdio pipe ends, or the PHP
  // backend would never see EOF.
  proc_t launcher = PROC_BAD;
  if (launch_mode) {
    path_t lexe = conf.launcher.empty() ? (base + lit("launcher.exe"))
                                        : resolve(base, widen_(conf.launcher));
    path_t html = resolve(base, widen_(conf.html));
    if (!conf.icon.empty()) {
      path_t ic = resolve(base, widen_(conf.icon));
#ifdef _WIN32
      SetEnvironmentVariableW(L"TINYJS_ICON", ic.c_str());
#else
      setenv("TINYJS_ICON", ic.c_str(), 1);
#endif
    }
    std::vector<std::string> largs;
    largs.push_back(narrow_(html));
    largs.push_back(name);
    largs.push_back(conf.title);
    largs.push_back(conf.size);
    largs.push_back(conf.version);
    launcher = spawn_proc(lexe, largs, IO_BAD, IO_BAD, IO_BAD, path_t());
    if (launcher == PROC_BAD) {
      logf_("[shell] could not spawn launcher %s\n", narrow_(lexe).c_str());
      kill_proc(php);
      return 1;
    }
    logf_("[shell] spawned launcher %s\n", narrow_(lexe).c_str());
  }

  // Wait for the launcher to connect — and give up if the launcher we spawned
  // died before it ever got that far (#25).
  bool launcher_died = false;
  io_t ep = io_accept_watching(srv, launcher, &launcher_died);
  if (ep == IO_BAD) {
    logf_(launcher_died ? "[shell] launcher never connected, aborting\n"
                        : "[shell] connect failed, aborting\n");
    kill_proc(php);
    // `launcher_died` means we already reaped it in the accept loop.
    if (!launcher_died) kill_proc(launcher);
    io_close(srv);
    io_cleanup_endpoint(name);
    return 1;
  }
  logf_("[shell] launcher connected\n");

  // --- bidirectional, NON-BLOCKING polling floor ---
  //
  // A strict request/response pump (read a launcher frame -> wait for its RET)
  // deadlocks: the launcher also sends *notification* frames (WINSTATE, MENU, …)
  // that the backend never answers with a RET, so waiting for one blocks the
  // proxy forever while the launcher's next CALL sits unread in the pipe.
  //
  // Instead we poll both directions and forward whatever bytes are available.
  // Line framing is reassembled per direction, so partial reads are harmless.
  // No threads (avoids the named-pipe write deadlock seen with the earlier
  // two-thread version) and no per-request coupling.
  std::string to_backend, to_launcher; // partial lines per direction
  auto pump = [&](io_t hIn, std::string &partial, io_t hOut, const char *tag,
                  bool *closed) -> bool {
    char tmp[4096];
    size_t got = 0;
    if (!io_read_avail(hIn, tmp, sizeof(tmp), &got))
      return false; // peer gone
    if (got == 0)
      return true; // nothing yet
    partial.append(tmp, got);
    size_t nl;
    while ((nl = partial.find('\n')) != std::string::npos) {
      std::string line = partial.substr(0, nl);
      partial.erase(0, nl + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      logf_("[shell] %s: %s\n", tag, line.c_str());
      if (!io_write_line(hOut, line)) {
        *closed = true;
        return false;
      }
    }
    return true;
  };

  // stderr is NOT forwarded -- it is drained and logged. Two reasons:
  //   1. A pipe that nobody reads fills up (~64KB) and the writer blocks forever,
  //      so a chatty backend would wedge itself mid-protocol.
  //   2. On several PHP builds *diagnostics* (notices, warnings, deprecations)
  //      go to stderr instead of stdout, and PHP's routing changed between 7.x
  //      and 8.x. Folding stderr into the frame channel therefore turns a stray
  //      notice into a malformed frame at a random point in the conversation.
  //      Keeping the channels apart makes that structurally impossible.
  std::string be_err; // partial stderr line
  auto drain_stderr = [&]() {
    // Drain everything that is available *now*, up to a bound. One non-blocking
    // read per tick would cap throughput at sizeof(tmp) per millisecond, which a
    // burst (a backtrace, a var_dump) can outrun; the pipe would then back up
    // towards the 64 KB blocking threshold this drain exists to avoid. The spin
    // is bounded so a permanently-noisy backend cannot starve the frame pump.
    char tmp[1024];
    size_t got = 0;
    for (int spin = 0; spin < 64; ++spin) {
      // A false return means the read end is no longer usable.
      if (!io_read_avail(hReadStderr, tmp, sizeof(tmp), &got) || got == 0) break;
      be_err.append(tmp, got);
    }
    size_t nl;
    while ((nl = be_err.find('\n')) != std::string::npos) {
      std::string line = be_err.substr(0, nl);
      be_err.erase(0, nl + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) logf_("[shell] backend stderr: %s\n", line.c_str());
    }
    // A partial final line without a newline is held until more arrives, but an
    // unbounded buffer would be a leak if the backend never emits '\n'. Cap it.
    if (be_err.size() > 8192) {
      logf_("[shell] backend stderr: %s\n", be_err.c_str());
      be_err.clear();
    }
  };

  bool closed = false;
  for (;;) {
    if (!pump(ep, to_backend, hWriteStdin, "L->P", &closed)) {
      if (closed) {
        logf_("[shell] write to backend failed\n");
        goto done;
      }
      logf_("[shell] launcher closed\n");
      break;
    }
    if (!pump(hReadStdout, to_launcher, ep, "P->L", &closed)) {
      if (closed) {
        logf_("[shell] write to launcher failed\n");
        goto done;
      }
      logf_("[shell] backend closed\n");
      break;
    }
    drain_stderr();
    sleep_ms(1); // idle tick; the pump is cheap and latency stays ~1ms
  }

done:
  io_close(hWriteStdin);
  logf_("[shell] closing\n");
  kill_proc(php);
  // Best-effort final sweep for anything the backend wrote between our last tick
  // and its death. This is *not* the mechanism that matters: the in-loop drain
  // runs every idle tick (~1 ms) and is what actually keeps the pipe empty. Nor
  // is it guaranteed to succeed -- on Windows the pipe can report itself broken
  // the moment the writer disappears, in which case this reads nothing and any
  // not-yet-drained bytes are simply lost. Treat it as a bonus, not a promise.
  drain_stderr();
  io_close(hReadStderr);
  // Whichever side went away first, the other must not linger: a dead PHP
  // backend would otherwise leave an empty window on screen.
  kill_proc(launcher);
  io_close(ep);
  if (ep != srv) io_close(srv);
  io_cleanup_endpoint(name);
  logf_("[shell] done\n");
  return 0;
}
