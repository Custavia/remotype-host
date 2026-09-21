"""Vet-before-swap: an unpaired connection must NOT evict the paired phone.

The macOS host used to cancel the current phone on EVERY incoming TCP connection,
before any authentication — so anyone on the LAN could disconnect the paired
phone just by opening a socket (the guard stopped them controlling anything, not
from kicking). This proves the fix, from the outside:

  1. an already-paired phone opens a session (the incumbent) and is live
  2. an UNPAIRED socket connects and hellos — the host must keep it on probation:
     the incumbent stays open and answering, and the newcomer gets nothing
  3. the unpaired socket sends input — still no effect, incumbent still live
  4. a PAIRED phone (the same identity on a new socket) connects and completes
     its session handshake — NOW the hand-off happens: the incumbent is dropped
     and the newcomer is the live session (paired take-over still works)

Reuses input_probe.Session for pairing/open/sealed-send, pinning one device id so
the incumbent and the take-over socket are the SAME paired identity on two
sockets. Env is the same as input_probe.py (RT1_CODE_CMD/RT1_CLEAR_CMD/
RT1_LOG_CMD); run it against a host you control (local Mac).

    python3 probation_probe.py <host> <port>
"""
import base64
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import interop_host as ih  # noqa: E402
import input_probe as ip  # noqa: E402
from interop_host import (  # noqa: E402
    H2P, P2H, Link, b64, device_tag, ec, open_sealed, seal, spki,
)

ADDR = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 50808

# One paired identity for the incumbent AND the take-over socket, so promotion is
# tested as "the same phone reconnected on a new socket" — the common real case.
ip.DEV = "9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a"


def alive(sess, label):
    """Send a sealed ping on [sess] and report whether a sealed pong comes back."""
    try:
        sess.send({"t": "ping"})
    except Exception as e:
        return ih.check(f"{label}: still live (send failed: {e})", False)
    deadline = time.time() + 2.5
    while time.time() < deadline:
        raw = sess.link.read_line(timeout=max(0.1, deadline - time.time()))
        if raw is None:
            break
        try:
            plain = open_sealed(base64.b64decode(raw), sess.keys["h2c"], H2P, sess.counter_in)
            sess.counter_in += 1
        except Exception:
            continue
        if json.loads(plain).get("t") == "pong":
            return ih.check(f"{label}: still live (sealed ping → pong)", True)
    return ih.check(f"{label}: still live (sealed ping → pong)", False)


def dead(sess, label):
    """The incumbent should be GONE after a paired take-over: a sealed ping gets
    no pong (the socket was cancelled by the host)."""
    try:
        sess.send({"t": "ping"})
    except Exception:
        return ih.check(f"{label}: evicted by the take-over (socket closed)", True)
    deadline = time.time() + 2.0
    while time.time() < deadline:
        raw = sess.link.read_line(timeout=max(0.1, deadline - time.time()))
        if raw is None:
            return ih.check(f"{label}: evicted by the take-over (socket closed)", True)
        try:
            plain = open_sealed(base64.b64decode(raw), sess.keys["h2c"], H2P, sess.counter_in)
            sess.counter_in += 1
        except Exception:
            continue
        if json.loads(plain).get("t") == "pong":
            return ih.check(f"{label}: evicted by the take-over (still answering!)", False)
    return ih.check(f"{label}: evicted by the take-over (socket closed)", True)


def unpaired_hello():
    """Open a raw socket and send a hello for a device the host has NEVER seen —
    the eviction attempt. Returns the reply (expected rt.no / no hi)."""
    link = Link(ADDR, PORT)
    key = ec.generate_private_key(ec.SECP256R1())
    spk = spki(key.public_key())
    n = os.urandom(16)
    e = ec.generate_private_key(ec.SECP256R1())
    link.send_json({
        "t": "hello", "v": 2, "name": "unpaired intruder", "rt": 1,
        "tag": b64(device_tag(n, spk)), "n": b64(n), "epk": b64(spki(e.public_key())),
    })
    reply = json.loads(link.read_line() or b"{}")
    return link, reply


def main():
    print(f"host {ADDR}:{PORT}")

    # 1) The incumbent: a real paired phone, open and live.
    incumbent = ip.Session()
    if not incumbent.pair():
        return ih.report()
    if not incumbent.open():
        return ih.report()
    alive(incumbent, "incumbent, freshly opened")

    # 2) An unpaired socket tries to take the slot just by connecting + helloing.
    intruder_link, reply = unpaired_hello()
    ih.check("the unpaired hello is refused (rt.no), not answered hi",
             reply.get("t") == "rt.no" or reply.get("t") != "hi")
    time.sleep(0.5)
    alive(incumbent, "incumbent, after an unpaired connection")

    # 3) The unpaired socket sends input anyway. The guard drops it AND it is not
    #    the active connection, so the incumbent is wholly unaffected.
    for m in ({"t": "mm", "dx": 50, "dy": 50}, {"t": "key", "c": "x"}, {"t": "tv.sub", "w": 800, "h": 600}):
        intruder_link.send_json(m)
    time.sleep(0.5)
    alive(incumbent, "incumbent, after the unpaired socket sent input")
    intruder_link.close()
    time.sleep(0.3)
    alive(incumbent, "incumbent, after the unpaired socket closed")

    # 4) The SAME paired identity reconnects on a NEW socket and completes the
    #    session handshake — the authenticated take-over. It must succeed, and
    #    the old incumbent must now be gone.
    takeover = ip.Session()
    takeover.key = incumbent.key            # same paired identity
    takeover.spk = incumbent.spk
    if not takeover.open():                  # hello → rt.conf on a fresh socket
        return ih.report()
    alive(takeover, "the take-over socket")
    time.sleep(0.5)
    dead(incumbent, "the previous incumbent")

    incumbent.close(); takeover.close()
    time.sleep(0.5)
    log = "\n".join(ip.log_lines()[-15:])
    ih.check("the host logged the vet + hand-off, not an anonymous eviction",
             "vetting it before any hand-off" in log or "took over from the previous phone" in log)
    return ih.report()


if __name__ == "__main__":
    sys.exit(main())
