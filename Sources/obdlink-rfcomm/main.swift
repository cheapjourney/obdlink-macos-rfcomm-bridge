// obdlink-rfcomm: expose a Bluetooth SPP service as a loopback TCP socket.
//
// Why this exists: macOS keeps a persisted /dev/cu.<name> device for a paired SPP
// adapter, but that port object can stop initiating connections after the first
// session - it opens instantly, returns zero bytes, and bluetoothd never logs a
// connection attempt. Opening the RFCOMM channel directly through IOBluetooth
// works reliably and survives repeated client connect/disconnect cycles.
//
// Design rules:
//   * binds 127.0.0.1 only - never a wildcard address
//   * one client at a time; the RFCOMM channel stays open across clients
//   * no credentials, no pairing state, no device addresses compiled in
//   * --self-test runs without any Bluetooth hardware

import Foundation
import IOBluetooth
import Darwin

// MARK: - configuration

struct Config {
    var address: String = ""
    var port: UInt16 = 35100
    var channel: UInt8 = 1
    var verbose = false
    var selfTest = false
    var showHelp = false
    // phase 4.1 secured mode (additive; without --unix-socket nothing changes)
    var unixSocket: String? = nil
    var mode: BridgeMode = .adapterOnly
    var vehicleToken: String? = nil
    var simulateTransport = false
}

let usage = """
obdlink-rfcomm - Bluetooth SPP to loopback TCP bridge (macOS)

USAGE
  obdlink-rfcomm --address AA-BB-CC-DD-EE-FF [options]

REQUIRED
  -a, --address <mac>     Bluetooth address of the paired SPP device
                          (also read from $OBDLINK_ADDRESS)

OPTIONS
  -p, --port <n>          TCP port to listen on, 127.0.0.1 only (default 35100)
                          (also read from $OBDLINK_PORT)
  -c, --channel <n>       RFCOMM channel, 1-30 (default 1)
  -v, --verbose           log connection detail to stderr
      --self-test         run loopback/TCP tests without Bluetooth and exit

SECURED MODE (phase 4.1, Unix socket + newline-delimited JSON)
      --unix-socket <path>  serve the JSON protocol on this socket instead of raw TCP
      --mode <m>            simulation | adapter-only | vehicle-readonly
                            (default adapter-only; fixed for the process lifetime)
      --simulate            shorthand for --mode simulation (fake adapter, no Bluetooth)
      --vehicle-token <t>   required in vehicle-readonly; must match the client's token
      --simulate-transport  test-only: fake adapter with a real gate (no Bluetooth)

In secured mode the raw TCP listener is NOT started, so it cannot bypass the
command gate. Socket directory 0700, socket 0600.

  -h, --help              show this help

EXIT CODES
  0 success   2 bad usage   3 device not found   4 baseband connect failed
  5 RFCOMM channel open failed   6 TCP bind/listen failed   75 SPP channel closed

The TCP listener is bound to 127.0.0.1 and is not reachable from the network.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func parseConfig(_ argv: [String]) -> Config {
    var cfg = Config()
    cfg.address = ProcessInfo.processInfo.environment["OBDLINK_ADDRESS"] ?? ""
    if let p = ProcessInfo.processInfo.environment["OBDLINK_PORT"], let v = UInt16(p) { cfg.port = v }
    if let c = ProcessInfo.processInfo.environment["OBDLINK_CHANNEL"], let v = UInt8(c) { cfg.channel = v }

    var i = 1
    while i < argv.count {
        let arg = argv[i]
        func value(_ name: String) -> String {
            guard i + 1 < argv.count else { fail("missing value for \(name)", code: 2) }
            i += 1
            return argv[i]
        }
        switch arg {
        case "-a", "--address": cfg.address = value(arg)
        case "-p", "--port":
            let raw = value(arg)
            guard let v = UInt16(raw), v > 0 else { fail("invalid port: \(raw)", code: 2) }
            cfg.port = v
        case "-c", "--channel":
            let raw = value(arg)
            guard let v = UInt8(raw), v >= 1, v <= 30 else { fail("invalid channel: \(raw)", code: 2) }
            cfg.channel = v
        case "--unix-socket": cfg.unixSocket = value(arg)
        case "--mode":
            let raw = value(arg)
            guard let m = BridgeMode(rawValue: raw) else {
                fail("invalid mode: \(raw) (simulation|adapter-only|vehicle-readonly)", code: 2)
            }
            cfg.mode = m
        case "--simulate": cfg.mode = .simulation
        case "--simulate-transport": cfg.simulateTransport = true
        case "--vehicle-token": cfg.vehicleToken = value(arg)
        case "-v", "--verbose": cfg.verbose = true
        case "--self-test": cfg.selfTest = true
        case "-h", "--help": cfg.showHelp = true
        default: fail("unknown option: \(arg)\n\n\(usage)", code: 2)
        }
        i += 1
    }
    return cfg
}

let addressPattern = "^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$"

func normaliseAddress(_ raw: String) -> String {
    let upper = raw.uppercased()
    if upper.range(of: addressPattern, options: .regularExpression) != nil { return upper }
    // Accept colon-separated input and convert it.
    let colon = "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
    if upper.range(of: colon, options: .regularExpression) != nil {
        return upper.replacingOccurrences(of: ":", with: "-")
    }
    fail("invalid Bluetooth address: \(raw) (expected AA-BB-CC-DD-EE-FF)", code: 2)
}

// MARK: - loopback listener

func makeLoopbackListener(port: UInt16) -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket() failed", code: 6) }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        close(fd)
        fail("bind failed on 127.0.0.1:\(port) (port in use?)", code: 6)
    }
    guard listen(fd, 1) == 0 else {
        close(fd)
        fail("listen() failed", code: 6)
    }

    // Read back the effective port (relevant when port 0 was requested).
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return (fd, UInt16(bigEndian: bound.sin_port))
}

func peerDescription(_ fd: Int32) -> String {
    var peer = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
    }
    guard rc == 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var inAddr = peer.sin_addr
    inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf) + ":" + String(UInt16(bigEndian: peer.sin_port))
}

// MARK: - self test (no Bluetooth, no hardware)

struct TestReport {
    var passed = 0
    var failed = 0
    mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        if ok { passed += 1 } else { failed += 1 }
    }
}

func runSelfTest(port: UInt16) -> Never {
    var report = TestReport()
    print("obdlink-rfcomm self-test (no Bluetooth, no serial port)\n")

    // 1. bind to loopback on an ephemeral port
    let listener = makeLoopbackListener(port: 0)
    report.check("listener binds", listener.fd >= 0, "port \(listener.port)")

    // 2. verify the bind address is loopback, not a wildcard
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &len) }
    }
    let boundAddr = rc == 0 ? String(cString: inet_ntoa(bound.sin_addr)) : "error"
    report.check("bound to 127.0.0.1 only", boundAddr == "127.0.0.1", boundAddr)

    // 3. accept one client
    let client = socket(AF_INET, SOCK_STREAM, 0)
    var target = sockaddr_in()
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = listener.port.bigEndian
    target.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    } == 0
    report.check("client connects", connected)

    var serverFD: Int32 = -1
    if connected {
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        serverFD = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener.fd, $0, &plen) }
        }
        report.check("accept returns a socket", serverFD >= 0)
        if serverFD >= 0 {
            report.check("peer address is loopback", peerDescription(serverFD).hasPrefix("127.0.0.1"),
                         peerDescription(serverFD))
        }
    }

    // 4. relay one payload in both directions
    if serverFD >= 0 {
        let outbound = Array("ATI\r".utf8)
        let wrote = outbound.withUnsafeBytes { write(client, $0.baseAddress, outbound.count) }
        report.check("client -> bridge write", wrote == outbound.count)

        var buffer = [UInt8](repeating: 0, count: 64)
        let got = read(serverFD, &buffer, buffer.count)
        let received = got > 0 ? String(bytes: buffer[0..<got], encoding: .utf8) ?? "" : ""
        report.check("bridge receives payload", received == "ATI\r", received)

        _ = "ELM327 v1.4b\r\r>".withCString { write(serverFD, $0, strlen($0)) }
        var back = [UInt8](repeating: 0, count: 64)
        let backN = read(client, &back, back.count)
        let response = backN > 0 ? String(bytes: back[0..<backN], encoding: .utf8) ?? "" : ""
        report.check("client receives payload", response.hasPrefix("ELM327"), response)
    }

    // 5. close and verify the port is released
    if serverFD >= 0 { close(serverFD) }
    close(client)
    close(listener.fd)

    let reuse = makeLoopbackListener(port: listener.port)
    report.check("port released after close", reuse.fd >= 0, "re-bound \(reuse.port)")
    close(reuse.fd)

    print("\n\(report.passed) passed, \(report.failed) failed")
    exit(report.failed == 0 ? 0 : 1)
}

// MARK: - bridge

final class Relay: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private let verbose: Bool

    init(verbose: Bool) { self.verbose = verbose }

    func attach(_ fd: Int32) {
        lock.lock(); clientFD = fd; lock.unlock()
    }

    func detach() {
        lock.lock(); clientFD = -1; lock.unlock()
    }

    private func forward(toClient bytes: UnsafeRawPointer, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard clientFD >= 0 else { return }
        var offset = 0
        while offset < count {
            let written = Darwin.write(clientFD, bytes.advanced(by: offset), count - offset)
            if written <= 0 { break }
            offset += written
        }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        if verbose { note("rx \(dataLength) bytes from adapter") }
        forward(toClient: UnsafeRawPointer(dataPointer), count: dataLength)
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        note("SPP channel closed by peer")
        exit(75)
    }
}

// MARK: - main

let cfg = parseConfig(CommandLine.arguments)

if cfg.showHelp {
    print(usage)
    exit(0)
}

if cfg.selfTest {
    runSelfTest(port: cfg.port)
}

// MARK: secured mode (phase 4.1) - takes precedence, never starts the TCP relay

if let socketPath = cfg.unixSocket {
    if cfg.mode != .simulation && !cfg.simulateTransport && cfg.address.isEmpty {
        fail("--address is required unless the transport is simulated", code: 2)
    }
    if cfg.mode == .vehicleReadonly, (cfg.vehicleToken ?? "").isEmpty {
        fail("--vehicle-token is required in vehicle-readonly mode", code: 2)
    }
    let transport: AdapterTransport
    if cfg.mode == .simulation || cfg.simulateTransport {
        transport = SimulatedAdapter()
    } else {
        let rfcomm = RfcommTransport()
        guard rfcomm.open(address: normaliseAddress(cfg.address), channel: cfg.channel) else {
            fail("RFCOMM channel \(cfg.channel) open failed", code: 5)
        }
        transport = rfcomm
    }
    let bridge = SecuredBridge(socketPath: socketPath, mode: cfg.mode,
                               transport: transport, vehicleToken: cfg.vehicleToken)
    do {
        try bridge.identify()
    } catch {
        fail("adapter identification failed: \(error)", code: 5)
    }
    signal(SIGPIPE, SIG_IGN)
    bridge.run()
}

guard !cfg.address.isEmpty else {
    fail("no Bluetooth address given\n\n\(usage)", code: 2)
}
let deviceAddress = normaliseAddress(cfg.address)

signal(SIGPIPE, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { note("interrupted"); exit(0) }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { note("terminated"); exit(0) }
sigterm.resume()

guard let device = IOBluetoothDevice(addressString: deviceAddress) else {
    fail("device not found: \(deviceAddress)", code: 3)
}
note("device: \(device.name ?? "(unnamed)") paired=\(device.isPaired())")

if !device.isConnected() {
    let rc = device.openConnection()
    note("baseband connect rc=\(rc)")
    Thread.sleep(forTimeInterval: 0.8)
}
guard device.isConnected() else {
    fail("baseband connection failed - is the device awake and in range?", code: 4)
}

let relay = Relay(verbose: cfg.verbose)
var channel: IOBluetoothRFCOMMChannel?
let channelRC = device.openRFCOMMChannelSync(&channel, withChannelID: cfg.channel, delegate: relay)
guard channelRC == kIOReturnSuccess, let spp = channel else {
    fail("RFCOMM channel \(cfg.channel) open failed (rc=\(channelRC))", code: 5)
}
note("RFCOMM channel \(cfg.channel) open")

let listener = makeLoopbackListener(port: cfg.port)
print("READY 127.0.0.1:\(listener.port)")
fflush(stdout)

Thread.detachNewThread {
    while true {
        let client = accept(listener.fd, nil, nil)
        if client < 0 { usleep(100_000); continue }
        relay.attach(client)
        note("client connected from \(peerDescription(client))")

        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(client, &buffer, buffer.count)
                if n <= 0 { break }
                var payload = Array(buffer[0..<n])
                if spp.writeSync(&payload, length: UInt16(n)) != kIOReturnSuccess { break }
            }
            note("client disconnected")
            close(client)
            relay.detach()
        }
    }
}

RunLoop.current.run()
