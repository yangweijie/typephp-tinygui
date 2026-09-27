// mac-winlist.c — list on-screen windows with their owning pid, for acceptance
// evidence on a Mac desktop.
//
// Why this exists: the usual ways to ask "is our window actually up?" do not
// work on this project's dev machine. AppleScript/System Events needs the
// Accessibility grant (it answers -1719 without it), and a plain
// `screencapture -x` grab of the whole screen photographs whatever the IDE has
// on top. CGWindowList needs neither grant and is per-window, so its
// kCGWindowNumber feeds `screencapture -x -o -l<id>` — a clean shot of just our
// window, even when it is fully covered.
//
// build:  cc -o build/mac-winlist tools/mac-winlist.c \
//           -framework CoreGraphics -framework CoreFoundation
//         (linking only CoreGraphics fails with missing _CFArrayGetCount)
//
// usage:  build/mac-winlist [owner-substring]
//         -> <windowNumber>\t<ownerPid>\t<ownerName>\t<windowName>\t<W>x<H>@<X>,<Y>
//
// Screen Recording is still needed for the *capture*, not for this listing.
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

static long num_of(CFDictionaryRef w, CFStringRef key) {
  CFTypeRef v = CFDictionaryGetValue(w, key);
  long out = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID())
    CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
  return out;
}

static void str_of(CFDictionaryRef w, CFStringRef key, char *buf, size_t cap) {
  buf[0] = '\0';
  CFTypeRef v = CFDictionaryGetValue(w, key);
  if (v && CFGetTypeID(v) == CFStringGetTypeID())
    CFStringGetCString((CFStringRef)v, buf, (CFIndex)cap, kCFStringEncodingUTF8);
}

int main(int argc, char **argv) {
  const char *want = argc > 1 ? argv[1] : "";
  CFArrayRef wins = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  if (!wins) {
    fprintf(stderr, "CGWindowListCopyWindowInfo failed\n");
    return 1;
  }
  const CFIndex n = CFArrayGetCount(wins);
  for (CFIndex i = 0; i < n; i++) {
    CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(wins, i);
    char owner[256], name[256];
    str_of(w, kCGWindowOwnerName, owner, sizeof owner);
    str_of(w, kCGWindowName, name, sizeof name);
    if (*want && !strstr(owner, want)) continue;
    // The bounds dict holds doubles; reading into longs would overrun by 4 B.
    double wx = 0, wy = 0, wid = 0, hei = 0;
    CFTypeRef b = CFDictionaryGetValue(w, kCGWindowBounds);
    if (b && CFGetTypeID(b) == CFDictionaryGetTypeID()) {
      // CFSTR() needs a literal, so the keys become CFStringRefs first.
      CFTypeRef keys[4] = {CFSTR("X"), CFSTR("Y"), CFSTR("Width"), CFSTR("Height")};
      double *dst[4] = {&wx, &wy, &wid, &hei};
      for (int k = 0; k < 4; k++) {
        CFTypeRef t = CFDictionaryGetValue((CFDictionaryRef)b, keys[k]);
        if (t && CFGetTypeID(t) == CFNumberGetTypeID())
          CFNumberGetValue((CFNumberRef)t, kCFNumberDoubleType, dst[k]);
      }
    }
    printf("%ld\t%ld\t%s\t%s\t%.0fx%.0f@%.0f,%.0f\n", num_of(w, kCGWindowNumber),
           num_of(w, kCGWindowOwnerPID), owner, name, wid, hei, wx, wy);
  }
  CFRelease(wins);
  return 0;
}
