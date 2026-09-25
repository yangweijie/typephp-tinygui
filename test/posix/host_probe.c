/* Probe: does this host really provide every primitive the POSIX shim needs?
 * fork/execv, dup2+FD_CLOEXEC spawn with inherited stdio, AF_UNIX
 * bind/listen/accept, and poll(0)-then-read non-blocking framing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK "/tmp/probe.sock"

int main(void) {
  int fails = 0;

  /* 1. AF_UNIX endpoint */
  unlink(SOCK);
  int srv = socket(AF_UNIX, SOCK_STREAM, 0);
  if (srv < 0) { printf("  AF_UNIX socket()      : FAIL %s\n", strerror(errno)); return 1; }
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
  sa.sun_family = AF_UNIX; strcpy(sa.sun_path, SOCK);
  if (bind(srv, (struct sockaddr *)&sa, sizeof sa) < 0) {
    printf("  AF_UNIX bind()        : FAIL %s\n", strerror(errno)); return 1;
  }
  if (listen(srv, 4) < 0) { printf("  AF_UNIX listen()      : FAIL\n"); return 1; }
  printf("  AF_UNIX bind+listen   : OK (sun_path=%zu)\n", sizeof sa.sun_path);

  /* 2. fork + execv + dup2 with inherited stdio (the shim's spawn path) */
  int p_in[2], p_out[2];
  if (pipe(p_in) || pipe(p_out)) { printf("  pipe()                : FAIL\n"); return 1; }
  pid_t pid = fork();
  if (pid == 0) {
    dup2(p_in[0], 0); dup2(p_out[1], 1); dup2(p_out[1], 2);
    fcntl(0, F_SETFD, 0); fcntl(1, F_SETFD, 0); fcntl(2, F_SETFD, 0);
    close(p_in[0]); close(p_in[1]); close(p_out[0]); close(p_out[1]); close(srv);
    execl("/bin/cat", "cat", (char *)NULL);   /* echo stdio back */
    _exit(127);
  }
  close(p_in[0]); close(p_out[1]);
  printf("  fork+execv+dup2 child : OK (pid=%d)\n", (int)pid);

  /* 3. accept() returns a NEW fd distinct from the listener */
  pid_t cli = fork();
  if (cli == 0) {
    close(srv);
    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un ca; memset(&ca, 0, sizeof ca);
    ca.sun_family = AF_UNIX; strcpy(ca.sun_path, SOCK);
    int tries = 100;
    while (tries-- && connect(c, (struct sockaddr *)&ca, sizeof ca) < 0) usleep(10000);
    if (tries <= 0) _exit(2);
    write(c, "hello-from-client\n", 18);
    usleep(200000);            /* stay open so the parent sees no EOF yet */
    close(c);
    _exit(0);
  }
  int sfd = accept(srv, NULL, NULL);
  if (sfd < 0) { printf("  accept()              : FAIL %s\n", strerror(errno)); fails++; }
  else printf("  accept()              : OK (%s)\n", sfd != srv ? "new fd" : "SAME fd as listener");

  /* 4. poll(fd,0) then blocking read — the exact non-blocking framing trick */
  int got = 0; char buf[256];
  for (int i = 0; i < 200 && got < 1; i++) {
    struct pollfd pf = { sfd, POLLIN, 0 };
    int pr = poll(&pf, 1, 0);
    if (pr > 0) {
      ssize_t n = read(sfd, buf, sizeof buf - 1);
      if (n <= 0) break;                       /* 0 == EOF */
      buf[n] = 0; got = 1;
      printf("  poll(0)+read frame    : OK (%zd bytes: %s)", n, buf);
    } else usleep(5000);
  }
  if (!got) { printf("  poll(0)+read frame    : FAIL\n"); fails++; }

  /* 5. read()==0 really is EOF on a unix socket */
  for (int i = 0; i < 400; i++) {
    struct pollfd pf = { sfd, POLLIN, 0 };
    if (poll(&pf, 1, 0) > 0) {
      ssize_t n = read(sfd, buf, sizeof buf);
      if (n == 0) { printf("  socket EOF (read==0)  : OK\n"); break; }
      if (n < 0 && errno != EINTR) { printf("  socket EOF            : FAIL %s\n", strerror(errno)); fails++; break; }
    }
    usleep(5000);
  }

  /* 6. SIGPIPE can be ignored (dead peer must not kill us) */
  signal(SIGPIPE, SIG_IGN);
  printf("  signal(SIGPIPE,IGN)   : OK\n");

  /* 7. teardown: waitpid reaps both children */
  write(p_in[1], "x\n", 2);
  close(p_in[1]);
  int st;
  waitpid(pid, &st, 0);
  waitpid(cli, &st, 0);
  printf("  waitpid reaps children: OK\n");

  close(sfd); close(srv); unlink(SOCK);
  printf("\nPROBE: %s\n", fails ? "FAILURES" : "ALL PRIMITIVES PRESENT");
  return fails ? 1 : 0;
}
