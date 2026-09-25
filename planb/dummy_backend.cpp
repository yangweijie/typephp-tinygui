// Minimal named-pipe SERVER that mimics what the aot-compiler PHP backend will
// do in TypePHP mode: it receives the pipe name as argv[1], creates the pipe
// server, waits for the launcher to connect, then answers CALL frames with RET
// frames (tinyjsapp protocol: CALL <id> <json> / RET <id> <status> <json>).
//
// Used only by spawn_bridge_test.cpp to prove the spawn+connect+protocol path
// headlessly. The real backend is aot-compiler's backend.exe (see backend.php).

#include <windows.h>
#include <string>
#include <cstdio>

static std::wstring widen(const std::string &s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w;
  w.resize(n);
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
  return w;
}

int main(int argc, char **argv) {
  std::string name =
      (argc > 1) ? argv[1] : "\\\\.\\pipe\\tinyjs-typephp-test";
  std::printf("[backend] creating pipe server: %s\n", name.c_str());

  HANDLE h = CreateNamedPipeW(
      widen(name).c_str(),
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      1, 4096, 4096, 0, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    std::fprintf(stderr, "[backend] CreateNamedPipeW failed: %lu\n",
                 GetLastError());
    return 1;
  }
  if (!ConnectNamedPipe(h, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) {
    std::fprintf(stderr, "[backend] ConnectNamedPipe failed: %lu\n",
                 GetLastError());
    CloseHandle(h);
    return 1;
  }
  std::printf("[backend] launcher connected\n");

  char buf[4096];
  DWORD n = 0;
  std::string acc;
  while (ReadFile(h, buf, sizeof(buf) - 1, &n, nullptr) && n > 0) {
    acc.append(buf, n);
    size_t nl;
    while ((nl = acc.find('\n')) != std::string::npos) {
      std::string line = acc.substr(0, nl);
      acc.erase(0, nl + 1);
      if (line.rfind("CALL", 0) == 0) {
        // CALL <id> <json>
        size_t s1 = line.find(' ');
        size_t s2 = line.find(' ', s1 + 1);
        std::string id = line.substr(s1 + 1, s2 - (s1 + 1));
        std::string json = line.substr(s2 + 1);
        std::string reply = "RET " + id + " 0 {\"ok\":true,\"echo\":" + json + "}\n";
        DWORD w = 0;
        WriteFile(h, reply.c_str(), (DWORD)reply.size(), &w, nullptr);
        std::printf("[backend] handled CALL %s -> RET\n", id.c_str());
        // Quit after one round trip so the test can finish.
        CloseHandle(h);
        return 0;
      }
    }
  }
  CloseHandle(h);
  return 0;
}
