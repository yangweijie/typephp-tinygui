/* mock_launcher.c — AF_UNIX client standing in for launcher-linux.
 *
 * Same job as mock_launcher.py: connect to the shim's socket, read the backend's
 * READY banner, then interleave NOTIFICATION frames (WINSTATE / SYS theme — which
 * the backend never answers) with CALL frames, and require `RET <id> 0 …` for each
 * one while counting the EVAL@* window frames that must arrive first.
 *
 * Why a second client exists, in C
 * ---------------------------------
 * Under **Cygwin**, CPython's AF_UNIX sockets do NOT interoperate with native
 * Cygwin AF_UNIX sockets — they appear to live on two different planes:
 *
 *   C server  + C client        -> accept() OK          (works)
 *   C server  + Python client   -> accept() ECONNABORTED (errno 113)
 *   Python srv + C client       -> accept() "OK" but reads UNRELATED GARBAGE
 *                                  (the C client even gets ECONNREFUSED)
 *   Python srv + Python client  -> works
 *
 * So a Python launcher simply cannot talk to our C shim on Cygwin, and the kit
 * would report a shim failure that is really a client-runtime artefact. The real
 * launcher is C++ (`launcher-linux.cc`), so the C client is also the more faithful
 * stand-in: it exercises the same libc socket calls the launcher makes.
 *
 * Keep the protocol logic in sync with mock_launcher.py, which
 * selftest_fixtures.py uses as the cross-platform protocol oracle. (The optional
 * MOCK_LOG_CALL step below is not mirrored there — it is off by default and only
 * the C client needs it, because only the C client can drive the Cygwin shim.)
 *
 * Usage: mock_launcher <socket-path> [n_calls]
 *        MOCK_LAUNCHER_ARGV=launcher mock_launcher <html> <socket> <title> <WxH> <ver>
 *        MOCK_LOG_CALL=1 mock_launcher <socket-path>   # also probe tiny.log()
 * Exit:  0 = protocol clean, 1 = mismatch/timeout, 2 = usage.
 *
 * The second form mirrors the argv the shim hands the REAL launcher in packaged
 * (`--launch`) mode — `launcher <html> <endpoint> [title] [WxH] [version]` — which
 * is the only way to exercise the shipping path without a GTK build. Since the
 * shim controls those arguments we cannot add a flag to them, so the layout is
 * selected by an environment variable instead (env is inherited by the spawned
 * launcher on both platforms).
 */
#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1 /* visibility macro; see the note in backend_shell.cpp */
#endif

#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define RBUF 65536
#define TIMEOUT_MS 15000

static int g_fd = -1;
static char g_buf[RBUF];
static size_t g_len = 0;

/* One line, NUL-terminated, with a stray trailing '\r' popped (the shim does the
 * same when it reassembles lines). Returns NULL on timeout or EOF. */
static char *read_line(int timeout_ms) {
  static char line[RBUF];
  for (;;) {
    char *nl = memchr(g_buf, '\n', g_len);
    if (nl) {
      size_t n = (size_t)(nl - g_buf);
      size_t rest = g_len - n - 1;
      if (n >= sizeof line) n = sizeof line - 1;
      memcpy(line, g_buf, n);
      line[n] = 0;
      if (n > 0 && line[n - 1] == '\r') line[n - 1] = 0;
      memmove(g_buf, nl + 1, rest);
      g_len = rest;
      return line;
    }
    struct pollfd p = {g_fd, POLLIN, 0};
    int r;
    do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
    if (r <= 0) return NULL; /* timeout, or poll error */
    ssize_t got = read(g_fd, g_buf + g_len, sizeof g_buf - g_len);
    if (got < 0) {
      if (errno == EINTR) continue;
      return NULL;
    }
    if (got == 0) return NULL; /* EOF */
    g_len += (size_t)got;
  }
}

static int send_line(const char *fmt, ...) {
  char out[8192];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(out, sizeof out, fmt, ap);
  va_end(ap);
  if (n < 0 || (size_t)n >= sizeof out) return -1;
  out[n++] = '\n';
  size_t off = 0;
  while (off < (size_t)n) {
    ssize_t w = write(g_fd, out + off, (size_t)n - off);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    off += (size_t)w;
  }
  return 0;
}

int main(int argc, char **argv) {
  /* Two argv layouts; see the header comment. */
  const char *layout = getenv("MOCK_LAUNCHER_ARGV");
  int launcher_layout = (layout && strcmp(layout, "launcher") == 0);
  int argi = launcher_layout ? 2 : 1; /* <html> <socket> … vs <socket> [n] */
  if (argc <= argi) {
    printf("usage: mock_launcher <socket-path> [n_calls]\n");
    printf("       MOCK_LAUNCHER_ARGV=launcher mock_launcher "
           "<html> <socket> <title> <WxH> <ver>\n");
    return 2;
  }
  const char *path = argv[argi];
  int n_calls;
  if (launcher_layout) {
    const char *e = getenv("N_CALLS");
    n_calls = e ? atoi(e) : 5;
  } else {
    n_calls = argc > 2 ? atoi(argv[2]) : 5;
  }
  /* In launcher mode our stdout is /dev/null (the shim spawns the launcher with
   * NO stdio, exactly like bInheritHandles=FALSE on Windows), so anything we need
   * to assert on has to travel as a FRAME. Remember the arguments we were given
   * and report them once connected. */
  const char *l_argv[5] = {0, 0, 0, 0, 0};
  if (launcher_layout) {
    for (int i = 0; i < 5; i++)
      l_argv[i] = (argc > i + 1) ? argv[i + 1] : 0;
  }

  g_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (g_fd < 0) {
    printf("FAIL: socket(AF_UNIX): %s\n", strerror(errno));
    return 1;
  }
  struct sockaddr_un a;
  memset(&a, 0, sizeof a);
  a.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a.sun_path) {
    printf("FAIL: socket path too long (%zu >= %zu)\n", strlen(path),
           sizeof a.sun_path);
    return 1;
  }
  strncpy(a.sun_path, path, sizeof a.sun_path - 1);
  if (connect(g_fd, (struct sockaddr *)&a, sizeof a) != 0) {
    printf("FAIL: connect(%s): %s\n", path, strerror(errno));
    return 1;
  }
  printf("connected to %s\n", path);
  fflush(stdout);

  /* 1. the backend's startup banner has to survive the pump */
  char *first = read_line(TIMEOUT_MS);
  if (!first || strcmp(first, "READY") != 0) {
    if (first) printf("FAIL: expected the READY banner first, got '%s'\n", first);
    else       printf("FAIL: expected the READY banner first, got None\n");
    return 1;
  }
  printf("banner ok: 'READY'\n");

  /* In packaged (launch) mode, prove the shim parsed <exe_stem>.conf correctly:
   * the values it resolved end up as our argv, so echo them back as ONE frame.
   * The shim logs every frame it forwards, so its log becomes the assertion
   * source. (This is the only way to observe them — our stdout is discarded.) */
  if (launcher_layout) {
    if (send_line("SYS launch-argv html=%s title=%s size=%s ver=%s",
                  l_argv[0] ? l_argv[0] : "-", l_argv[2] ? l_argv[2] : "-",
                  l_argv[3] ? l_argv[3] : "-", l_argv[4] ? l_argv[4] : "-") != 0) {
      printf("FAIL: could not send the launch-argv frame\n");
      return 1;
    }
    printf("reported the launch argv as a frame\n");
  }

  /* 2. interleave notifications with calls — the deadlock regression test */
  int evals = 0, rets = 0;
  for (int i = 0; i < n_calls; i++) {
    char fid[32];
    snprintf(fid, sizeof fid, "id%02d", i);

    send_line("WINSTATE main {\"fullscreen\":false,\"focused\":true}");
    send_line("SYS theme light");
    send_line("CALL %s [\"{\\\"method\\\":\\\"ping\\\",\\\"params\\\":{}}\","
              "\"file://\"]", fid);

    for (;;) {
      char *line = read_line(TIMEOUT_MS);
      if (!line) {
        printf("FAIL: peer closed/timed out waiting for RET %s "
               "(%d/%d rets, %d evals) — pump stalled?\n",
               fid, rets, n_calls, evals);
        return 1;
      }
      if (strncmp(line, "EVAL", 4) == 0) {
        evals++;
        continue;
      }
      char want[48], want_ok[48];
      snprintf(want, sizeof want, "RET %s ", fid);
      if (strncmp(line, want, strlen(want)) == 0) {
        snprintf(want_ok, sizeof want_ok, "RET %s 0 ", fid);
        if (strncmp(line, want_ok, strlen(want_ok)) != 0) {
          printf("FAIL: RET for %s carried a non-zero status: '%s'\n", fid, line);
          return 1;
        }
        rets++;
        break;
      }
      printf("FAIL: unexpected frame while waiting for %s: '%s'\n", fid, line);
      return 1;
    }
  }
  printf("calls ok: %d CALL -> %d RET, %d EVAL frames pushed ahead of them\n",
         rets, rets, evals);

  /* 2b. Optional: exercise the one backend method that writes to STDERR.
   * `tiny.log(msg)` reaches dispatch()'s `log` case, which does
   * `fwrite(STDERR, '[php-backend] …')`. That is the real-world counterpart of
   * mock_backend_noisy.py's synthetic decoy: if the shim ever merged stderr into
   * the frame channel, this line would land in the middle of the protocol as a
   * bogus frame. Off by default so the standard runs stay byte-comparable.
   * The RET is asserted exactly like any other call. */
  if (getenv("MOCK_LOG_CALL")) {
    const char *fid = "log0";
    send_line("CALL %s [\"{\\\"method\\\":\\\"log\\\",\\\"params\\\":"
              "{\\\"msg\\\":\\\"stderr-probe\\\"}}\",\"file://\"]", fid);
    for (;;) {
      char *line = read_line(TIMEOUT_MS);
      if (!line) {
        printf("FAIL: peer closed/timed out waiting for RET %s (the log call)\n",
               fid);
        return 1;
      }
      if (strncmp(line, "EVAL", 4) == 0) { evals++; continue; }
      char want[48], want_ok[48];
      snprintf(want, sizeof want, "RET %s ", fid);
      if (strncmp(line, want, strlen(want)) == 0) {
        snprintf(want_ok, sizeof want_ok, "RET %s 0 ", fid);
        if (strncmp(line, want_ok, strlen(want_ok)) != 0) {
          printf("FAIL: RET for %s carried a non-zero status: '%s'\n", fid, line);
          return 1;
        }
        rets++;
        break;
      }
      printf("FAIL: unexpected frame while waiting for %s: '%s'\n", fid, line);
      return 1;
    }
    printf("log call ok: RET %s 0, %d CALL -> %d RET total\n", fid, rets, rets);
  }

  /* 3. closing our end must make the shim finish cleanly (it logs
   *    "launcher closed" and exits 0) rather than being terminated. */
  close(g_fd);
  printf("closed the connection; the shim should now shut down on its own\n");
  return 0;
}
