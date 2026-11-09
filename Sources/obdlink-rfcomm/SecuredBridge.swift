// Secured bridge: Unix-domain socket + newline-delimited JSON for phase 4.1.
//
// Additive to the existing TCP relay in main.swift. When --unix-socket is given,
// this path is used instead: the TCP listener is not started at all, so the raw
// byte channel cannot be used to bypass the command gate.
//
// Protocol v1 (mirrors phase4_1/transport/macos_bridge.py):
//   -> {"type":"hello","protocol":1,"mode":"adapter-only"|"vehicle-readonly"}
//   <- {"type":"hello_ack","protocol":1,"adapter":"…","stn":"…","mode":"…"}
//   -> {"type":"write","data":"ATI\r"}      <- {"type":"ok"} | {"type":"blocked","reason":"…"}
//   -> {"type":"read","timeout":2.0}        <- {"type":"line","data":"…"} | {"type":"timeout","partial":"…"} | {"type":"closed"}
//   -> {"type":"close"}                     <- {"type":"ok"}
//
// Design rules:
//   * the gate lives here, in the bridge — the Python client has its own copy
//   * no mode can be upgraded at runtime; the mode is fixed at startup
//   * identity in hello_ack comes from the adapter (ATI/STDI/STI), never invented
//   * --simulate uses a fake adapter and marks the ack with "simulated": true

import Foundation
import IOBluetooth
import Darwin

enum BridgeMode: String {
    case simulation = "simulation"
    case adapterOnly = "adapter-only"
    case vehicleReadonly = "vehicle-readonly"

    var isSimulated: Bool { self == .simulation }
    /// Mode announced on the wire. A simulation bridge presents itself as an
    /// adapter-only bridge — it emulates that mode, it does not invent a fourth.
    var wireMode: String { self == .vehicleReadonly ? "vehicle-readonly" : "adapter-only" }

    /// Only the vehicle mode may put diagnostic requests on the bus. Simulation
    /// stays as strict as adapter-only on purpose.
    var allowsDiagnosticReads: Bool { self == .vehicleReadonly }
}

// MARK: - command gate (kept in step with phase4_1/transport/bridge_gate.py)

struct Gate {
    /// Adapter commands this bridge accepts. Every entry is adapter-local: it
    /// configures the device, none of them emits a CAN frame on its own.
    ///   STP 33      ISO 15765, 11-bit, 500 kbit/s (protocol preset)
    ///   STCAF 0     normal addressing
    ///   STCFCPA     flow-control pair for a response ID that is not request+8
    ///   ATAT0       fixed response timing instead of adaptive
    ///   STPTO       adapter-side response timeout in ms
    ///   ATD0/ATD1   DLC column on/off
    ///   STDI        STN device identification (adapter identity)
    static let atPattern =
        "^(ATZ|ATE[01]|ATL[01]|ATS[01]|ATH[01]|ATD[01]|ATSP6|ATCAF[01]|ATCFC[01]|"
        + "ATFCSM[0-2]|ATAL|ATI|STI|STDI|ATDP|ATRV|ATSH [0-9A-F]{3,8}|ATCRA [0-9A-F]{3,8}|"
        + "STP 33|STCAF 0|STCFCPA [0-9A-F]{3,8}, ?[0-9A-F]{3,8}|ATAT0|STPTO [0-9]{1,5})$"

    /// Read requests permitted in vehicle mode. Subset of phase3's MFD entry.
    static let mfdReads: Set<String> = [
        "22F187", "22F18E", "21EF", "2180", "226C14", "226C15", "226C1C", "226C20",
    ]

    static let adapterIdentityCommands = ["ATI", "STDI", "STI"]

    enum Verdict {
        case allowed
        case blocked(String)
    }

    static func check(_ rawLine: String, mode: BridgeMode) -> Verdict {
        let s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.isEmpty { return .blocked("leere Zeile") }

        if s.range(of: atPattern, options: .regularExpression) != nil {
            if s.hasPrefix("STPTO ") {
                let parts = s.split(separator: " ")
                if parts.count == 2, let ms = Int(parts[1]), ms >= 1, ms <= 65535 {
                    return .allowed
                }
                return .blocked("STPTO außerhalb 1..65535")
            }
            return .allowed
        }
        if s.hasPrefix("21") || s.hasPrefix("22") {
            guard mode.allowsDiagnosticReads else {
                return .blocked("Diagnoseanfrage im Adapter-only-Modus gesperrt")
            }
            return mfdReads.contains(s) ? .allowed : .blocked("\(s) ist nicht in der Allowlist")
        }
        if s == "300000" {
            guard mode.allowsDiagnosticReads else {
                return .blocked("Flow-Control im Adapter-only-Modus gesperrt")
            }
            return .allowed
        }
        return .blocked("Befehl \(s) ist nicht freigegeben")
    }
}

// MARK: - line assembly for adapter answers

final class LineBuffer {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
    }

    /// Next complete line (terminated by CR or LF), without the terminator.
    func popLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let idx = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) else { return nil }
        let line = buffer.prefix(upTo: idx)
        var cut = buffer.startIndex..<buffer.endIndex
        cut = idx..<idx + 1
        buffer.removeSubrange(cut)
        // drop a following LF of a CRLF pair
        if buffer.first == 0x0A { buffer.removeFirst() }
        return String(data: line, encoding: .ascii) ?? ""
    }

    var partial: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .ascii) ?? ""
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}

// MARK: - transports

protocol AdapterTransport: AnyObject {
    func write(_ text: String) throws
    func waitForLine(timeout: Double) throws -> String
    var isClosed: Bool { get }
}

enum TransportError: Error {
    case timeout(partial: String)
    case closed
    case io(String)
}

/// Fake adapter for tests. Answers like an OBDLink behind an STN chip.
final class SimulatedAdapter: AdapterTransport {
    private let queue = NSMutableArray()
    private let cond = NSCondition()
    private(set) var isClosed = false

    func write(_ text: String) throws {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reply: String
        switch true {
        case command == "ATZ", command == "ATI": reply = "ELM327 v1.4b"
        case command == "STDI": reply = "OBDLink MX+ (simulated)"
        case command == "STI": reply = "STN2255 v5.10.3"
        case command.hasPrefix("AT@"): reply = "OBD SOLUTIONS LLC"
        case command == "ATRV": reply = "12.6V"
        case command == "22F187": reply = "62 F1 87 32 35 39 31 35 36 32 34 34 52"
        case command == "226C1C": reply = "62 6C 1C 38"
        case command.hasPrefix("AT"), command.hasPrefix("ST"): reply = "OK"
        default: reply = "?"
        }
        cond.lock()
        queue.add(reply)
        cond.broadcast()
        cond.unlock()
    }

    func waitForLine(timeout: Double) throws -> String {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while queue.count == 0 {
            if isClosed { cond.unlock(); throw TransportError.closed }
            if !cond.wait(until: deadline) { break }
        }
        if queue.count == 0 { cond.unlock(); throw TransportError.timeout(partial: "") }
        let line = queue.object(at: 0) as! String
        queue.removeObject(at: 0)
        cond.unlock()
        return line
    }
}

/// Real RFCOMM transport. Same connect sequence as the TCP relay in main.swift.
final class RfcommTransport: NSObject, AdapterTransport, IOBluetoothRFCOMMChannelDelegate {
    private let lines = LineBuffer()
    private let cond = NSCondition()
    private var channel: IOBluetoothRFCOMMChannel?
    private(set) var isClosed = false

    func open(address: String, channel channelID: UInt8) -> Bool {
        guard let dev = IOBluetoothDevice(addressString: address) else {
            note("device not found: \(address)"); return false
        }
        note("device: \(dev.name ?? "?") paired=\(dev.isPaired())")
        if !dev.isConnected() {
            let rc = dev.openConnection()
            guard rc == kIOReturnSuccess else {
                note("baseband connect rc=\(rc)"); note("baseband connection failed"); return false
            }
        }
        var ch: IOBluetoothRFCOMMChannel? = nil
        let rc = dev.openRFCOMMChannelSync(&ch, withChannelID: BluetoothRFCOMMChannelID(channelID), delegate: self)
        guard rc == kIOReturnSuccess, let opened = ch else {
            note("RFCOMM channel \(channelID) open failed rc=\(rc)"); return false
        }
        channel = opened
        note("RFCOMM channel \(channelID) open")
        return true
    }

    func write(_ text: String) throws {
        guard let ch = channel else { throw TransportError.closed }
        var bytes = Array(text.utf8)
        let rc = ch.writeSync(&bytes, length: UInt16(bytes.count))
        if rc != kIOReturnSuccess { throw TransportError.io("writeSync rc=\(rc)") }
    }

    func waitForLine(timeout: Double) throws -> String {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = lines.popLine() { cond.unlock(); return line }
            if isClosed { cond.unlock(); throw TransportError.closed }
            if !cond.wait(until: deadline) {
                let partial = lines.partial
                cond.unlock()
                throw TransportError.timeout(partial: partial)
            }
        }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        cond.lock()
        lines.append(Data(bytes: dataPointer, count: dataLength))
        cond.broadcast()
        cond.unlock()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        cond.lock(); isClosed = true; cond.broadcast(); cond.unlock()
    }
}

// MARK: - the NDJSON bridge

final class SecuredBridge {
    let socketPath: String
    let mode: BridgeMode
    let transport: AdapterTransport
    let vehicleToken: String?

    private var listenFD: Int32 = -1
    private var adapterName = ""
    private var stnName = ""

    init(socketPath: String, mode: BridgeMode, transport: AdapterTransport, vehicleToken: String?) {
        self.socketPath = socketPath
        self.mode = mode
        self.transport = transport
        self.vehicleToken = vehicleToken
    }

    func identify() throws {
        // Adapter-local queries only. In adapter-only mode these are the only
        // frames this program ever sends on its own.
        for cmd in ["ATI", "STDI", "STI"] {
            if case .blocked(let reason) = Gate.check(cmd, mode: mode) {
                throw TransportError.io("identity command \(cmd) blocked: \(reason)")
            }
            try transport.write(cmd + "\r")
            let answer = try transport.waitForLine(timeout: 2.0)
            switch cmd {
            case "ATI": adapterName = answer
            case "STDI": if !answer.isEmpty { adapterName = answer }
            case "STI": stnName = answer
            default: break
            }
        }
    }

    func run() -> Never {
        unlink(socketPath)
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fail("unix socket() failed", code: 6) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            fail("socket path too long", code: 2)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
            dst[pathBytes.count] = 0
        }
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else { fail("unix bind failed on \(socketPath)", code: 6) }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 1) == 0 else { fail("unix listen failed", code: 6) }

        print("READY \(socketPath) mode=\(mode.rawValue) simulated=\(mode.isSimulated)")
        fflush(stdout)

        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        let f = fdopen(client, "r+")
        guard let f = f else { return }
        defer { fclose(f) }

        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            _ = line.withCString { fputs($0, f) }
            fflush(f)
        }

        guard let first = readLine(from: f), let hello = parse(first) else {
            send(["type": "error", "reason": "invalid json"]); return
        }
        guard hello["type"] as? String == "hello" else {
            send(["type": "error", "reason": "hello expected"]); return
        }
        guard (hello["protocol"] as? Int) == 1 else {
            send(["type": "error", "reason": "protocol mismatch"]); return
        }
        guard (hello["mode"] as? String) == mode.wireMode else {
            send(["type": "error", "reason": "mode mismatch"]); return
        }
        if mode == .vehicleReadonly {
            guard let expected = vehicleToken, (hello["vehicle_token"] as? String) == expected else {
                send(["type": "error", "reason": "token missing"]); return
            }
        }
        send(["type": "hello_ack", "protocol": 1, "adapter": adapterName,
              "stn": stnName, "mode": mode.wireMode, "simulated": mode.isSimulated])

        while let raw = readLine(from: f), let msg = parse(raw) {
            switch msg["type"] as? String {
            case "write":
                let data = (msg["data"] as? String) ?? ""
                switch Gate.check(data, mode: mode) {
                case .blocked(let reason):
                    send(["type": "blocked", "reason": reason])
                case .allowed:
                    do {
                        try transport.write(data.hasSuffix("\r") ? data : data + "\r")
                        send(["type": "ok"])
                    } catch {
                        send(["type": "error", "reason": "write failed"])
                    }
                }
            case "read":
                let timeout = (msg["timeout"] as? Double) ?? 2.0
                do {
                    let line = try transport.waitForLine(timeout: timeout)
                    send(["type": "line", "data": line])
                } catch TransportError.timeout(let partial) {
                    send(["type": "timeout", "partial": partial])
                } catch {
                    send(["type": "closed"])
                }
            case "close":
                send(["type": "ok"])
                return
            default:
                send(["type": "error", "reason": "unknown message"])
            }
        }
    }

    private func readLine(from f: UnsafeMutablePointer<FILE>) -> String? {
        var line = [CChar](repeating: 0, count: 8192)
        guard fgets(&line, Int32(line.count), f) != nil else { return nil }
        return String(cString: line).trimmingCharacters(in: .newlines)
    }

    private func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
