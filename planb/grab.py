"""Dependency-free window screenshot (ctypes/GDI) + minimal PNG writer.

Usage: python grab.py <window-title-substring> <out.png>
Captures the top-level window whose title contains the substring, after
bringing it to the foreground. Falls back to the whole virtual screen.
"""
import ctypes
import ctypes.wintypes as wt
import struct
import sys
import zlib
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

user32.SetProcessDPIAware()

SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD),
        ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
        ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG),
        ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]


def find_window(substr):
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
    return found


def grab(x, y, w, h):
    hdc = user32.GetDC(0)
    memdc = gdi32.CreateCompatibleDC(hdc)
    hbmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(memdc, hbmp)
    gdi32.BitBlt(memdc, 0, 0, w, h, hdc, x, y, SRCCOPY)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h          # top-down
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    bi.bmiHeader.biCompression = 0
    buflen = w * h * 4
    buf = ctypes.create_string_buffer(buflen)
    gdi32.GetDIBits(memdc, hbmp, 0, h, buf, ctypes.byref(bi), DIB_RGB_COLORS)

    gdi32.DeleteObject(hbmp)
    gdi32.DeleteDC(memdc)
    user32.ReleaseDC(0, hdc)
    return buf.raw


def write_png(path, w, h, bgra):
    stride = w * 4
    raw = bytearray()
    for row in range(h):
        raw.append(0)  # filter: none
        off = row * stride
        line = bgra[off:off + stride]
        px = bytearray(w * 4)
        for i in range(w):
            b, g, r = line[i * 4], line[i * 4 + 1], line[i * 4 + 2]
            px[i * 4] = r
            px[i * 4 + 1] = g
            px[i * 4 + 2] = b
            px[i * 4 + 3] = 255
        raw += px

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        f.write(chunk(b"IEND", b""))


def main():
    substr = sys.argv[1] if len(sys.argv) > 1 else ""
    out = sys.argv[2] if len(sys.argv) > 2 else "shot.png"

    wins = find_window(substr) if substr else []
    if wins:
        hwnd, title = wins[0]
        user32.SetForegroundWindow(hwnd)
        time.sleep(0.6)
        rc = wt.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rc))
        x, y = rc.left, rc.top
        w, h = rc.right - rc.left, rc.bottom - rc.top
        print(f"window '{title}' hwnd={hwnd} rect=({x},{y},{w}x{h})")
    else:
        x = user32.GetSystemMetrics(76)
        y = user32.GetSystemMetrics(77)
        w = user32.GetSystemMetrics(78)
        h = user32.GetSystemMetrics(79)
        print(f"no window matched; full virtual screen ({x},{y},{w}x{h})")

    write_png(out, w, h, grab(x, y, w, h))
    print("saved", out)


main()
