// Self-test block for the socket lifecycle. Runs without Bluetooth, without an
// adapter and without a vehicle: only temporary directories and AF_UNIX nodes.

import Foundation
import Darwin

private func makeSocketNode(_ path: String, listen: Bool) -> Int32? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in bytes.enumerated() { dst[i] = b }
        dst[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { close(fd); return nil }
    if listen && Darwin.listen(fd, 1) != 0 { close(fd); return nil }
    return fd
}

func runSocketLifecycleSelfTests(_ report: inout TestReport) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("obd-lc-\(getpid())").path
    let path = root + "/bridge.sock"
    try? fm.removeItem(atPath: root)
    defer { try? fm.removeItem(atPath: root) }

    let lc = SocketLifecycle(socketPath: path)
    var ok = true
    do {
        try lc.prepareDirectory()
        try lc.acquireLock()
    } catch {
        ok = false
        report.check("socket lifecycle setup", false, "\(error)")
    }
    if ok {
        var st = stat()
        _ = lstat(root, &st)
        report.check("new socket directory is 0700", (st.st_mode & 0o777) == 0o700,
                     String(st.st_mode & 0o777, radix: 8))

        let second = SocketLifecycle(socketPath: path)
        var secondRefused = false
        do { try second.acquireLock() } catch { secondRefused = true }
        report.check("second instance refused by lock", secondRefused)
    }

    // a symlink planted at the lock path must not be followed
    let lockRoot = root + "/locklink"
    try? fm.createDirectory(atPath: lockRoot, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    let lockTarget = lockRoot + "/real.lock"
    fm.createFile(atPath: lockTarget, contents: Data())
    _ = symlink(lockTarget, lockRoot + "/bridge.sock.lock")
    let symLock = SocketLifecycle(socketPath: lockRoot + "/bridge.sock")
    var refusedLockLink = false
    do { try symLock.acquireLock() } catch { refusedLockLink = true }
    report.check("symlink at lock path is refused", refusedLockLink)

    // a regular file at the socket path must never be deleted
    let filePath = root + "/plain.sock"
    fm.createFile(atPath: filePath, contents: Data("keep me".utf8))
    let fileLC = SocketLifecycle(socketPath: filePath)
    var refusedFile = false
    do { try fileLC.clearStaleSocket() } catch { refusedFile = true }
    report.check("regular file is refused and kept",
                 refusedFile && fm.fileExists(atPath: filePath))

    // a symlink must be refused and never followed
    let target = root + "/target.txt"
    fm.createFile(atPath: target, contents: Data("target".utf8))
    let linkPath = root + "/link.sock"
    _ = symlink(target, linkPath)
    let linkLC = SocketLifecycle(socketPath: linkPath)
    var refusedLink = false
    do { try linkLC.clearStaleSocket() } catch { refusedLink = true }
    report.check("symlink is refused and kept",
                 refusedLink && (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil
                    && fm.fileExists(atPath: target))

    // a stale socket (bound, not listening) is removed
    let stalePath = root + "/stale.sock"
    if let fd = makeSocketNode(stalePath, listen: false) {
        close(fd)
        let staleLC = SocketLifecycle(socketPath: stalePath)
        var cleared = false
        do { try staleLC.clearStaleSocket(); cleared = !fm.fileExists(atPath: stalePath) }
        catch { cleared = false }
        report.check("stale socket is removed", cleared)
    } else {
        report.check("stale socket is removed", false, "could not create node")
    }

    // a live socket must never be removed
    let livePath = root + "/live.sock"
    if let fd = makeSocketNode(livePath, listen: true) {
        let liveLC = SocketLifecycle(socketPath: livePath)
        var refusedLive = false
        do { try liveLC.clearStaleSocket() } catch { refusedLive = true }
        report.check("live socket is refused and kept",
                     refusedLive && fm.fileExists(atPath: livePath))
        close(fd)
    } else {
        report.check("live socket is refused and kept", false, "could not create node")
    }

    // ownership: release removes our own node, and nothing that replaced it
    let ownPath = root + "/own.sock"
    let ownLC = SocketLifecycle(socketPath: ownPath)
    if let fd = makeSocketNode(ownPath, listen: true) {
        try? ownLC.recordBoundSocket()
        _ = chmod(ownPath, 0o600)
        var st = stat()
        _ = lstat(ownPath, &st)
        report.check("socket permissions are 0600", (st.st_mode & 0o777) == 0o600,
                     String(st.st_mode & 0o777, radix: 8))
        ownLC.release()
        report.check("own socket removed on release", !fm.fileExists(atPath: ownPath))
        close(fd)
    } else {
        report.check("own socket removed on release", false, "could not create node")
    }

    let foreignPath = root + "/foreign.sock"
    let foreignLC = SocketLifecycle(socketPath: foreignPath)
    if let fd = makeSocketNode(foreignPath, listen: true) {
        try? foreignLC.recordBoundSocket()
        // replace the node with a regular file after it was recorded
        _ = unlink(foreignPath)
        fm.createFile(atPath: foreignPath, contents: Data("foreign".utf8))
        foreignLC.release()
        report.check("release never deletes a foreign node",
                     fm.fileExists(atPath: foreignPath))
        close(fd)
    } else {
        report.check("release never deletes a foreign node", false, "could not create node")
    }

    // a group-writable existing directory is refused, not chmod'ed
    let looseDir = root + "/loose"
    try? fm.createDirectory(atPath: looseDir, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o777])
    let looseLC = SocketLifecycle(socketPath: looseDir + "/b.sock")
    var refusedDir = false
    do { try looseLC.prepareDirectory() } catch { refusedDir = true }
    var dst = stat()
    _ = lstat(looseDir, &dst)
    report.check("group/world-writable directory is refused, not chmod'ed",
                 refusedDir && (dst.st_mode & 0o777) == 0o777,
                 String(dst.st_mode & 0o777, radix: 8))
}
