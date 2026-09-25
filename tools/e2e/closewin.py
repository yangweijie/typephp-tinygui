import ctypes, sys, time
u = ctypes.windll.user32
title = sys.argv[1] if len(sys.argv) > 1 else "TypePHP Demo"
WM_CLOSE = 0x0010
targets = []
EnumProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
def cb(hwnd, lp):
    n = ctypes.create_unicode_buffer(512)
    u.GetWindowTextW(hwnd, n, 512)
    if n.value == title and u.IsWindowVisible(hwnd):
        targets.append(hwnd)
    return True
u.EnumWindows(EnumProc(cb), None)
for h in targets:
    print("WM_CLOSE ->", h)
    u.PostMessageW(h, WM_CLOSE, 0, 0)
print("closed %d window(s)" % len(targets))
