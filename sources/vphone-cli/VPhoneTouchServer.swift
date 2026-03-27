import AppKit
import Foundation

/// Unix-domain socket server that drives touch/swipe on the VM view without
/// needing the GUI window focused or even visible.
///
/// Listens at /tmp/vphone-touch.sock.
/// Protocol: newline-delimited JSON.
///   tap:   {"t":"tap",  "x":215, "y":400}
///   swipe: {"t":"swipe","x1":215,"y1":800,"x2":215,"y2":100,"steps":20}
///   home:  {"t":"home"}
/// Response: {"ok":true} or {"ok":false,"error":"..."}
final class VPhoneTouchServer {
    let socketPath: String

    private let screenW: Double
    private let screenH: Double

    // Accessed only on main thread
    private(set) weak var view: VPhoneVirtualMachineView?
    private(set) weak var keyHelper: VPhoneKeyHelper?
    private(set) weak var control: VPhoneControl?

    init(screenWidth: Int, screenHeight: Int, screenScale: Double, vmName: String) {
        screenW = Double(screenWidth) / screenScale
        screenH = Double(screenHeight) / screenScale
        socketPath = "/tmp/vphone-touch-\(vmName).sock"
    }

    func start(view: VPhoneVirtualMachineView, keyHelper: VPhoneKeyHelper?, control: VPhoneControl?) {
        self.view = view
        self.keyHelper = keyHelper
        self.control = control
        DispatchQueue.global(qos: .utility).async { [socketPath] in Self.runListener(socketPath: socketPath) }
        print("[touch-server] listening at \(socketPath)")
    }

    // MARK: - Listener (blocking GCD thread)

    private static func runListener(socketPath: String) {
        try? FileManager.default.removeItem(atPath: socketPath)

        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { print("[touch-server] socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = Darwin.strcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            Darwin.bind(serverFD,
                        UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), addrLen)
        }
        guard bound == 0 else {
            print("[touch-server] bind() failed: \(errno)")
            Darwin.close(serverFD); return
        }
        Darwin.listen(serverFD, 8)

        while true {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            DispatchQueue.global(qos: .utility).async { Self.handleClient(clientFD) }
        }
    }

    private static func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }

        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 1024)
        while !buf.contains(UInt8(ascii: "\n")) {
            let n = Darwin.read(fd, &tmp, tmp.count)
            guard n > 0 else { break }
            buf.append(contentsOf: tmp[..<n])
        }

        guard
            let line = String(data: buf, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let jsonData = line.data(using: .utf8),
            let cmd = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            _ = Darwin.write(fd, "{\"ok\":false,\"error\":\"bad json\"}\n", 31)
            return
        }

        // Hop to main actor via Task (supports async commands like app_launch)
        final class ResultBox: @unchecked Sendable { var value = "{\"ok\":false,\"error\":\"no server\"}\n" }
        let sema = DispatchSemaphore(value: 0)
        let box  = ResultBox()
        DispatchQueue.main.async {
            Task { @MainActor in
                box.value = await VPhoneTouchServerHolder.server?.handleAsync(cmd)
                    ?? "{\"ok\":false,\"error\":\"no server\"}\n"
                sema.signal()
            }
        }
        sema.wait()

        let resp = box.value
        _ = Darwin.write(fd, resp, resp.utf8.count)
    }

    // MARK: - Command handler (main actor, supports async)

    @MainActor
    func handleAsync(_ cmd: [String: Any]) async -> String {
        let t = cmd["t"] as? String ?? ""
        switch t {
        case "app_launch":
            guard let control, let bundleId = cmd["bundle_id"] as? String else {
                return "{\"ok\":false,\"error\":\"missing bundle_id or no control\"}\n"
            }
            do {
                let pid = try await control.appLaunch(bundleId: bundleId)
                return "{\"ok\":true,\"pid\":\(pid)}\n"
            } catch {
                return "{\"ok\":false,\"error\":\"\(error)\"}\n"
            }
        case "app_terminate":
            guard let control, let bundleId = cmd["bundle_id"] as? String else {
                return "{\"ok\":false,\"error\":\"missing bundle_id or no control\"}\n"
            }
            do {
                try await control.appTerminate(bundleId: bundleId)
                return "{\"ok\":true}\n"
            } catch {
                return "{\"ok\":false,\"error\":\"\(error)\"}\n"
            }
        default:
            let ok = handle(cmd)
            return ok ? "{\"ok\":true}\n" : "{\"ok\":false,\"error\":\"unknown command\"}\n"
        }
    }

    @MainActor
    func handle(_ cmd: [String: Any]) -> Bool {
        let t = cmd["t"] as? String ?? ""
        switch t {
        case "tap":
            let x = asDouble(cmd["x"]), y = asDouble(cmd["y"])
            doTap(x: x, y: y)
            return true
        case "swipe":
            doSwipe(x1: asDouble(cmd["x1"]), y1: asDouble(cmd["y1"]),
                    x2: asDouble(cmd["x2"]), y2: asDouble(cmd["y2"]),
                    steps: (cmd["steps"] as? Int) ?? 20)
            return true
        case "home":
            keyHelper?.sendHome()
            return true
        default:
            return false
        }
    }

    // MARK: - Touch (main actor)

    @MainActor
    private func doTap(x: Double, y: Double) {
        guard let view else { return }
        let pt = iosToLocal(x: x, y: y, in: view)
        let ts = ProcessInfo.processInfo.systemUptime
        view.sendTouchEvent(phase: 0, localPoint: pt, timestamp: ts)
        // Schedule move + up on main queue with small delays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
            view?.sendTouchEvent(phase: 1, localPoint: pt, timestamp: ts + 0.05)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak view] in
            view?.sendTouchEvent(phase: 3, localPoint: pt, timestamp: ts + 0.10)
        }
    }

    @MainActor
    private func doSwipe(x1: Double, y1: Double, x2: Double, y2: Double, steps: Int) {
        guard let view else { return }
        let stepDelay = 0.5 / Double(max(steps, 1))
        let ts0 = ProcessInfo.processInfo.systemUptime

        for i in 0 ... steps {
            let delay = stepDelay * Double(i)
            let t = Double(i) / Double(steps)
            let px = x1 + (x2 - x1) * t
            let py = y1 + (y2 - y1) * t
            let phase = i == 0 ? 0 : (i == steps ? 3 : 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view else { return }
                let pt = self.iosToLocal(x: px, y: py, in: view)
                view.sendTouchEvent(phase: phase, localPoint: pt, timestamp: ts0 + delay)
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func iosToLocal(x: Double, y: Double, in view: NSView) -> NSPoint {
        NSPoint(x: (x / screenW) * view.bounds.width,
                y: (1.0 - y / screenH) * view.bounds.height)
    }

    private func asDouble(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int    { return Double(i) }
        return 0
    }
}

// Simple holder — set on main thread before listener starts
enum VPhoneTouchServerHolder {
    nonisolated(unsafe) static weak var server: VPhoneTouchServer?
}
