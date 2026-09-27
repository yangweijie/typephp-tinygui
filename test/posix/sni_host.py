#!/usr/bin/env python3
"""A spec-conformant StatusNotifierWatcher host — the "system tray" for
test/posix/desktop-session.sh.

Why a hand-written host has to exist at all: the tray path we must verify is an
SNI *client* (libayatana-appindicator3 inside launcher-linux), and Debian
bookworm ships no panel that speaks SNI out of the box — xfce4-panel 4.18 only
built the XEmbed `libsystray.so`, and lxqt-panel 1.2.1 dropped
`libstatusnotifier.so` from its package. A tray host *is* by definition a
watcher object on the session bus, so this implements exactly the half of
org.freedesktop.StatusNotifierItem-v0.7 that a host must provide:

  bus name  org.kde.StatusNotifierWatcher
  object    /StatusNotifierWatcher
  props     RegisteredStatusNotifierItems(as) IsStatusNotifierHostRegistered(b)
            ProtocolVersion(i)
  methods   RegisterStatusNotifierItem(s) UnregisterStatusNotifierItem(s)
  signals   StatusNotifierItemRegistered(s) StatusNotifierItemUnregistered(s)
            StatusNotifierHostRegistered()

and then does what a real host does with a registration: reads the item's
org.kde.StatusNotifierItem properties, saves its IconPixmap to a PNG, pulls the
com.canonical.dbusmenu layout from the item's Menu path, and (when asked) calls
Activate() / sends a dbusmenu "clicked" Event — which is precisely how a tray
click reaches the launcher and comes back out as a TRAYCLICK / TRAY <id> pipe
frame.

BOUNDARY, stated plainly: this proves OUR side of the wire is spec-correct and
that the launcher reacts to host-driven activation. It does NOT prove that
KDE's or xfce4-4.20's panel paints the same bytes — that needs a machine with a
real DE. See the "desktop session" section of test/posix/README.md.

usage: sni_host.py --report <path.json> [--icon-png <path>] [--timeout 25]
                   [--activate] [--click <label-substring>]
exit:  0 = at least one item registered (and requested actions ran),
       3 = timeout with no item, 1 = bus/name failure.
"""
import argparse
import json
import struct
import sys
import zlib

import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

WATCHER_IFACE = "org.kde.StatusNotifierWatcher"
ITEM_IFACE = "org.kde.StatusNotifierItem"
DBUSMENU_IFACE = "com.canonical.dbusmenu"
PROPS_IFACE = "org.freedesktop.DBus.Properties"


def to_png(width, height, argb, path):
    """ARGB32 (0xAARRGGBB per pixel, as SNI ships it) -> RGBA PNG, no PIL."""
    raw = bytearray()
    for p in argb:
        u = p & 0xFFFFFFFF
        a = (u >> 24) & 0xFF
        r = (u >> 16) & 0xFF
        g = (u >> 8) & 0xFF
        b = u & 0xFF
        raw += bytes((r, g, b, a))
    stride = width * 4

    def chunk(tag, data):
        return (struct.pack("!I", len(data)) + tag + data
                + struct.pack("!I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    body = b"".join(b"\x00" + bytes(raw[i * stride:(i + 1) * stride])
                    for i in range(height))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(body, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


def flatten_layout(node, out):
    """(id, props, [variant(child)...]) -> list of {id,label,type} in menu order."""
    mid = int(node[0])
    props = node[1]
    children = node[2] if len(node) > 2 else []
    out.append({
        "id": mid,
        "label": str(props.get("label", "")),
        "type": str(props.get("type", "")),
        "enabled": bool(props.get("enabled", True)),
    })
    for child in children:
        flatten_layout(child, out)


class Host(dbus.service.Object):
    def __init__(self, bus, args, state):
        super().__init__(bus, "/StatusNotifierWatcher")
        self.bus = bus
        self.args = args
        self.state = state
        self.registered = []

    # ---- the watcher surface a client calls -----------------------------
    @dbus.service.method(WATCHER_IFACE, in_signature="s", out_signature="",
                         sender_keyword="sender")
    def RegisterStatusNotifierItem(self, service, sender=None):
        bus_name = sender if service.startswith("/") else service
        path = service if service.startswith("/") else "/StatusNotifierItem"
        rec = {"service": str(service), "bus": str(bus_name), "path": str(path)}
        if rec not in self.registered:
            self.registered.append(rec)
            self.state["items"].append(rec)
            self.StatusNotifierItemRegistered(str(service))
            # A real host gives the client a moment to export props/menu.
            GLib.timeout_add(700, self.inspect, len(self.state["items"]) - 1)

    @dbus.service.method(WATCHER_IFACE, in_signature="s", out_signature="")
    def UnregisterStatusNotifierItem(self, service):
        self.state["unregistered"].append(str(service))
        self.StatusNotifierItemUnregistered(str(service))

    @dbus.service.signal(WATCHER_IFACE, signature="s")
    def StatusNotifierItemRegistered(self, service):
        pass

    @dbus.service.signal(WATCHER_IFACE, signature="s")
    def StatusNotifierItemUnregistered(self, service):
        pass

    @dbus.service.signal(WATCHER_IFACE, signature="")
    def StatusNotifierHostRegistered(self):
        pass

    # ---- org.freedesktop.DBus.Properties on the watcher itself ----------
    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self.GetAll(interface).get(prop)

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface, *a):
        return dbus.Dictionary({
            "RegisteredStatusNotifierItems": dbus.Array(
                [r["service"] for r in self.registered], signature="s"),
            "IsStatusNotifierHostRegistered": dbus.Boolean(True),
            "ProtocolVersion": dbus.Int32(0),
        }, signature="sv")

    @dbus.service.method(PROPS_IFACE, in_signature="ssv")
    def Set(self, interface, prop, value):
        raise dbus.exceptions.DBusException(
            "org.freedesktop.DBus.Error.InvalidArgs: read-only")

    # ---- what a host DOES after a registration --------------------------
    def inspect(self, idx):
        rec = self.state["items"][idx]
        try:
            obj = self.bus.get_object(rec["bus"], rec["path"])
            props = dbus.Interface(obj, PROPS_IFACE).GetAll(ITEM_IFACE)
        except dbus.exceptions.DBusException as exc:
            rec["error"] = "GetAll failed: %s" % exc
            self.finish_if_done()
            return False
        summary = {
            "Id": str(props.get("Id", "")),
            "Category": str(props.get("Category", "")),
            "Status": str(props.get("Status", "")),
            "IconName": str(props.get("IconName", "")),
            "Title": str(props.get("Title", "")),
            "Menu": str(props.get("Menu", "/(none)")),
            "ItemIsMenu": bool(props.get("ItemIsMenu", False)),
        }
        tip = props.get("ToolTip")
        if tip and len(tip) > 1:
            summary["ToolTip"] = str(tip[1].get("label", ""))
        rec["props"] = summary

        pix = props.get("IconPixmap")
        if pix and len(pix) >= 2:
            width, height = int(pix[0]), int(pix[1])
            argb = [int(v) for v in pix[2:2 + width * height]]
            summary["IconPixmap"] = {"width": width, "height": height,
                                     "pixels": len(argb)}
            if self.args.icon_png and argb:
                try:
                    to_png(width, height, argb, self.args.icon_png)
                    summary["IconPixmap"]["saved"] = self.args.icon_png
                except Exception as exc:                       # noqa: BLE001
                    summary["IconPixmap"]["save_error"] = str(exc)
        else:
            summary["IconPixmap"] = {"width": 0, "height": 0, "pixels": 0}

        if summary["Menu"] not in ("", "/(none)", "/"):
            try:
                menu = self.bus.get_object(rec["bus"], summary["Menu"])
                iface = dbus.Interface(menu, DBUSMENU_IFACE)
                try:
                    iface.AboutToShow(0)
                except dbus.exceptions.DBusException:
                    pass          # not every client implements it; harmless
                rev, layout = iface.GetLayout(0, -1, [])
                flat = []
                flatten_layout(layout, flat)
                rec["dbusmenu"] = {"revision": int(rev), "items": flat}
                self.state["menus"].append(flat)
            except dbus.exceptions.DBusException as exc:
                rec["dbusmenu_error"] = str(exc)

        if self.args.activate:
            try:
                dbus.Interface(obj, ITEM_IFACE).Activate(
                    dbus.Int32(10), dbus.Int32(10))
                rec["activate_sent"] = True
            except dbus.exceptions.DBusException as exc:
                rec["activate_error"] = str(exc)
            self.args.activate = False        # once is enough

        if self.args.click:
            want = self.args.click
            hit = None
            for entry in rec.get("dbusmenu", {}).get("items", []):
                if entry["label"] and want in entry["label"]:
                    hit = entry
                    break
            if hit is None:
                rec["click_error"] = "no menu item matching %r" % want
            else:
                menu = self.bus.get_object(rec["bus"], summary["Menu"])
                dbus.Interface(menu, DBUSMENU_IFACE).Event(
                    dbus.Int32(hit["id"]), "clicked",
                    dbus.Dictionary({}, signature="sv"), dbus.UInt32(0))
                rec["click_sent"] = hit
            self.args.click = ""

        self.finish_if_done()
        return False

    def finish_if_done(self):
        # Stay up while a scripted host action is still owed to a later
        # registration; otherwise give the launcher a beat to write its pipe
        # frame and then stop.
        if self.args.click or self.args.activate:
            return
        GLib.timeout_add(1500, self.stop, 0)

    def stop(self, code):
        if self.state.get("finished"):
            return False
        self.state["finished"] = True
        with open(self.args.report, "w") as fh:
            json.dump({"watcher": WATCHER_IFACE, "rc": code, **self.state},
                      fh, indent=1, default=str)
        try:
            self.remove_from_connection()
        except Exception:                              # noqa: BLE001
            pass
        self.loop.quit()
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--icon-png", default="")
    ap.add_argument("--timeout", type=float, default=25.0)
    ap.add_argument("--activate", action="store_true")
    ap.add_argument("--click", default="")
    args = ap.parse_args()

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SessionBus()
        # Owning the well-known name IS the registration a client looks for;
        # dbus.service.BusName keeps it alive for the lifetime of this object.
        name = dbus.service.BusName(WATCHER_IFACE, bus)
    except dbus.exceptions.DBusException as exc:
        print("cannot own %s on the session bus: %s" % (WATCHER_IFACE, exc),
              file=sys.stderr)
        return 1

    state = {"items": [], "menus": [], "unregistered": [], "finished": False}
    host = Host(bus, args, state)
    host.name = name          # keep the bus-name reference alive

    loop = GLib.MainLoop()
    host.loop = loop
    host.StatusNotifierHostRegistered()

    def on_timeout():
        # Nothing ever registered: the tray leg of the acceptance failed.
        return host.stop(3 if not state["items"] else 0)

    GLib.timeout_add(int(args.timeout * 1000), on_timeout)
    loop.run()
    return 0 if state["items"] else 3


if __name__ == "__main__":
    sys.exit(main())
