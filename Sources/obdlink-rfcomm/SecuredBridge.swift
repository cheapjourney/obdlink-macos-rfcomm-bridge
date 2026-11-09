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

    /// Read requests permitted in vehicle mode.
    ///
    /// The Swift gate is deliberately the NARROWER side: it may only allow a
    /// subset of what phase4_1/transport/bridge_gate.py allows, never more.
    /// 2106 was missing here while the Python side already allowed it, so the
    /// release for a single 21 06 read was refused by the bridge - narrower is
    /// safe, but an unintended gap blocks an approved read. Keep every entry
    /// both sides agree on in the parity corpus.
    static let mfdReads: Set<String> = [
        "22F187", "22F18E", "21EF", "2180", "2106", "2107", "226C14", "226C15", "226C1C", "226C20",
    ]

    static let adapterIdentityCommands = ["ATI", "STDI", "STI"]

    enum Verdict {
        case allowed
        case blocked(String)
    }

    /// Commands permitted in adapter-only (and simulation). Everything here is
    /// adapter-local identification or formatting; none of them selects a
    /// protocol, sets an address, or can emit a CAN frame. The first hardware
    /// test needs nothing beyond ATI/STDI/STI, so the list stays minimal.
    static let adapterOnlyCommands: Set<String> = [
        "ATI", "STI", "STDI", "ATZ", "AT@1",
        "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATD0", "ATD1", "ATCAF0", "ATCAF1", "ATRV",
    ]

    /// Deliberately absent from adapter-only: ATSH, ATCRA, STP, STCAF,
    /// STCFCPA, ATAT, STPTO, ATSP6, ATCFC, ATFCSM, ATAL, ATDP. They configure
    /// protocol or addressing and only make sense once the vehicle session is
    /// authorised - they live in vehicle-readonly.

    static func check(_ rawLine: String, mode: BridgeMode) -> Verdict {
        let s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.isEmpty { return .blocked("leere Zeile") }

        if mode.allowsDiagnosticReads {
            // vehicle-readonly: adapter configuration plus allowlisted reads
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
                return mfdReads.contains(s) ? .allowed : .blocked("\(s) ist nicht in der Allowlist")
            }
            if s == "300000" { return .allowed }
            return .blocked("Befehl \(s) ist nicht freigegeben")
        }

        // adapter-only / simulation: identification and formatting only
        if s.hasPrefix("21") || s.hasPrefix("22") || s == "300000" {
            return .blocked("Diagnoseanfrage im Adapter-only-Modus gesperrt")
        }
        if adapterOnlyCommands.contains(s) { return .allowed }
        if s.range(of: atPattern, options: .regularExpression) != nil {
            return .blocked("\(s) ist im Adapter-only-Modus nicht freigegeben "
                            + "(Protokoll-/Adresskonfiguration nur im Fahrzeugmodus)")
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
    ///
    /// Everything up to AND INCLUDING the terminator is consumed. Removing only
    /// the terminator (idx..<idx+1) instead of startIndex..<idx+1 leaves the line
    /// in the buffer, so every later read returns the whole session concatenated
    /// without delimiters. Measured against the real MX+ burst
    /// "ATI\rELM327 v1.4b\r\r>": 41 54 49 0D 45 4C 4D 33 32 37 20 76 31 2E 34 62
    /// 0D 0D 3E must split into "ATI" / "ELM327 v1.4b" / "" and leave nothing.
    ///
    /// The ELM prompt ">" is sent WITHOUT a trailing CR, so it is not a line. It
    /// is consumed here as a response terminator; otherwise it prefixes the next
    /// answer ("&gt;ATI") and the identification parse sees a glued string.
    func popLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        while buffer.first == 0x3E { buffer.removeFirst() }
        guard !buffer.isEmpty else { return nil }
        guard let idx = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) else { return nil }
        let line = String(data: Data(buffer[buffer.startIndex..<idx]), encoding: .ascii) ?? ""
        buffer.removeSubrange(buffer.startIndex..<idx + 1)
        // drop a following LF of a CRLF pair
        if buffer.first == 0x0A { buffer.removeFirst() }
        return line
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
        // Synthetic value: 0x38 is the PRE-activation configuration of the
        // reference vehicle, kept only so the pipeline has something to read.
        // The documented value after the 2026-11-08 activation is 0x78; this
        // simulation must never be quoted as a vehicle measurement.
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
    var verbose = false

    func open(address: String, channel channelID: UInt8) -> Bool {
        guard let dev = IOBluetoothDevice(addressString: address) else {
            note("device not found: \(address)"); return false
        }
        note("device: \(dev.name ?? "?") paired=\(dev.isPaired())")
        if !dev.isConnected() {
            let rc = dev.openConnection()
            note("baseband connect rc=\(rc)")
            guard rc == kIOReturnSuccess else {
                note("baseband connection failed"); return false
            }
            // Same settle delay as the TCP path in main.swift: the MX+ needs a
            // moment after the baseband link before SPP answers.
            Thread.sleep(forTimeInterval: 0.8)
        }
        guard dev.isConnected() else { note("baseband connection failed - device not connected"); return false }
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
        if verbose { note("writeSync \(rc) for \(bytes.count) bytes") }
        if rc != kIOReturnSuccess { throw TransportError.io("writeSync rc=\(rc)") }
    }

    /// Polls the buffer. IOBluetooth delivers delegate callbacks through the
    /// run loop of the thread that opened the channel, so waiting on a
    /// condition here would block exactly the loop that has to deliver them.
    func waitForLine(timeout: Double) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lines.popLine() { return line }
            if isClosed { throw TransportError.closed }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let line = lines.popLine() { return line }
        if isClosed { throw TransportError.closed }
        throw TransportError.timeout(partial: lines.partial)
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        if verbose { note("rx \(dataLength) bytes") }
        lines.append(Data(bytes: dataPointer, count: dataLength))
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        note("RFCOMM channel closed by peer")
        isClosed = true
    }
}

// MARK: - the NDJSON bridge

final class SecuredBridge {
    let socketPath: String
    let mode: BridgeMode
    let transport: AdapterTransport
    let vehicleToken: String?
    let verbose: Bool

    private var listenFD: Int32 = -1
    private var adapterName = ""
    private var stnName = ""
    private var identified = false

    init(socketPath: String, mode: BridgeMode, transport: AdapterTransport,
         vehicleToken: String?, verbose: Bool = false) {
        self.socketPath = socketPath
        self.mode = mode
        self.transport = transport
        self.vehicleToken = vehicleToken
        self.verbose = verbose
    }

    /// One line per command actually handed to the adapter. Tests read this to
    /// prove what the bridge sends on its own, and what a client got through.
    private func logTx(_ command: String) {
        guard verbose else { return }
        note("tx: \(command)")
    }

    /// Runs on the client thread, after the main run loop is pumping — the
    /// RFCOMM callbacks can only arrive then.
    func ensureIdentified() throws {
        guard !identified else { return }
        try identify()
        identified = true
    }

    func identify() throws {
        // Adapter-local queries only. The adapter echoes by default (we do not
        // send ATE0 - it is not needed for identification), so a raw line can be
        // "ATI" followed by the answer on the next line, or both glued together.
        // Both forms are handled, and the echo is never reported as an answer.
        for cmd in ["ATI", "STDI", "STI"] {
            if case .blocked(let reason) = Gate.check(cmd, mode: mode) {
                throw TransportError.io("identity command \(cmd) blocked: \(reason)")
            }
            logTx(cmd)
            try transport.write(cmd + "\r")
            let answer = try answer(for: cmd, timeout: 2.0)
            switch cmd {
            case "ATI":
                adapterName = answer
            case "STDI":
                if !answer.isEmpty { adapterName = answer }
            case "STI":
                stnName = answer
            default:
                break
            }
        }
        if adapterName.isEmpty || stnName.isEmpty {
            throw TransportError.io("adapter did not identify (adapter=\(adapterName) stn=\(stnName))")
        }
    }

    /// Reads the first line that is neither the echoed command nor the prompt.
    private func answer(for cmd: String, timeout: Double) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            let raw = try transport.waitForLine(timeout: remaining)
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == ">" { continue }
            let upper = text.uppercased()
            if upper == cmd { continue }                       // pure echo
            if upper.hasPrefix(cmd) {                          // echo glued to answer
                text = String(text.dropFirst(cmd.count)).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
            }
            return text
        }
        return ""
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

        // The accept loop must NOT run on the main thread: IOBluetooth delivers
        // RFCOMM delegate callbacks through the run loop of the thread that
        // opened the channel. With the main thread blocked in accept(), no
        // callback ever fires and the adapter looks silent (writeSync returns 0,
        // zero bytes arrive). So: accept on a background thread, keep the main
        // run loop pumping.
        let acceptThread = Thread { [self] in
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { continue }
                handle(client: client)
                close(client)
            }
        }
        acceptThread.stackSize = 512 * 1024
        acceptThread.start()

        while true {
            RunLoop.current.run(until: Date().addingTimeInterval(3600))
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
        do {
            try ensureIdentified()
        } catch {
            send(["type": "error", "reason": "adapter identification failed"])
            return
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
                        logTx(data.trimmingCharacters(in: .whitespacesAndNewlines))
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
