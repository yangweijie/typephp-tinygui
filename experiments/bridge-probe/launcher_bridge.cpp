// launcher_bridge.cpp — 方案 B 的 launcher 侧 stdio 桥接（并入 launcher-win.cc）
//
// 替换原 launcher 中"创建命名管道/Unix socket 并等待后端连接"的逻辑。
// 改为：launcher 作为父进程，用 CreateProcess 拉起 aot-compiler 编出的
// backend.exe，并把子进程的 stdin/stdout 重定向到匿名管道。
// 之后 launcher 与后端之间仍讲同一套换行分隔的 CALL/RET 帧协议，
// 只是传输层从 命名管道/套接字 换成 子进程 stdio。
//
// 这样 PHP 后端侧彻底不需要 socket / proc_open（呼应 nano 策略的无进程/网络意图），
// 所有原生能力（窗口、菜单、托盘、对话框…）继续留在 C++ launcher 里。

#include <windows.h>
#include <string>
#include <thread>
#include <atomic>

namespace launcher_bridge {

struct BackendPipe {
    HANDLE childStdinWrite = nullptr;   // launcher -> backend stdin
    HANDLE childStdoutRead = nullptr;   // backend stdout -> launcher
    PROCESS_INFORMATION pi{};
    std::atomic<bool> running{false};
    std::thread reader;
};

// 现有 launcher 里处理"后端响应"的回调（原 socket/pipe 读取路径调用它）。
// 这里保持签名不变，把 stdio 读到的 RET 帧喂给它即可。
extern void onBackendResponse(const std::string& id, const std::string& json);

// 拉起 PHP 后端子进程，重定向 stdio。返回 false 表示启动失败。
inline bool spawnBackend(BackendPipe& bp, const std::wstring& exePath,
                         const std::wstring& workDir) {
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};  // 句柄可继承
    HANDLE childStdinRead = nullptr, childStdoutWrite = nullptr;

    if (!CreatePipe(&childStdinRead, &bp.childStdinWrite, &sa, 0)) return false;
    if (!CreatePipe(&bp.childStdoutRead, &childStdoutWrite, &sa, 0)) return false;

    STARTUPINFOW si{sizeof(si)};
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = childStdinRead;        // 子进程 stdin 来自本管道
    si.hStdOutput = childStdoutWrite;     // 子进程 stdout 写入本管道
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

    if (!CreateProcessW(exePath.c_str(), nullptr, nullptr, nullptr,
                        TRUE, CREATE_NO_WINDOW, nullptr,
                        workDir.empty() ? nullptr : workDir.c_str(),
                        &si, &bp.pi)) {
        return false;
    }
    // 父进程用不到的子端句柄关闭，避免句柄泄漏
    CloseHandle(childStdinRead);
    CloseHandle(childStdoutWrite);

    bp.running = true;
    bp.reader = std::thread([&bp]() { readerLoop(bp); });
    return true;
}

// 把一帧发给后端（CALL <id> <json>）。原 pipe_write_line 直接换成这个。
inline bool bridgeWrite(BackendPipe& bp, const std::string& frame) {
    std::string buf = frame + "\n";
    DWORD written = 0;
    return WriteFile(bp.childStdinWrite, buf.data(), (DWORD)buf.size(),
                     &written, nullptr) && written == buf.size();
}

// 读子进程 stdout，按 \n 切帧
inline void readerLoop(BackendPipe& bp) {
    char chunk[4096];
    DWORD n = 0;
    std::string buf;
    while (bp.running && ReadFile(bp.childStdoutRead, chunk, sizeof(chunk), &n, nullptr) && n > 0) {
        buf.append(chunk, n);
        size_t nl;
        while ((nl = buf.find('\n')) != std::string::npos) {
            std::string line = buf.substr(0, nl);
            buf.erase(0, nl + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            dispatchLine(bp, line);
        }
    }
    bp.running = false;
}

inline void dispatchLine(BackendPipe& bp, const std::string& line) {
    if (line == "READY") {
        // 后端就绪：发初始握手（原 client.hello / 配置下发）
        bridgeWrite(bp, "CALL 0 {\"method\":\"app.config\",\"params\":{}}");
        return;
    }
    if (line.rfind("RET ", 0) == 0) {
        // RET <id> <json>
        std::string rest = line.substr(4);
        size_t sp = rest.find(' ');
        if (sp != std::string::npos) {
            std::string id = rest.substr(0, sp);
            std::string json = rest.substr(sp + 1);
            onBackendResponse(id, json);
        }
        return;
    }
    if (line.rfind("GOT ", 0) == 0) {
        // 后端不应主动发 GOT（那是 launcher->backend 的异步通知）；忽略或记日志
        return;
    }
    // 其它行：日志
}

inline void shutdownBackend(BackendPipe& bp) {
    bp.running = false;
    if (bp.childStdinWrite) CloseHandle(bp.childStdinWrite);
    if (bp.childStdoutRead) CloseHandle(bp.childStdoutRead);
    if (bp.pi.hProcess) {
        TerminateProcess(bp.pi.hProcess, 0);
        CloseHandle(bp.pi.hProcess);
        CloseHandle(bp.pi.hThread);
    }
    if (bp.reader.joinable()) bp.reader.join();
}

}  // namespace launcher_bridge
