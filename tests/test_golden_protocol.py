"""Phase 8.6 golden-message test against the real bridge binary.

Hardware-free: uses --mode simulation and --mode vehicle-readonly with
--simulate-transport, so no Bluetooth, no adapter, no vehicle. Every case speaks
the NDJSON protocol over a Unix socket and asserts the exact shapes that
protocol/ndjson_protocol.json documents.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "build" / "obdlink-rfcomm"
TOKEN = "VEHICLE_READONLY"
results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))


class Bridge:
    def __init__(self, *args: str):
        self.dir = Path(tempfile.mkdtemp(prefix="p86_"))
        self.sock = self.dir / "b.sock"
        self.proc = subprocess.Popen([str(BIN), "--unix-socket", str(self.sock), *args],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def __enter__(self):
        for _ in range(100):
            if self.sock.exists():
                return self
            if self.proc.poll() is not None:
                raise AssertionError("bridge exited early")
            time.sleep(0.05)
        raise AssertionError("socket did not appear")

    def __exit__(self, *exc):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)


class Client:
    def __init__(self, path: Path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        self.s.connect(str(path))
        self.f = self.s.makefile("rwb")

    def send_raw(self, line: bytes) -> None:
        self.f.write(line + b"\n")
        self.f.flush()

    def send(self, obj: dict) -> None:
        self.send_raw(json.dumps(obj).encode())

    def recv(self) -> dict:
        line = self.f.readline()
        if not line:
            raise EOFError("closed")
        return json.loads(line)

    def close(self):
        try:
            self.f.close(); self.s.close()
        except OSError:
            pass


def hello(client: Client, mode="adapter-only", proto=1, token=None) -> dict:
    msg = {"type": "hello", "protocol": proto, "mode": mode}
    if token is not None:
        msg["vehicle_token"] = token
    client.send(msg)
    return client.recv()


# ---------------------------------------------------------------- simulation
def test_simulation() -> None:
    with Bridge("--mode", "simulation") as b:
        c = Client(b.sock)
        ack = hello(c)
        check("hello_ack type", ack.get("type") == "hello_ack", str(ack.get("type")))
        check("hello_ack protocol=1", ack.get("protocol") == 1)
        check("hello_ack presents adapter-only", ack.get("mode") == "adapter-only")
        check("hello_ack simulated=true", ack.get("simulated") is True)
        check("hello_ack adapter starts with OBDLink",
              str(ack.get("adapter", "")).upper().startswith("OBDLINK"), ack.get("adapter"))
        check("hello_ack carries STN2255", "STN2255" in str(ack.get("stn", "")).upper())

        c.send({"type": "write", "data": "ATI"})
        check("write ATI -> ok", c.recv().get("type") == "ok")
        c.send({"type": "read", "timeout": 1.0})
        line = c.recv()
        check("read -> line ELM327", line.get("type") == "line" and line.get("data") == "ELM327 v1.4b",
              str(line.get("data")))

        c.send({"type": "write", "data": "22F187"})
        blocked = c.recv()
        check("22F187 blocked in adapter-only", blocked.get("type") == "blocked", blocked.get("reason", ""))
        check("blocked carries a reason", bool(blocked.get("reason")))

        c.send({"type": "read", "timeout": 0.2})
        check("empty read -> timeout with partial",
              c.recv().get("type") == "timeout")

        c.send({"type": "bogus"})
        err = c.recv()
        check("unknown type -> error unknown message",
              err.get("type") == "error" and err.get("reason") == "unknown message", str(err))

        c.send({"type": "close"})
        check("close -> ok", c.recv().get("type") == "ok")
        c.close()


def test_handshake_rejections() -> None:
    with Bridge("--mode", "simulation") as b:
        c = Client(b.sock)
        c.send_raw(b"{not json")
        err = c.recv()
        check("invalid json -> error invalid json",
              err.get("type") == "error" and err.get("reason") == "invalid json")
        c.close()

        c = Client(b.sock)
        c.send({"type": "write", "data": "ATI"})
        err = c.recv()
        check("non-hello first -> error hello expected",
              err.get("reason") == "hello expected", str(err))
        c.close()

        c = Client(b.sock)
        err = hello(c, proto=2)
        check("protocol 2 -> error protocol mismatch",
              err.get("reason") == "protocol mismatch", str(err))
        c.close()

        c = Client(b.sock)
        err = hello(c, mode="vehicle-readonly")
        check("mode mismatch -> error mode mismatch",
              err.get("reason") == "mode mismatch", str(err))
        c.close()


def test_post_handshake_malformed() -> None:
    """v0.2.0: a malformed line after hello answers with a structured error."""
    with Bridge("--mode", "simulation") as b:
        c = Client(b.sock)
        hello(c)
        c.send_raw(b"{broken")
        try:
            msg = c.recv()
            got = (msg.get("type"), msg.get("reason"))
        except EOFError:
            got = ("closed-silently", None)
        # exact semantics: the reason must be the documented one, ...
        check("post-handshake malformed JSON -> error invalid json",
              got == ("error", "invalid json"), str(got))
        # ... and the connection must be closed afterwards, not left open
        try:
            rest = c.f.readline()
            closed_after = (rest == b"")
        except Exception:                        # noqa: BLE001
            closed_after = True
        check("malformed JSON closes the connection after the error", closed_after)
        c.close()


# ---------------------------------------------------------- vehicle-readonly
def test_vehicle_mode() -> None:
    with Bridge("--mode", "vehicle-readonly", "--simulate-transport",
                "--vehicle-token", TOKEN) as b:
        c = Client(b.sock)
        ack = hello(c, mode="vehicle-readonly", token=TOKEN)
        check("vehicle hello_ack", ack.get("type") == "hello_ack" and ack.get("mode") == "vehicle-readonly")

        c.send({"type": "write", "data": "2180"})
        check("2180 allowed in vehicle mode", c.recv().get("type") == "ok")
        c.send({"type": "read", "timeout": 1.0})
        check("2180 answer line", c.recv().get("type") == "line")

        c.send({"type": "write", "data": "2106"})
        check("2106 allowed in vehicle mode", c.recv().get("type") == "ok")
        c.send({"type": "read", "timeout": 0.5})
        c.recv()

        c.send({"type": "write", "data": "217F"})
        blocked = c.recv()
        check("217F blocked in vehicle mode (gate narrower than Python)",
              blocked.get("type") == "blocked", blocked.get("reason", ""))

        c.send({"type": "write", "data": "10C0"})
        check("10C0 blocked (session change)", c.recv().get("type") == "blocked")
        c.send({"type": "write", "data": "2E6C1C78"})
        check("2E write blocked", c.recv().get("type") == "blocked")
        c.send({"type": "write", "data": "3B0780"})
        check("3B write blocked", c.recv().get("type") == "blocked")
        c.close()

        c = Client(b.sock)
        err = hello(c, mode="vehicle-readonly", token="WRONG")
        check("wrong token -> error token missing", err.get("reason") == "token missing", str(err))
        c.close()

        c = Client(b.sock)
        c.send({"type": "hello", "protocol": 1, "mode": "vehicle-readonly"})
        err = c.recv()
        check("missing token -> error token missing", err.get("reason") == "token missing")
        c.close()


def main() -> int:
    for fn in (test_simulation, test_handshake_rejections,
               test_post_handshake_malformed, test_vehicle_mode):
        fn()
    ok = sum(1 for _, p, _ in results if p)
    print(f"\n{ok} passed, {len(results) - ok} failed")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
