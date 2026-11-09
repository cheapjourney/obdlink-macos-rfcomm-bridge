// Socket lifecycle for the secured mode: ownership, locking, stale detection.
//
// The v0.2.0 baseline called unlink(path) before binding, unconditionally. That
// deletes a live instance's socket, a regular file or a symlink at that path, and
// it cannot tell a stale node from a running bridge. This file replaces it with:
//
//   * an advisory flock on "<socket>.lock" so two starters cannot race,
//   * an lstat check that refuses anything that is not a socket,
//   * a connect probe that distinguishes "live" from "stale" (fail closed on
//     anything it cannot decide),
//   * an inode identity check before unlink, and again at cleanup,
//   * a directory check that never chmods a directory it did not create.
//
// No vehicle, no adapter, no network: only file system and AF_UNIX operations.

import Foundation
import Darwin

enum SocketLifecycleError: Error, CustomStringConvertible {
    case busy(String)
    case refused(String)
    case io(String)

    var description: String {
        switch self {
        case .busy(let m): return m
        case .refused(let m): return m
        case .io(let m): return m
        }
    }

    /// Exit codes: 7 = another instance, 8 = path refused, 6 = local I/O.
    var exitCode: Int32 {
        switch self {
        case .busy: return 7
        case .refused: return 8
        case .io: return 6
        }
    }
}

final class SocketLifecycle {
    let socketPath: String
    private var lockFD: Int32 = -1
    private var boundDev: dev_t = 0
    private var boundIno: ino_t = 0
    private(set) var ownsSocket = false

    var lockPath: String { socketPath + ".lock" }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: directory

    /// Creates the directory with 0700 when missing; otherwise verifies it and
    /// leaves it untouched. Never chmods a directory owned by someone else.
    func prepareDirectory() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT else {
                throw SocketLifecycleError.io("cannot stat \(dir): errno \(errno)")
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                return
            } catch {
                throw SocketLifecycleError.io("cannot create \(dir): \(error)")
            }
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw SocketLifecycleError.refused("\(dir) exists and is not a directory")
        }
        guard st.st_uid == geteuid() else {
            throw SocketLifecycleError.refused("\(dir) is not owned by this user")
        }
        // Group- or world-writable means any local user could place or replace
        // the socket; refuse instead of silently chmod'ing a foreign directory.
        guard (st.st_mode & 0o022) == 0 else {
            throw SocketLifecycleError.refused("\(dir) is group/world writable; fix it by hand")
        }
    }

    // MARK: lock

    /// Serialises startup between instances. flock is released by the kernel when
    /// the process dies, so a SIGKILL cannot leave a permanent lock behind.
    ///
    /// O_NOFOLLOW and the fstat checks matter: without them a symlink planted at
    /// the lock path would make two instances flock *different* files and both
    /// would believe they are the only one.
    func acquireLock() throws {
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw SocketLifecycleError.refused(
                    "\(lockPath) is a symlink; refusing to lock through it")
            }
            throw SocketLifecycleError.io("cannot open lock \(lockPath): errno \(errno)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              st.st_uid == geteuid() else {
            close(fd)
            throw SocketLifecycleError.refused(
                "\(lockPath) is not a regular file owned by this user")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw SocketLifecycleError.busy("another instance holds \(lockPath)")
        }
        lockFD = fd
    }

    // MARK: stale detection

    /// True when something is still accepting connections on that path.
    /// Unclear answers count as "live" so that nothing is deleted on a guess.
    static func socketIsLive(_ path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return true }
        if errno == ECONNREFUSED { return false }        // nobody listening
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let prc = poll(&pfd, 1, 200)
            if prc <= 0 { return true }                  // no answer: fail closed
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            return err == 0
        }
        return true                                      // unknown: fail closed
    }

    /// Removes a socket left behind by a dead instance. Refuses everything else.
    func clearStaleSocket() throws {
        var st = stat()
        if lstat(socketPath, &st) != 0 {
            if errno == ENOENT { return }
            throw SocketLifecycleError.io("cannot stat \(socketPath): errno \(errno)")
        }
        let kind = st.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFSOCK) else {
            // regular file, directory, symlink, fifo: never remove, never follow
            throw SocketLifecycleError.refused(
                "\(socketPath) exists and is not a socket (mode \(String(kind, radix: 8)))")
        }
        guard st.st_uid == geteuid() else {
            throw SocketLifecycleError.refused("\(socketPath) is not owned by this user")
        }
        guard !SocketLifecycle.socketIsLive(socketPath) else {
            throw SocketLifecycleError.busy("\(socketPath) is served by a running instance")
        }
        // Re-check identity immediately before unlinking: between the probe and
        // the unlink another process could have replaced the node. If the inode
        // changed we cannot prove it is the stale one, so we refuse.
        var again = stat()
        guard lstat(socketPath, &again) == 0,
              again.st_ino == st.st_ino, again.st_dev == st.st_dev,
              (again.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw SocketLifecycleError.refused("socket changed during stale check")
        }
        guard unlink(socketPath) == 0 else {
            throw SocketLifecycleError.io("cannot remove stale socket: errno \(errno)")
        }
    }

    // MARK: ownership record

    /// Records the node we just bound, so cleanup can prove it is still ours.
    func recordBoundSocket() throws {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else {
            throw SocketLifecycleError.io("cannot stat bound socket: errno \(errno)")
        }
        boundDev = st.st_dev
        boundIno = st.st_ino
        ownsSocket = true
    }

    /// Unlinks only the node this process created. Anything else is left alone.
    func release() {
        if ownsSocket {
            var st = stat()
            if lstat(socketPath, &st) == 0,
               st.st_ino == boundIno, st.st_dev == boundDev,
               (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
                _ = unlink(socketPath)
            }
            ownsSocket = false
        }
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }
}
