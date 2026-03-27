import ObjC from "frida-objc-bridge";

declare const rpc: {
    exports: { [key: string]: (...args: any[]) => any };
};

function findFn(name: string, retType: string, argTypes: string[]): NativeFunction<any, any> | null {
    for (const m of Process.enumerateModules()) {
        try {
            for (const e of m.enumerateExports()) {
                if (e.name === name) return new NativeFunction(e.address, retType as any, argTypes as any);
            }
        } catch (_) {}
    }
    return null;
}

// Screenshot
const createScreenImage = findFn('_UICreateScreenUIImage', 'pointer', []);
const pngRepFn          = findFn('UIImagePNGRepresentation', 'pointer', ['pointer']);

// Touch injection
const mat          = findFn('mach_absolute_time', 'uint64', []);
const createFinger = findFn('IOHIDEventCreateDigitizerFingerEvent', 'pointer',
    ['pointer','uint64','uint32','uint32','uint32','double','double','double','double','double','int32','uint32']);
const dispatchHID  = findFn('BKSHIDEventSendToFocusedProcess', 'void', ['pointer']);

// eventMask bits: range=1, touch=2, position=4
const MASK_BEGIN = 7;  // range|touch|position
const MASK_MOVE  = 4;  // position only
const MASK_UP    = 3;  // range|touch, pressure=0

const SCREEN_W = 430;
const SCREEN_H = 932;

function sendTouch(nx: number, ny: number, mask: number, pressure: number): void {
    if (!mat || !createFinger || !dispatchHID) return;
    const ts = mat() as unknown as UInt64;
    const ev = createFinger(ptr('0'), ts, 1, 1, mask, nx, ny, 0, pressure, 0, 1, 0) as NativePointer;
    dispatchHID(ev);
}

function scheduleTouch(nx: number, ny: number, mask: number, pressure: number): Promise<void> {
    return new Promise((resolve) => {
        ObjC.schedule(ObjC.mainQueue, () => {
            sendTouch(nx, ny, mask, pressure);
            resolve();
        });
    });
}

rpc.exports = {
    screenshot(outPath: string): Promise<{ ok: boolean; path: string; bytes?: number; error?: string }> {
        outPath = outPath || '/tmp/frida_screen.png';
        return new Promise((resolve) => {
            ObjC.schedule(ObjC.mainQueue, () => {
                try {
                    if (!createScreenImage || !pngRepFn) {
                        resolve({ ok: false, path: outPath, error: 'missing fns' });
                        return;
                    }
                    const imgPtr = createScreenImage() as NativePointer;
                    if (imgPtr.isNull()) { resolve({ ok: false, path: outPath, error: 'null image' }); return; }
                    const dataPtr = pngRepFn(imgPtr) as NativePointer;
                    if (dataPtr.isNull()) { resolve({ ok: false, path: outPath, error: 'null data' }); return; }
                    const data = new ObjC.Object(dataPtr);
                    data.writeToFile_atomically_(outPath, 1);
                    resolve({ ok: true, path: outPath, bytes: data.length() as unknown as number });
                } catch (err: any) {
                    resolve({ ok: false, path: outPath, error: String(err) });
                }
            });
        });
    },

    async tap(x: number, y: number): Promise<boolean> {
        const nx = x / SCREEN_W;
        const ny = y / SCREEN_H;
        await scheduleTouch(nx, ny, MASK_BEGIN, 1.0);
        await new Promise(r => setTimeout(r, 100));
        await scheduleTouch(nx, ny, MASK_MOVE, 1.0);
        await new Promise(r => setTimeout(r, 50));
        await scheduleTouch(nx, ny, MASK_UP, 0.0);
        return true;
    },

    async swipe(x1: number, y1: number, x2: number, y2: number, steps?: number): Promise<boolean> {
        steps = steps || 20;
        const delay = 500 / steps;
        for (let i = 0; i <= steps; i++) {
            const t = i / steps;
            const nx = (x1 + (x2 - x1) * t) / SCREEN_W;
            const ny = (y1 + (y2 - y1) * t) / SCREEN_H;
            const mask = i === 0 ? MASK_BEGIN : i === steps ? MASK_UP : MASK_MOVE;
            const pressure = i === steps ? 0.0 : 1.0;
            await scheduleTouch(nx, ny, mask, pressure);
            if (i < steps) await new Promise(r => setTimeout(r, delay));
        }
        return true;
    },
};
