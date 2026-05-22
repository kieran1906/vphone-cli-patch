import frida
import subprocess
import time

UDID = "0000FE01-29E105426CE10DD4"

# JS to inject touch events via IOHIDEvent
TOUCH_SCRIPT = """
var IOHIDEvent = ObjC.classes.IOHIDEvent;
var UIApplication = ObjC.classes.UIApplication;

function sendTouch(x, y, phase) {
    // phase: 1=began, 2=moved, 3=ended
    var event = IOHIDEvent.eventWithType_senderID_timestamp_(
        ObjC.classes.IOHIDEvent.buttonMask(),
        0, 0
    );
    // Use GraphicsServices touch injection
    var GSEventRef = Memory.alloc(256);
    send({type: 'touch', x: x, y: y, phase: phase});
}

rpc.exports = {
    tap: function(x, y) {
        var script = `
            var ev = IOHIDEventCreateDigitizerEvent(
                kCFAllocatorDefault, mach_absolute_time(),
                kIOHIDDigitizerTransducerTypeFinger, 1, 1,
                kIOHIDEventOptionIsAbsolute,
                ` + x + ` / 390.0, ` + y + ` / 844.0, 0, 1, 1, 0, 0, 0
            );
        `;
        // Use private SpringBoard API for touch injection
        var SBUIController = ObjC.classes.SBUIController;
        if (SBUIController) {
            send({type: 'log', msg: 'SBUIController available'});
        }

        // Use HIDEvent via IOKit
        var GSEvent = Module.findExportByName('GraphicsServices', 'GSSendEvent');
        if (GSEvent) {
            send({type: 'log', msg: 'GSEvent available'});
        }
        send({type: 'log', msg: 'tap called at ' + x + ',' + y});
    }
};
"""

# Simpler direct approach using Frida + IOHIDEvent injection
PROBE_SCRIPT = """
var results = {};

// Search all loaded modules for an export
function findInAll(sym) {
    try {
        var mods = Process.enumerateModules();
        for (var i = 0; i < mods.length; i++) {
            try {
                var exports = mods[i].enumerateExports();
                for (var j = 0; j < exports.length; j++) {
                    if (exports[j].name === sym) {
                        return {addr: exports[j].address.toString(), mod: mods[i].name};
                    }
                }
            } catch(e2) {}
        }
    } catch(e) {}
    return null;
}

var symsToFind = [
    'BKSHIDEventSendToFocusedProcess',
    'BKSHIDEventSetDigitizerInfo',
    'BKSHIDEventSetDigitizerInfoWithSubEventInfos',
    'IOHIDEventCreateDigitizerEvent',
    'IOHIDEventCreateDigitizerFingerEvent',
    'IOHIDEventSetFloatValue',
    'mach_absolute_time',
];

symsToFind.forEach(function(sym) {
    results[sym] = findInAll(sym);
});

rpc.exports = {
    probe: function() { return results; }
};
"""

def screenshot(port=2231):
    """Take screenshot using idevicescreenshot"""
    subprocess.run(
        ["./vphone-cli/.limd/bin/idevicescreenshot", "-u", UDID, "screenshot.png"],
        capture_output=True
    )
    print("Screenshot saved: screenshot.png")


def main():
    device = frida.get_device(UDID)
    print(f"Connected: {device.name}")

    # Attach to SpringBoard to inject touches
    session = device.attach("SpringBoard")
    script = session.create_script(PROBE_SCRIPT)
    script.load()

    result = script.exports_sync.probe()
    print("Available APIs:", result)

    script.unload()
    session.detach()


if __name__ == "__main__":
    main()
