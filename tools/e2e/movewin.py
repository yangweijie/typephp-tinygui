"""Find a window by title substring and move/resize it (predictable coords)."""
import ctypes
import ctypes.wintypes as wt
import sys

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()

substr, x, y, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

found = []


@ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
def cb(hwnd, _):
    if not user32.IsWindowVisible(hwnd):
        return True
    n = user32.GetWindowTextLengthW(hwnd)
    if n:
        b = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, b, n + 1)
        if substr.lower() in b.value.lower():
            found.append((hwnd, b.value))
    return True


user32.EnumWindows(cb, 0)
if not found:
    print("no window matched:", substr)
    sys.exit(1)

hwnd, title = found[0]
SWP_NOZORDER, SWP_SHOWWINDOW = 0x0004, 0x0040
user32.SetWindowPos(hwnd, 0, x, y, w, h, SWP_NOZORDER | SWP_SHOWWINDOW)
rc = wt.RECT()
user32.GetWindowRect(hwnd, ctypes.byref(rc))
print(f"'{title}' -> rect=({rc.left},{rc.top},{rc.right-rc.left}x{rc.bottom-rc.top})")
