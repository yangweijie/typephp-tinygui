"""Minimize then restore a window to generate window-state transitions.

The launcher reports WINSTATE on real transitions only (deduped), so a
minimize->restore cycle is a reliable way to exercise the backend->page
EVAL push path without touching any user setting.
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

user32 = ctypes.windll.user32
SW_MINIMIZE = 6
SW_RESTORE = 9

substr = sys.argv[1]

found = []


@ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
def cb(hwnd, _):
    if not user32.IsWindowVisible(hwnd):
        return True
    n = user32.GetWindowTextLengthW(hwnd)
    if n:
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        if substr.lower() in buf.value.lower():
            found.append((hwnd, buf.value))
    return True


user32.EnumWindows(cb, 0)
if not found:
    print("no window matched:", substr)
    sys.exit(1)

hwnd, title = found[0]
print(f"window='{title}' hwnd={hwnd}")

print("minimize")
user32.ShowWindow(hwnd, SW_MINIMIZE)
time.sleep(1.2)

print("restore")
user32.ShowWindow(hwnd, SW_RESTORE)
time.sleep(0.4)
user32.SetForegroundWindow(hwnd)
time.sleep(1.0)
print("done")
