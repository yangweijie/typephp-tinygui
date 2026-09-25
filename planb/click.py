"""Click at (window rect origin + relative offset) and report the window title."""
import ctypes
import ctypes.wintypes as wt
import sys
import time

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004

substr = sys.argv[1]
rx = int(sys.argv[2])
ry = int(sys.argv[3])

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
    print("no window matched")
    sys.exit(1)

hwnd, title = found[0]
rc = wt.RECT()
user32.GetWindowRect(hwnd, ctypes.byref(rc))
x, y = rc.left + rx, rc.top + ry
print(f"window='{title}' hwnd={hwnd} rect=({rc.left},{rc.top}) -> click ({x},{y})")

user32.SetForegroundWindow(hwnd)
time.sleep(0.4)
user32.SetCursorPos(x, y)
time.sleep(0.15)
user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
time.sleep(0.05)
user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
time.sleep(0.8)

n = user32.GetWindowTextLengthW(hwnd)
buf = ctypes.create_unicode_buffer(n + 1)
user32.GetWindowTextW(hwnd, buf, n + 1)
print("title after click:", buf.value)
