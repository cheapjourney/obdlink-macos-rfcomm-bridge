#!/usr/bin/env python3
"""Phase 10.0 regression: secured-mode lifecycle against the real binary.

Hardware-free. Uses --mode simulation (no Bluetooth) and local sockets only.
"""
import json, os, signal, socket, subprocess, sys, tempfile, time
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "build" / "obdlink-rfcomm"
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))


def start(sock, *args, wait=True):
    p = subprocess.Popen([str(BIN), "--unix-socket", str(sock), *args],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if wait:
        for _ in range(100):
            if sock.exists():
                return p
            if p.poll() is not None:
                return p
            time.sleep(0.05)
    return p


def connect(sock):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(str(sock))
    return s, s.makefile("rwb")


def hello(f, mode="adapter-only", token=None, proto=1):
    msg = {"type": "hello", "protocol": proto, "mode": mode}
    if token:
        msg["vehicle_token"] = token
    f.write((json.dumps(msg) + "\n").encode()); f.flush()
    return json.loads(f.readline())


def main():
    root = Path(tempfile.mkdtemp(prefix="p10_"))
    sock = root / "b.sock"

    # 1. first instance starts
    p1 = start(sock, "--mode", "simulation")
    check("first instance starts", sock.exists() and p1.poll() is None)

    # 2. second instance refused (exit 7), first stays reachable
    p2 = start(sock, "--mode", "simulation", wait=False)
    try:
        rc2 = p2.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p2.kill(); rc2 = "timeout"
    check("second instance refused with exit 7", rc2 == 7, str(rc2))
    try:
        s, f = connect(sock)
        ack = hello(f)
        check("first instance still reachable", ack.get("type") == "hello_ack")
        f.close(); s.close()
    except Exception as e:                       # noqa: BLE001
        check("first instance still reachable", False, repr(e))

    # 3. SIGTERM cleanup
    p1.send_signal(signal.SIGTERM)
    rc1 = p1.wait(timeout=10)
    check("SIGTERM exit 0 and socket removed", rc1 == 0 and not sock.exists(), str(rc1))

    # 4. regular file at the socket path is refused and kept
    plain = root / "plain.sock"
    plain.write_text("keep")
    p = start(plain, "--mode", "simulation", wait=False)
    rc = p.wait(timeout=10)
    check("regular file refused with exit 8 and kept",
          rc == 8 and plain.read_text() == "keep", str(rc))

    # 5. symlink is refused and kept, target untouched
    target = root / "t.txt"; target.write_text("target")
    link = root / "link.sock"; link.symlink_to(target)
    p = start(link, "--mode", "simulation", wait=False)
    rc = p.wait(timeout=10)
    check("symlink refused with exit 8 and kept",
          rc == 8 and link.is_symlink() and target.read_text() == "target", str(rc))

    # 6. stale socket is replaced
    stale = root / "stale.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(str(stale)); srv.close()
    p = start(stale, "--mode", "simulation")
    check("stale socket is taken over", stale.exists() and p.poll() is None)
    if p.poll() is None:
        p.terminate(); p.wait(timeout=10)

    # 7. permissions
    sock2 = root / "perm.sock"
    p = start(sock2, "--mode", "simulation")
    mode_sock = sock2.stat().st_mode & 0o777
    mode_dir = sock2.parent.stat().st_mode & 0o777
    check("socket 0600", mode_sock == 0o600, oct(mode_sock))
    check("directory 0700", mode_dir == 0o700, oct(mode_dir))

    # 8. NDJSON: malformed line after hello gets a structured error
    s, f = connect(sock2)
    hello(f)
    f.write(b"{broken\n"); f.flush()
    try:
        reply = json.loads(f.readline())
        got = (reply.get("type"), reply.get("reason"))
    except Exception:                            # noqa: BLE001
        got = ("closed", None)
    check("malformed JSON after hello -> error invalid json",
          got == ("error", "invalid json"), str(got))
    f.close(); s.close()

    # 9. overlong message is rejected deterministically
    s, f = connect(sock2)
    hello(f)
    f.write(b'{"type":"write","data":"' + b"A" * 9000 + b'"}\n'); f.flush()
    try:
        reply = json.loads(f.readline())
        got = (reply.get("type"), reply.get("reason"))
    except Exception:                            # noqa: BLE001
        got = ("closed", None)
    check("overlong message -> error message too long",
          got == ("error", "message too long"), str(got))
    f.close(); s.close()

    # 9b. overlong MULTIBYTE message: byte length, not character count
    s, f = connect(sock2)
    hello(f)
    f.write(b'{"type":"write","data":"' + "\u00dc".encode() * 6000 + b'"}\n'); f.flush()
    try:
        reply = json.loads(f.readline())
        got = (reply.get("type"), reply.get("reason"))
    except Exception:                            # noqa: BLE001
        got = ("closed", None)
    check("overlong multibyte message -> message too long",
          got == ("error", "message too long"), str(got))
    f.close(); s.close()

    # 10. sequential processing: two requests, two ordered answers
    s, f = connect(sock2)
    hello(f)
    f.write((json.dumps({"type": "write", "data": "ATI"}) + "\n").encode()); f.flush()
    a1 = json.loads(f.readline())["type"]
    f.write((json.dumps({"type": "read", "timeout": 1.0}) + "\n").encode()); f.flush()
    a2 = json.loads(f.readline())
    check("sequential request handling", a1 == "ok" and a2["type"] == "line",
          f"{a1}/{a2.get('type')}")
    f.close(); s.close()

    if p.poll() is None:
        p.terminate(); p.wait(timeout=10)
    check("clean stop removes socket", not sock2.exists())

    # 11. legacy TCP requires --tcp
    p = subprocess.run([str(BIN), "--address", "AA-BB-CC-DD-EE-FF"],
                       capture_output=True, text=True)
    check("legacy TCP without --tcp exits 2",
          p.returncode == 2 and "--tcp" in (p.stderr or ""), str(p.returncode))

    print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
