#!/usr/bin/env python3
"""
mac_tap.py — Tap/swipe the vphone-cli VM window using macOS CGEvent mouse injection.

The vphone-cli VPhoneVirtualMachineView translates mouseDown/mouseDragged/mouseUp
into _VZTouch events sent directly to the iOS VM via the Virtualization framework.
So CGEvent clicks on the window become real iOS touch events — no jailbreak needed.

Usage:
  python3 mac_tap.py tap X Y
  python3 mac_tap.py swipe X1 Y1 X2 Y2 [steps]
  python3 mac_tap.py home
  python3 mac_tap.py info          # show window info and exit

Coordinates are in iOS logical points (430×932 space).
"""

import sys
import time
import subprocess

try:
    import Quartz
    import AppKit
except ImportError:
    print("ERROR: Quartz/AppKit not available — run with system Python3 or pyobjc installed")
    sys.exit(1)

SCREEN_W = 430.0
SCREEN_H = 932.0
TITLE_KEYWORDS = ["vphone", "VPHONE"]


def find_vphone_window():
    """Return window bounds + PID. Works even when window is not frontmost."""
    # Include off-screen windows too so it works when vphone is behind other apps
    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    if not windows:
        return None, None

    for w in windows:
        owner = w.get("kCGWindowOwnerName", "")
        name = w.get("kCGWindowName", "") or ""
        if any(k.lower() in owner.lower() or k.lower() in name.lower() for k in TITLE_KEYWORDS):
            bounds = w.get("kCGWindowBounds", {})
            pid = w.get("kCGWindowOwnerPID")
            return bounds, pid

    return None, None


def get_content_rect_via_ax(pid):
    """Use Accessibility API to get the exact content area of the VM view."""
    try:
        from ApplicationServices import (
            AXUIElementCreateApplication,
            AXUIElementCopyAttributeValue,
            kAXWindowsAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
            AXValueGetValue,
            kAXValueCGPointType,
            kAXValueCGSizeType,
            kAXChildrenAttribute,
            kAXRoleAttribute,
        )
        import CoreFoundation

        app = AXUIElementCreateApplication(pid)
        err, wins = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, None)
        if err != 0 or not wins or len(wins) == 0:
            return None

        win = wins[0]
        err, pos_val = AXUIElementCopyAttributeValue(win, kAXPositionAttribute, None)
        err2, sz_val = AXUIElementCopyAttributeValue(win, kAXSizeAttribute, None)
        if err != 0 or err2 != 0:
            return None

        import ctypes
        import CoreGraphics

        pos = CoreGraphics.CGPoint()
        sz = CoreGraphics.CGSize()

        # AXValueGetValue with kAXValueCGPointType
        ok1 = AXValueGetValue(pos_val, kAXValueCGPointType, ctypes.byref(pos))
        ok2 = AXValueGetValue(sz_val, kAXValueCGSizeType, ctypes.byref(sz))
        if ok1 and ok2:
            return {"X": pos.x, "Y": pos.y, "Width": sz.width, "Height": sz.height}
    except Exception as e:
        pass
    return None


def get_window_content_rect():
    """Get the content rect of the VM view in screen coordinates."""
    bounds, pid = find_vphone_window()
    if not bounds:
        return None

    # Try AX API first for exact content bounds
    if pid:
        ax_rect = get_content_rect_via_ax(pid)
        if ax_rect and ax_rect["Width"] > 100:
            # AX position is window origin (top of title bar), size is full window.
            # The content view starts below title bar + toolbar.
            # Approximate combined title bar + unified toolbar height: ~52pt
            # We'll use a simple heuristic: content_height ≈ width * (932/430)
            ww = ax_rect["Width"]
            expected_content_h = ww * (SCREEN_H / SCREEN_W)
            toolbar_h = ax_rect["Height"] - expected_content_h
            if 20 < toolbar_h < 120:
                return {
                    "X": ax_rect["X"],
                    "Y": ax_rect["Y"] + toolbar_h,
                    "Width": ww,
                    "Height": expected_content_h,
                }

    # Fallback: use CGWindowList bounds (full frame)
    # Estimate toolbar height from aspect ratio
    ww = bounds["Width"]
    wh = bounds["Height"]
    expected_content_h = ww * (SCREEN_H / SCREEN_W)
    toolbar_h = wh - expected_content_h
    if not (20 < toolbar_h < 120):
        # Fallback: assume 52pt toolbar
        toolbar_h = 52

    return {
        "X": bounds["X"],
        "Y": bounds["Y"] + toolbar_h,
        "Width": ww,
        "Height": ww * (SCREEN_H / SCREEN_W),
    }


def ios_to_screen(x, y, rect):
    """Map iOS logical point (0..430, 0..932) to macOS screen coordinates."""
    nx = x / SCREEN_W
    ny = y / SCREEN_H
    sx = rect["X"] + nx * rect["Width"]
    sy = rect["Y"] + ny * rect["Height"]
    return sx, sy


def post(pid, event):
    """Post CGEvent directly to vphone-cli process — no window focus needed."""
    Quartz.CGEventPostToPid(pid, event)


def tap(x, y):
    rect = get_window_content_rect()
    _, pid = find_vphone_window()
    if not rect or not pid:
        print("ERROR: vphone-cli window not found", file=sys.stderr)
        return False
    sx, sy = ios_to_screen(x, y, rect)
    print(f"[mac_tap] tap iOS ({x},{y}) → screen ({sx:.1f},{sy:.1f})")
    pos = Quartz.CGPoint(sx, sy)
    down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, pos, Quartz.kCGMouseButtonLeft)
    up   = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp,   pos, Quartz.kCGMouseButtonLeft)
    post(pid, down)
    time.sleep(0.05)
    post(pid, up)
    return True


def swipe(x1, y1, x2, y2, steps=20):
    rect = get_window_content_rect()
    _, pid = find_vphone_window()
    if not rect or not pid:
        print("ERROR: vphone-cli window not found", file=sys.stderr)
        return False

    delay = 0.5 / steps
    positions = []
    for i in range(steps + 1):
        t = i / steps
        x = x1 + (x2 - x1) * t
        y = y1 + (y2 - y1) * t
        positions.append(ios_to_screen(x, y, rect))

    print(f"[mac_tap] swipe iOS ({x1},{y1})→({x2},{y2}) in {steps} steps")

    start_pos = Quartz.CGPoint(positions[0][0], positions[0][1])
    down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, start_pos, Quartz.kCGMouseButtonLeft)
    post(pid, down)
    time.sleep(0.02)

    for i, (sx, sy) in enumerate(positions[1:], 1):
        pos = Quartz.CGPoint(sx, sy)
        ev = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDragged, pos, Quartz.kCGMouseButtonLeft)
        post(pid, ev)
        if i < steps:
            time.sleep(delay)

    time.sleep(0.02)
    end_pos = Quartz.CGPoint(positions[-1][0], positions[-1][1])
    up = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, end_pos, Quartz.kCGMouseButtonLeft)
    post(pid, up)
    return True


def send_home():
    """Send Home button via right-click on the VM window."""
    rect = get_window_content_rect()
    _, pid = find_vphone_window()
    if not rect or not pid:
        print("ERROR: vphone-cli window not found", file=sys.stderr)
        return False
    cx = rect["X"] + rect["Width"] / 2
    cy = rect["Y"] + rect["Height"] / 2
    pos = Quartz.CGPoint(cx, cy)
    down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventRightMouseDown, pos, Quartz.kCGMouseButtonRight)
    up   = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventRightMouseUp,   pos, Quartz.kCGMouseButtonRight)
    post(pid, down)
    time.sleep(0.05)
    post(pid, up)
    print("[mac_tap] sent Home")
    return True


def info():
    rect = get_window_content_rect()
    bounds, pid = find_vphone_window()
    if not bounds:
        print("vphone-cli window NOT found")
        return
    print(f"Window bounds (full frame): {dict(bounds)}")
    print(f"Content rect (estimated):   {rect}")
    print(f"PID: {pid}")
    # Take a quick sanity shot
    sx, sy = ios_to_screen(215, 466, rect)
    print(f"Center (215,466) → screen ({sx:.1f},{sy:.1f})")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    cmd = args[0]
    if cmd == "tap" and len(args) >= 3:
        tap(float(args[1]), float(args[2]))
    elif cmd == "swipe" and len(args) >= 5:
        steps = int(args[5]) if len(args) >= 6 else 20
        swipe(float(args[1]), float(args[2]), float(args[3]), float(args[4]), steps)
    elif cmd == "home":
        send_home()
    elif cmd == "info":
        info()
    else:
        print(__doc__)
        sys.exit(1)
