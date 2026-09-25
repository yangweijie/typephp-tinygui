// Standalone, headless proof of the TypePHP backend-bridge logic that was
// injected into tinyjsapp's native/launcher-win.cc (Hunks A/C/D of the patch).
//
// It contains spawn_typephp_backend() VERBATIM from the patch, plus a minimal
// main() that:
//   1. spawns a dummy backend (a pipe-server) passing it the generated pipe name,
//   2. connects to that named pipe as a client (mirroring launcher-win.cc),
//   3. exchanges one CALL/RET frame to prove the spawn+connect+protocol round trip.
//
// This isolates the bridge logic from the rest of the launcher (which needs the
// Windows SDK WRL headers) so it can be validated in a headless CI/sandbox.
//
// Build & run (MinGW-w64 g++):
//   g++ -std=c++17 -O2 -o dummy_backend.exe dummy_backend.cpp -ladvapi32
//   g++ -std=c++17 -O2 -o spawn_bridge_test.exe spawn_bridge_test.cpp -ladvapi32
//   ./spawn_bridge_test.exe

#include <windows.h>
#include <string>
#include <cstdlib>
#include <cstdio>
#include <cstring>

static std::wstring widen(const std::string &s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w;
  w.resize(n);
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
  return w;
}

// ---- verbatim from the launcher-win.cc patch (Hunk D + forward decls) ----
static bool g_typephp = false;
static PROCESS_INFORMATION g_backend_proc = {};
static std::string spawn_typephp_backend();
static void terminate_typephp_backend();

static std::string spawn_typephp_backend() {
  // Pipe name the backend must create as a server before we connect.
  std::string name =
      "\\\\.\\pipe\\tinyjs-typephp-" + std::to_string(GetCurrentProcessId());
  // Backend binary: env TYPEPHP_BACKEND, else "<launcher_dir>/backend.exe".
  wchar_t buf[MAX_PATH];
  std::wstring exe;
  if (GetEnvironmentVariableW(L"TYPEPHP_BACKEND", buf, MAX_PATH)) {
    exe = buf;
  } else {
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring self(buf, n);
    size_t sl = self.find_last_of(L"\\/");
    exe = (sl == std::wstring::npos ? L"" : self.substr(0, sl + 1)) + L"backend.exe";
  }
  std::wstring cmd = L"\"" + exe + L"\" " + widen(name);
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return "";
  }
  CloseHandle(pi.hThread);
  g_backend_proc = pi;
  std::atexit(terminate_typephp_backend);
  return name;
}

static void terminate_typephp_backend() {
  if (g_backend_proc.hProcess) {
    TerminateProcess(g_backend_proc.hProcess, 0);
    CloseHandle(g_backend_proc.hProcess);
    g_backend_proc.hProcess = nullptr;
    g_backend_proc.hThread = nullptr;
  }
}
// ---------------------------------------------------------------------------

static std::string g_pipe_name;

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  // Honor TYPEPHP_BACKEND from the environment when set (e.g. point it at the
  // real shim backend_shell.exe); otherwise default to the dummy pipe-server.
  if (GetEnvironmentVariableA("TYPEPHP_BACKEND", nullptr, 0) == 0)
    SetEnvironmentVariableA("TYPEPHP_BACKEND", "dummy_backend.exe");

  g_typephp = true;
  g_pipe_name = spawn_typephp_backend();
  if (g_pipe_name.empty()) {
    std::fprintf(stderr, "FAIL: spawn_typephp_backend() returned empty\n");
    return 1;
  }
  std::printf("[test] spawned backend, pipe=%s\n", g_pipe_name.c_str());

  // Connect as a client (synchronous here; the real launcher uses overlapped in
  // pipe_read_loop — the spawn/name logic under test is identical).
  HANDLE h = INVALID_HANDLE_VALUE;
  for (int i = 0; i < 50; i++) {
    h = CreateFileW(widen(g_pipe_name).c_str(), GENERIC_READ | GENERIC_WRITE,
                    0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) break;
    if (GetLastError() == ERROR_PIPE_BUSY)
      WaitNamedPipeW(widen(g_pipe_name).c_str(), 1000);
    else
      Sleep(100);
  }
  if (h == INVALID_HANDLE_VALUE) {
    std::fprintf(stderr, "FAIL: could not connect to backend pipe\n");
    return 1;
  }
  std::printf("[test] connected to backend pipe\n");

  // Send a CALL frame and read the RET reply. The frame uses the backend's
  // method/params shape, so it works both with the dummy echo server and with
  // the real PHP backend (api.sum => 7).
  std::string call = "CALL 1 {\"method\":\"api.sum\",\"params\":{\"a\":3,\"b\":4}}\n";
  DWORD w = 0;
  if (!WriteFile(h, call.c_str(), (DWORD)call.size(), &w, nullptr) ||
      w != call.size()) {
    std::printf("FAIL: WriteFile CALL (w=%lu err=%lu)\n", w, GetLastError());
    return 1;
  }
  std::printf("[test] wrote CALL (%lu bytes)\n", w);
  // Read frames and ignore anything that is not the RET we are waiting for —
  // exactly how launcher-win.cc's pipe_read_loop treats unknown frames (it
  // silently drops lines without a known prefix, e.g. the READY banner).
  char buf[4096];
  std::string acc;
  for (int tries = 0; tries < 40; tries++) {
    DWORD r = 0;
    BOOL ok = ReadFile(h, buf, sizeof(buf) - 1, &r, nullptr);
    std::printf("[test] ReadFile ok=%d r=%lu err=%lu\n", (int)ok, r,
                ok ? 0UL : GetLastError());
    if (!ok || r == 0)
      break;
    acc.append(buf, r);
    size_t nl;
    while ((nl = acc.find('\n')) != std::string::npos) {
      std::string line = acc.substr(0, nl);
      acc.erase(0, nl + 1);
      std::printf("[test] frame: %s\n", line.c_str());
      if (line.rfind("RET 1", 0) == 0) {
        std::printf("[test] PASS: spawn + connect + CALL/RET round trip OK\n");
        CloseHandle(h);
        return 0;
      }
    }
  }
  std::printf("FAIL: no RET 1 frame (residual='%s')\n", acc.c_str());
  DWORD sc = 0;
  GetExitCodeProcess(g_backend_proc.hProcess, &sc);
  std::printf("FAIL: shim exit code = 0x%08lX (259=still running)\n", sc);
  CloseHandle(h);
  return 1;
}
