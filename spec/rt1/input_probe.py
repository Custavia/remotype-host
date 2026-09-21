"""Does a REAL host inject phone input over a live sealed session?

The bug this exists to catch: the screen keeps streaming (host -> phone) while
the trackpad and keyboard go dead (phone -> host). That is a phone->host input
path failure on a socket that is otherwise alive — a socket CLOSE would take the
screen with it, so "screen alive, input dead" is its own class of fault.

This is a current-protocol synthetic phone. It pairs, opens a sealed session,
then drives input the way the app does and proves the host acted on it:

  1. a burst of `mm` (relative mouse move) frames — checked against the host's
     own `inject mm` telemetry in its log (the console cursor can't be read over
     ssh: that runs in session 0, a different window station)
  2. the exact ORDER the app uses around the fault: tv.sub, an immediate resize
     tv.sub, then interleaved mm — this is the sequence the s log captured right
     before "RT1: sealed line failed to open — closing"
  3. a long steady 60/s mm stream with a concurrent tv subscription, to see if
     the counter ever desyncs under the TV downlink (the "input wedges while the
     screen streams" report)
  4. `key`, `mb` click, `sc` scroll — that they neither desync nor close the link

Health is read from the host log, not from a reply: the host does not ack input.
A PASS means every `inject mm` the host logged during a phase is > 0 and the link
never logged "sealed line failed to open" or "dropped a message".

Env (same shape as pairing_edges.py):
    RT1_CODE_CMD   prints the live pairing code
    RT1_CLEAR_CMD  deletes the code file
    RT1_LOG_CMD    prints the last ~40 host log lines

    python3 input_probe.py <host> <port>
"""
import base64
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import interop_host as ih  # noqa: E402
from interop_host import (  # noqa: E402
    Link, b64, crockford_bytes, device_tag, ec, ecdh, pairing_transcript,
    seal, serialization, session_keys, spki,
)

ADDR = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 50808

CODE_CMD = os.environ["RT1_CODE_CMD"]
CLEAR_CMD = os.environ["RT1_CLEAR_CMD"]
LOG_CMD = os.environ["RT1_LOG_CMD"]

DEV = "10ada7a710ada7a710ada7a710ada7a7"
NAME = "RT1 input probe"
observations = []


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, timeout=30)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def read_code():
    out = sh(CODE_CMD).strip()
    alnum = [c for c in out if c.isalnum()]
    return out if len(alnum) == 12 else None


def log_lines():
    return [l.rstrip() for l in sh(LOG_CMD).splitlines() if l.strip()]


def inject_count(lines):
    """Total mouse-moves the host logged as injected across its JITTER lines."""
    n = 0
    for l in lines:
        i = l.find("inject mm")
        if i < 0:
            continue
        seg = l[i:]
        j = seg.find("n=")
        if j >= 0:
            k = j + 2
            num = ""
            while k < len(seg) and seg[k].isdigit():
                num += seg[k]; k += 1
            if num:
                n += int(num)
    return n


def faults(lines):
    return [l for l in lines
            if "failed to open" in l or "dropped a message" in l]


class Session:
    """A paired, open sealed link to the host — the real phone's state machine."""

    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.spk = spki(self.key.public_key())
        self.link = None
        self.keys = None
        self.counter_out = 0
        self.counter_in = 0

    # -- pairing ---------------------------------------------------------

    def pair(self):
        sh(CLEAR_CMD)
        link = Link(ADDR, PORT)
        e = ec.generate_private_key(ec.SECP256R1())

        def begin():
            link.send_json({
                "t": "pair.begin", "rt": 1, "dev": DEV, "spk": b64(self.spk),
                "epk": b64(spki(e.public_key())), "name": NAME, "plat": "test",
            })
            return json.loads(link.read_line() or b"{}")

        begin()  # mints the code
        code = None
        deadline = time.time() + 5
        while time.time() < deadline and not code:
            code = read_code()
            if not code:
                time.sleep(0.2)
        if not code:
            link.close()
            ih.check("input probe could pair (no code appeared)", False); return False
        hi = begin()
        if hi.get("t") != "pair.hi":
            link.close()
            ih.check(f"pair.begin answered pair.hi (got {hi})", False); return False
        epk_h = base64.b64decode(hi["epk"])
        z = ecdh(e, serialization.load_der_public_key(epk_h))
        mac_p, _ = pairing_transcript(
            DEV, hi["hid"], self.spk, base64.b64decode(hi["spk"]),
            spki(e.public_key()), epk_h, NAME, hi.get("name", ""),
            z, crockford_bytes(code))
        link.send_json({"t": "pair.conf", "mac": b64(mac_p)})
        ok = json.loads(link.read_line() or b"{}").get("t") == "pair.ok"
        link.close()
        ih.check("the input probe paired", ok); return ok

    # -- session ---------------------------------------------------------

    def open(self):
        self.link = Link(ADDR, PORT)
        e = ec.generate_private_key(ec.SECP256R1())
        epk_p = spki(e.public_key())
        n_p = os.urandom(16)
        self.link.send_json({
            "t": "hello", "v": 2, "name": NAME, "rt": 1,
            "tag": b64(device_tag(n_p, self.spk)), "n": b64(n_p),
            "epk": b64(epk_p),
        })
        hi = json.loads(self.link.read_line() or b"{}")
        if hi.get("t") != "hi" or not hi.get("hid"):
            ih.check(f"the probe opened a session (hi={hi})", False); return False
        hid = hi["hid"]
        n_h = base64.b64decode(hi["n"])
        epk_h_der = base64.b64decode(hi["epk"])
        epk_h = serialization.load_der_public_key(epk_h_der)
        with open_support("identity.bin") as f:
            raw_id = f.read()
        host_priv = ec.derive_private_key(int.from_bytes(raw_id[:32], "big"),
                                          ec.SECP256R1())
        spk_h = spki(host_priv.public_key())
        zee = ecdh(e, epk_h)
        zes = ecdh(e, host_priv.public_key())
        zse = ecdh(self.key, epk_h)
        self.keys = session_keys(DEV, hid, self.spk, spk_h, epk_p, epk_h_der,
                                 n_p, n_h, zee, zes, zse)
        self.link.send_json({"t": "rt.conf", "mac": b64(self.keys["mac_p"])})
        ok = json.loads(self.link.read_line() or b"{}").get("t") == "rt.ok"
        # drain the frames the host volunteers on open (perms, etc.)
        self._drain(1.0)
        ih.check("the probe's session is open", ok); return ok

    def send(self, obj):
        from interop_host import P2H
        blob = seal(json.dumps(obj).encode(), self.keys["c2h"], P2H,
                    self.counter_out)
        self.counter_out += 1
        self.link.send_raw(base64.b64encode(blob))

    def _drain(self, seconds):
        from interop_host import H2P, open_sealed
        deadline = time.time() + seconds
        while time.time() < deadline:
            raw = self.link.read_line(timeout=max(0.05, deadline - time.time()))
            if raw is None:
                break
            try:
                open_sealed(base64.b64decode(raw), self.keys["h2c"], H2P,
                            self.counter_in)
                self.counter_in += 1
            except Exception:
                # a frame we couldn't open: the host is out of step with us, or
                # sent something we won't parse. Not fatal to the probe; the log
                # check catches a real desync.
                break

    def close(self):
        if self.link:
            self.link.close()


def open_support(name):
    from interop_host import SUPPORT
    return open(os.path.join(SUPPORT, name), "rb")


def burst_mm(sess, n, dx, dy, hz=60):
    gap = 1.0 / hz
    for _ in range(n):
        sess.send({"t": "mm", "dx": dx, "dy": dy})
        time.sleep(gap)


def phase(name, fn):
    print(f"-- {name}")
    before = log_lines()
    n0 = inject_count(before)
    fn()
    time.sleep(1.5)                       # let the host flush a JITTER line
    after = log_lines()
    new = [l for l in after if l not in before]
    f = faults(new)
    ih.check(f"[{name}] the link logged no fault (saw {f})", not f)
    # The inject assertion needs the host's JITTER "inject mm" telemetry, which
    # only the WINDOWS host emits. On a host that never logs it (macOS injects
    # via CGEvent with no telemetry line), the no-fault check above is the signal
    # and injection itself is covered by interop_host's sealed round-trip — so
    # report it as an observation instead of a false failure.
    if any("inject mm" in l for l in after):
        injected = inject_count(after) - n0
        ih.check(f"[{name}] the host injected mouse moves (delta={injected})",
                 injected > 0)
    else:
        observations.append(f"[{name}] no inject telemetry on this host — "
                            f"injection not observable via log (macOS); no fault seen")
        print(f"     note: {observations[-1]}")


def main():
    print(f"host {ADDR}:{PORT}")
    s = Session()
    if not s.pair():
        return ih.report()
    if not s.open():
        return ih.report()

    phase("A: a plain mm burst injects", lambda: burst_mm(s, 90, 6, 4))

    def tv_then_resize():
        # The exact order from the s log: subscribe, immediately resize, then
        # drive the pointer through the resize — where "failed to open" hit.
        s.send({"t": "tv.sub", "w": 1184, "h": 384, "z": 0.5, "f": "cursor"})
        time.sleep(0.05)
        s.send({"t": "tv.sub", "w": 1184, "h": 960, "z": 0.5, "f": "cursor"})
        burst_mm(s, 60, -5, -3)
    phase("B: mm across a tv.sub resize (the s-log sequence)", tv_then_resize)

    def steady_under_tv():
        # A long pointer stream with a TV subscription live and its downlink
        # coming back at us — the "input wedges while the screen streams" report.
        # We keep draining host frames so its send buffer never blocks, mirroring
        # a real phone that is rendering the video.
        end = time.time() + 4
        i = 0
        while time.time() < end:
            s.send({"t": "mm", "dx": 7 if i % 2 else -7, "dy": 3})
            i += 1
            if i % 10 == 0:
                s._drain(0.02)
            time.sleep(1.0 / 60)
    phase("C: 4s of 60/s mm with the TV downlink live", steady_under_tv)

    def discretes():
        s.send({"t": "tv.unsub"})
        s.send({"t": "key", "c": "a", "mods": 0})
        s.send({"t": "mb", "b": 0, "down": True, "mods": 0})
        s.send({"t": "mb", "b": 0, "down": False, "mods": 0})
        s.send({"t": "sc", "dx": 0, "dy": -3})
        burst_mm(s, 40, 4, 4)             # so the phase has an inject signal
    phase("D: key + click + scroll interleaved with mm", discretes)

    s.close()
    time.sleep(1.0)
    tail = log_lines()
    ih.check("the session was never dropped by a fault during the probe",
             not faults(tail[-12:]))
    if observations:
        print("\nOBSERVATIONS")
        for o in observations:
            print("  - " + o)
    return ih.report()


if __name__ == "__main__":
    sys.exit(main())
