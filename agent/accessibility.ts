import ObjC from "frida-objc-bridge";

declare const rpc: {
    exports: { [key: string]: (...args: any[]) => any };
};

interface Element {
    label: string;
    hint: string;
    x: number;
    y: number;
    w: number;
    h: number;
    source: string;
}

function strOf(obj: any): string {
    try {
        if (obj === null || obj === undefined) return "";
        const s = String(obj).trim();
        // Filter ObjC nil representations
        if (s === "" || s === "null" || s === "(null)" || s === "undefined") return "";
        return s;
    } catch (_) { return ""; }
}

function toNum(v: any): number { return parseInt(String(v), 10) || 0; }

// Parse accessibilityFrame().toString() — returns "origin_x,origin_y,w,h" CSV.
// Returns center point for tapping.
function frameFromAxFrame(el: any): { x: number; y: number; w: number; h: number } | null {
    try {
        const s = String(el.accessibilityFrame());
        const parts = s.split(",").map(Number);
        if (parts.length === 4 && parts[2] > 0 && parts[3] > 0) {
            const [ox, oy, w, h] = parts;
            return { x: ox + w / 2, y: oy + h / 2, w, h };
        }
    } catch (_) {}
    return null;
}

// Parse "frame = (x y; w h)" from UIView description — local coords fallback.
function frameFromDesc(desc: string): { x: number; y: number; w: number; h: number } | null {
    const m = desc.match(/frame\s*=\s*\(([\d.+-]+)\s+([\d.+-]+);\s*([\d.+-]+)\s+([\d.+-]+)\)/);
    if (m) {
        const [, x, y, w, h] = m.map(Number);
        if (w > 0 && h > 0) return { x: x + w / 2, y: y + h / 2, w, h };
    }
    return null;
}

function descOf(obj: ObjC.Object): string {
    try { return obj.description().toString(); } catch (_) { return ""; }
}

const SCREEN_W = 430;
const SCREEN_H = 932;

function isOnScreen(rect: { x: number; y: number; w: number; h: number }): boolean {
    // Center point must be within screen bounds
    return rect.w > 0 && rect.h > 0
        && rect.x >= 0 && rect.x <= SCREEN_W
        && rect.y >= 0 && rect.y <= SCREEN_H;
}

rpc.exports = {
    // Returns frontmost app bundle ID + PID from SpringBoard context
    getFrontmostApp(): Promise<{ bundleID?: string; pid?: number; error?: string }> {
        return new Promise((resolve) => {
            ObjC.schedule(ObjC.mainQueue, () => {
                try {
                    // Try SBApplicationController (SpringBoard only)
                    let bundleID = "";
                    try {
                        const ctrl = ObjC.classes.SBApplicationController["sharedInstance"]();
                        const app = ctrl["frontmostApplication"]();
                        if (app && String(app) !== "null") {
                            bundleID = String(app["bundleIdentifier"]());
                        }
                    } catch (_) {}

                    // Fallback: FBProcessManager
                    if (!bundleID) {
                        try {
                            const pm = ObjC.classes.FBProcessManager["sharedInstance"]();
                            const proc = pm["foregroundProcess"]();
                            if (proc && String(proc) !== "null") {
                                bundleID = String(proc["bundleID"]());
                            }
                        } catch (_) {}
                    }

                    resolve({ bundleID: bundleID || undefined });
                } catch (err: any) {
                    resolve({ error: String(err) });
                }
            });
        }) as any;
    },

    diagnose(): Promise<any> {
        return new Promise((resolve) => {
            ObjC.schedule(ObjC.mainQueue, () => {
                const info: any = {};
                try { info.sbIconViewCount = (ObjC.chooseSync(ObjC.classes.SBIconView) as any[]).length; } catch (e: any) { info.sbIconViewErr = String(e); }
                try { info.uiLabelCount = (ObjC.chooseSync(ObjC.classes.UILabel) as any[]).length; } catch (e: any) { info.uiLabelErr = String(e); }
                try {
                    const icons = ObjC.chooseSync(ObjC.classes.SBIconView) as any[];
                    if (icons.length > 0) {
                        info.icon0label = icons[0].accessibilityLabel().toString();
                        info.icon0frame = icons[0].accessibilityFrame().toString();
                    }
                } catch (e: any) { info.icon0err = String(e); }
                resolve(info);
            });
        }) as any;
    },

    dumpElements(): Promise<{ ok: boolean; elements?: Element[]; error?: string }> {
        return new Promise((resolve) => {
            ObjC.schedule(ObjC.mainQueue, () => {
                try {
                    const out: Element[] = [];
                    const seenPtrs = new Set<string>();

                    function add(ptr: string, label: string, hint: string, rect: { x: number; y: number; w: number; h: number }, source: string): void {
                        if (seenPtrs.has(ptr) || !label || !isOnScreen(rect)) return;
                        seenPtrs.add(ptr);
                        out.push({ label, hint, ...rect, source });
                    }

                    function bestFrame(obj: any): { x: number; y: number; w: number; h: number } | null {
                        // accessibilityFrame gives screen-space coords — prefer this
                        const af = frameFromAxFrame(obj);
                        if (af) return af;
                        // Fall back to description frame (may be local-space but often works)
                        return frameFromDesc(descOf(obj));
                    }

                    // Helper: returns true if view is visible (not hidden, alpha > 0, has window)
                    function isVisible(obj: any): boolean {
                        try { if (obj.isHidden()) return false; } catch (_) {}
                        try { if (Number(obj.alpha()) < 0.01) return false; } catch (_) {}
                        return true;
                    }

                    // ── UILabel ───────────────────────────────────────────────────────────
                    try {
                        const labels = ObjC.chooseSync(ObjC.classes.UILabel) as ObjC.Object[];
                        for (const lbl of labels) {
                            try {
                                if (!isVisible(lbl)) continue;
                                const text = strOf(lbl.text());
                                if (!text) continue;
                                const rect = bestFrame(lbl);
                                if (!rect) continue;
                                const axLabel = strOf(lbl.accessibilityLabel());
                                add(lbl.handle.toString(), axLabel || text, "", rect, "label");
                            } catch (_) {}
                        }
                    } catch (_) {}

                    // ── UIButton ──────────────────────────────────────────────────────────
                    try {
                        const buttons = ObjC.chooseSync(ObjC.classes.UIButton) as ObjC.Object[];
                        for (const btn of buttons) {
                            try {
                                if (!isVisible(btn)) continue;
                                const rect = bestFrame(btn);
                                if (!rect) continue;
                                let label = strOf(btn.accessibilityLabel());
                                if (!label) {
                                    try { label = strOf((btn as any).titleLabel().text()); } catch (_) {}
                                }
                                if (!label) continue;
                                const hint = strOf(btn.accessibilityHint());
                                add(btn.handle.toString(), label, hint, rect, "button");
                            } catch (_) {}
                        }
                    } catch (_) {}

                    // ── UITextField ───────────────────────────────────────────────────────
                    try {
                        const fields = ObjC.chooseSync(ObjC.classes.UITextField) as ObjC.Object[];
                        for (const f of fields) {
                            try {
                                if (!isVisible(f)) continue;
                                const rect = bestFrame(f);
                                if (!rect) continue;
                                const label = strOf(f.accessibilityLabel()) || strOf((f as any).placeholder());
                                if (!label) continue;
                                add(f.handle.toString(), label, "", rect, "textfield");
                            } catch (_) {}
                        }
                    } catch (_) {}

                    // ── SBIconView (home screen / dock / Control Center icons) ────────────
                    // accessibilityLabel() returns the icon name; accessibilityFrame() gives screen coords.
                    try {
                        const iconViews = ObjC.chooseSync(ObjC.classes.SBIconView) as any[];
                        for (const iv of iconViews) {
                            try {
                                if (!isVisible(iv)) continue;
                                const label = strOf(iv.accessibilityLabel());
                                if (!label) continue;
                                const fd = iv.accessibilityFrame().toString();
                                const parts = fd.split(",").map(Number);
                                if (parts.length !== 4 || !(parts[2] > 0)) continue;
                                const [ox, oy, w, h] = parts;
                                const rect = { x: ox + w / 2, y: oy + h / 2, w, h };
                                if (!isOnScreen(rect)) continue;
                                add(iv.handle.toString(), label, "", rect, "icon");
                            } catch (_) {}
                        }
                    } catch (_) {}

                    // ── Walk UIView tree for any UIView with accessibilityLabel ────────────
                    function walkForAxLabels(obj: ObjC.Object, depth: number): void {
                        if (depth > 15) return;
                        try {
                            const ptr = obj.handle.toString();
                            if (seenPtrs.has(ptr)) return;
                            // Skip hidden/transparent subtrees entirely
                            if (!isVisible(obj)) return;

                            const axLabel = strOf(obj.accessibilityLabel());
                            if (axLabel) {
                                const rect = bestFrame(obj);
                                if (rect) add(ptr, axLabel, strOf(obj.accessibilityHint()), rect, "ax");
                            }

                            const subs = obj.subviews() as ObjC.Object;
                            const n = toNum(subs.count());
                            for (let i = 0; i < n; i++) {
                                walkForAxLabels(subs.objectAtIndex_(i) as ObjC.Object, depth + 1);
                            }
                        } catch (_) {}
                    }

                    try {
                        const wins = ObjC.chooseSync(ObjC.classes.UIWindow) as ObjC.Object[];
                        for (const w of wins) {
                            // Skip hidden windows (recents, lock screen when unlocked, etc.)
                            try { if ((w as any).isHidden()) continue; } catch (_) {}
                            walkForAxLabels(w, 0);
                        }
                    } catch (_) {}

                    resolve({ ok: true, elements: out });
                } catch (err: any) {
                    resolve({ ok: false, error: String(err) });
                }
            });
        });
    },
};
