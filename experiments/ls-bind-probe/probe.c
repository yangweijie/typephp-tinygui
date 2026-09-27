// ---------------------------------------------------------------------------
// ls-bind-probe — does LaunchServices (not our shim) block file/socket
// creation on a non-boot volume? Three ordered steps, each logged before and
// after so the log itself names the step that never returns:
//
//   [1] create+write a REGULAR file next to the executable
//   [2] bind() an AF_UNIX socket next to the executable
//   [3] bind() an AF_UNIX socket in /tmp
//
// Run the same binary two ways (direct exec, and `open` = LaunchServices) from
// two locations (boot volume, external HFS+ volume). The 2x2 table is the
// answer; no code from shim/ is involved, so a hang here cannot be our bug.
//
// Log lines go to /tmp/ls-bind-probe.log (append, fsync per line) because a
// GUI-launched process has no stderr anyone will read.
// ---------------------------------------------------------------------------
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>

static int logfd = -1;
static const char *TAG = "run";

static void logf_(const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  __builtin_va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  __builtin_va_end(ap);
  if (n < 0) return;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  char line[1200];
  // Every line carries the scenario tag, so `grep <tag> log` isolates one run
  // — the four scenarios are interleaved in one file on purpose (ordering is
  // itself evidence about when a hang started).
  int m = snprintf(line, sizeof line, "%c %ld.%03ld %-16s %s\n", '>',
                   (long)ts.tv_sec, ts.tv_nsec / 1000000, TAG, buf);
  if (m > 0) {
    if (logfd >= 0) {
      ssize_t w = write(logfd, line, (size_t)m);
      (void)w;
      fsync(logfd);
    }
    fputs(line, stderr);
    fflush(stderr);
  }
}

static void exe_dir(char *out, size_t cap) {
  char path[4096];
  uint32_t sz = sizeof path;
  if (_NSGetExecutablePath(path, &sz) != 0) {
    snprintf(out, cap, "?");
    return;
  }
  char real[4096];
  if (!realpath(path, real)) {
    snprintf(out, cap, "?");
    return;
  }
  char *slash = strrchr(real, '/');
  if (!slash) {
    snprintf(out, cap, "?");
    return;
  }
  *slash = '\0';
  snprintf(out, cap, "%s", real);
}

static int bind_to(const char *name, socklen_t *len_out) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  if (strlen(name) >= sizeof addr.sun_path) {
    logf_("path too long (%zu): %s", strlen(name), name);
    close(fd);
    return -1;
  }
  strncpy(addr.sun_path, name, sizeof addr.sun_path - 1);
  *len_out = (socklen_t)(sizeof(sa_family_t) + strlen(name) + 1);
  unlink(name);
  if (bind(fd, (struct sockaddr *)&addr, *len_out) != 0) {
    logf_("bind failed errno=%d (%s) at %s", errno, strerror(errno), name);
    close(fd);
    return -1;
  }
  if (listen(fd, 1) != 0) {
    logf_("listen failed errno=%d at %s", errno, name);
    close(fd);
    return -1;
  }
  return fd;
}

int main(int argc, char **argv) {
  if (argc > 1) TAG = argv[1];
  const char *tag = TAG;
  logfd = open("/tmp/ls-bind-probe.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
  char dir[4096];
  exe_dir(dir, sizeof dir);
  pid_t pid = getpid();
  logf_("== %s pid=%d uid=%d exe_dir=%s", tag, (int)pid, (int)getuid(), dir);

  // [1] regular file, next to the executable
  char reg[4200];
  snprintf(reg, sizeof reg, "%s/probe.txt", dir);
  logf_("[1] begin create regular file %s", reg);
  int rf = open(reg, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (rf >= 0) {
    ssize_t w = write(rf, "x\n", 2);
    fsync(rf);
    close(rf);
    logf_("[1] ok wrote=%zd", w);
  } else {
    logf_("[1] failed errno=%d (%s)", errno, strerror(errno));
  }

  // [2] AF_UNIX socket, next to the executable
  char sv[4200];
  snprintf(sv, sizeof sv, "%s/probe.sock", dir);
  logf_("[2] begin bind AF_UNIX in exe_dir %s (sun_path used %zu B)", sv,
        strlen(sv));
  socklen_t len = 0;
  int s2 = bind_to(sv, &len);
  logf_("[2] %s", s2 >= 0 ? "ok" : "not ok");

  // [3] AF_UNIX socket in /tmp (always the boot volume)
  char st[128];
  snprintf(st, sizeof st, "/tmp/ls-bind-probe-%d.sock", (int)pid);
  logf_("[3] begin bind AF_UNIX in /tmp %s", st);
  int s3 = bind_to(st, &len);
  logf_("[3] %s", s3 >= 0 ? "ok" : "not ok");

  if (s2 >= 0) { close(s2); unlink(sv); }
  if (s3 >= 0) { close(s3); unlink(st); }
  logf_("== %s done", tag);
  if (logfd >= 0) close(logfd);
  return 0;
}
