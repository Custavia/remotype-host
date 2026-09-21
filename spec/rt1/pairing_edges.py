"""Pairing-ceremony edge cases against a REAL host, from the outside.

interop_host.py proves the happy path and the guard. This is the rest of the
ceremony — the situations a real phone actually gets into, which are exactly the
ones a demo never shows:

  A. the user taps Cancel on the phone (pair.cancel) — the code is retired, the
     window says so, the socket stays up, and a LATER drop of that socket does
     not retire a code that a second phone has minted since
  B. the phone vanishes mid-ceremony without a cancel — same outcome, gentler words
  C. a pair.cancel from a socket that never began pairing is ignored, and the
     phone that IS pairing completes; then the paired phone opens a session on
     the same socket
  D. three wrong codes burn the code; the next begin mints a fresh one
  E. input sent during the pairing phase is dropped (only a pong comes back)
  F. pair.cancel on a fresh socket is harmless
  G. pair.cancel after pair.ok is ignored — the pairing stands
  H. begin → cancel → begin again on the SAME socket pairs cleanly
  J. two phones begin on one code; the first pairs; what happens to the second
     is OBSERVED and reported, not asserted (the spec burns the code after the
     first success; a second begin-before-burn is a grey area)

Black box: it needs a live code and the host's log, and it gets both through
shell commands so the same script drives a local Mac host and a Windows box
over ssh.

    RT1_CODE_CMD   prints the code the host wrote to its REMOTYPE_RT1_TEST_CODE_FILE
    RT1_CLEAR_CMD  deletes that file (so "a new code was minted" is observable)
    RT1_LOG_CMD    prints the last ~40 host log lines
    RT1_SHOT_CMD   optional; "{out}" is replaced with a PNG path to save the
                   pairing window to — the visual half of each case
    RT1_SHOT_DIR   where those PNGs go (default /tmp)

Usage:
    python3 pairing_edges.py <host> <port> [A B C ...]
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
    serialization, spki,
)

ADDR = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 50808
ONLY = set(a.upper() for a in sys.argv[3:])

CODE_CMD = os.environ["RT1_CODE_CMD"]
CLEAR_CMD = os.environ["RT1_CLEAR_CMD"]
LOG_CMD = os.environ["RT1_LOG_CMD"]
SHOT_CMD = os.environ.get("RT1_SHOT_CMD")
SHOT_DIR = os.environ.get("RT1_SHOT_DIR", "/tmp")

# One dev id for every pairing this script completes, so the host ends up with
# ONE "RT1 edge-case phone" in its list rather than one per run.
DEV = "ed9ec45e0000000000000000000000ca"
NAME = "RT1 edge-case phone"

STATE = {"code": None}          # the code we believe is live on the host
# Two host concurrency models exist and the suite must not mistake one for a bug:
#   per-connection (Windows): each socket has its own pairing/session state, so a
#     bystander on a second socket cannot touch a ceremony on the first.
#   single-connection (macOS): each accept replaces the one shared session, so a
#     second phone connecting mid-pairing TAKES OVER — one phone per computer, by
#     design. Cases C and J probe bystander-isolation, which only means something
#     on a per-connection host; on a single-connection host they report the
#     take-over instead of failing.
observations = []


# ------------------------------------------------------------------ helpers

def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, timeout=30)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def read_code():
    out = sh(CODE_CMD).strip()
    alnum = [c for c in out if c.isalnum()]
    # A code, and not a "file not found" complaint: 12 Crockford characters.
    return out if len(alnum) == 12 and "\n" not in out else None


def clear_code():
    sh(CLEAR_CMD)


def poll_code(timeout=4.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        code = read_code()
        if code:
            return code
        time.sleep(0.2)
    return None


def log_lines():
    return [l.rstrip() for l in sh(LOG_CMD).splitlines() if l.strip()]


def logsnap():
    return set(log_lines())


def new_log(base):
    return [l for l in log_lines() if l not in base]


def wait_log(base, needle, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for l in new_log(base):
            if needle in l:
                return l
        time.sleep(0.4)
    return None


def shot(name):
    if not SHOT_CMD:
        return
    out = os.path.join(SHOT_DIR, f"edge-{name}.png")
    sh(SHOT_CMD.replace("{out}", out))
    if os.path.exists(out):
        print(f"     [shot] {out}")


def reply(link, timeout=3.0):
    raw = link.read_line(timeout=timeout)
    return json.loads(raw) if raw else {}


def drain(link, seconds=1.5):
    seen = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        raw = link.read_line(timeout=max(0.1, deadline - time.time()))
        if raw is None:
            break
        try:
            seen.append(json.loads(raw).get("t"))
        except ValueError:
            seen.append("<unparseable>")
    return seen


def pong(link, label):
    link.send_json({"t": "ping"})
    ih.check(label, "pong" in drain(link, 1.5))


def flip(code):
    return "".join(("0" if c != "0" else "1") if c.isalnum() else c for c in code)


class Phone:
    def __init__(self, dev=None, name=NAME):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.spk = spki(self.key.public_key())
        self.dev = dev or os.urandom(16).hex()
        self.name = name

    def begin(self, link):
        e = ec.generate_private_key(ec.SECP256R1())
        link.send_json({
            "t": "pair.begin", "rt": 1, "dev": self.dev, "spk": b64(self.spk),
            "epk": b64(spki(e.public_key())), "name": self.name, "plat": "test",
        })
        return reply(link), e

    def conf(self, link, hi, e, code):
        spk_h = base64.b64decode(hi["spk"])
        epk_h = base64.b64decode(hi["epk"])
        z = ecdh(e, serialization.load_der_public_key(epk_h))
        mac_p, mac_h = pairing_transcript(
            self.dev, hi["hid"], self.spk, spk_h, spki(e.public_key()), epk_h,
            self.name, hi.get("name", ""), z, crockford_bytes(code))
        link.send_json({"t": "pair.conf", "mac": b64(mac_p)})
        return reply(link), mac_h

    def hello(self, link):
        e = ec.generate_private_key(ec.SECP256R1())
        n = os.urandom(16)
        link.send_json({
            "t": "hello", "v": 2, "name": self.name, "rt": 1,
            "tag": b64(device_tag(n, self.spk)), "n": b64(n),
            "epk": b64(spki(e.public_key())),
        })
        return reply(link)


def ensure_code(link, phone):
    """Gets [link] into the pairing phase with a code we know. Returns (code, hi, e)."""
    clear_code()
    r, e = phone.begin(link)
    if r.get("t") == "pair.hi":
        # The host minted a FRESH code for this begin (mint-on-begin) and wrote it
        # to the test-hook file. clear_code() emptied the file first, so poll for
        # the new value — never reuse STATE["code"], which is a prior case's code
        # and no longer matches what the host will verify against.
        code = poll_code()
        if not code:
            ih.check("a code is live but this run cannot read it (is the test "
                     "code hook set on the host?)", False)
            return None, r, e
        STATE["code"] = code
        return code, r, e
    # No code was live. The host mints one, raises its panel and answers THIS
    # begin with pair.hi — one tap on the phone (both hosts since 2026-09-09).
    ih.check("an unprompted pair.begin mints a code and is answered pair.hi",
             r.get("t") == "pair.hi")
    code = poll_code()
    ih.check("the host minted a code", bool(code))
    if not code:
        return None, r, e
    STATE["code"] = code
    return code, r, e


def new_code_after(link, phone, label):
    """Proves the live code is gone: a begin mints a NEW code (and is answered
    pair.hi, so this socket is now in a fresh ceremony)."""
    clear_code()
    r, _ = phone.begin(link)
    ih.check(label, r.get("t") == "pair.hi")
    code = poll_code()
    ih.check("…and a fresh code was minted", bool(code) and code != STATE["code"])
    STATE["code"] = code
    return code


def settle(seconds=1.0):
    time.sleep(seconds)


# -------------------------------------------------------------------- cases

def case_A():
    print("A. Cancel on the phone, then a bystander's drop")
    p1, p2 = Phone(), Phone()
    l1 = Link(ADDR, PORT)
    code, hi, e = ensure_code(l1, p1)
    if not code:
        l1.close(); return
    base = logsnap()
    l1.send_json({"t": "pair.cancel"})
    settle()
    ih.check("the host logged the cancel",
             wait_log(base, "cancelled on the phone") is not None)
    shot("A-cancelled")
    pong(l1, "the cancelled socket stays open and still answers ping")
    ih.check("input on the cancelled socket is still dropped",
             (l1.send_json({"t": "key", "c": "x"}) or drain(l1, 1.0)) == [])
    # A second phone comes along and mints a new code.
    l2 = Link(ADDR, PORT)
    code2 = new_code_after(l2, p2, "after the cancel a new begin mints a fresh code (old one retired)")
    if not code2:
        l1.close(); l2.close(); return
    hi2, e2 = p2.begin(l2)
    ih.check("phone 2 is in the ceremony", hi2.get("t") == "pair.hi")
    # NOW the cancelled socket drops. Its cancel must have reset it, or this
    # drop reads as "phone vanished mid-pairing" and retires phone 2's code.
    base = logsnap()
    l1.close()
    settle(1.5)
    ih.check("the cancelled socket's drop does not retire phone 2's code",
             wait_log(base, "disconnected mid-pairing", 2.0) is None)
    r, mac_h = p2.conf(l2, hi2, e2, code2)
    ih.check("phone 2 pairs with the new code", r.get("t") == "pair.ok")
    if r.get("t") == "pair.ok":
        ih.check("pair.ok carries the host MAC",
                 base64.b64decode(r.get("mac", "")) == mac_h)
    l2.close()
    settle()


def case_B():
    print("B. The phone vanishes mid-ceremony")
    p = Phone()
    l = Link(ADDR, PORT)
    code, hi, e = ensure_code(l, p)
    if not code:
        l.close(); return
    base = logsnap()
    l.close()
    settle(1.5)
    ih.check("the host logged the mid-pairing drop",
             wait_log(base, "disconnected mid-pairing") is not None)
    shot("B-dropped")
    l = Link(ADDR, PORT)
    new_code_after(l, p, "the code is gone after the drop (a begin mints a fresh one)")
    # That begin put this socket into a fresh ceremony, so dropping it is a
    # second mid-pairing drop: logged, and the fresh code retired with it.
    base = logsnap()
    l.close()
    settle(1.5)
    ih.check("dropping the re-entered socket is logged as mid-pairing too",
             wait_log(base, "disconnected mid-pairing") is not None)
    l = Link(ADDR, PORT)
    new_code_after(l, p, "…and the next begin mints yet another code")
    l.send_json({"t": "pair.cancel"})
    settle()
    l.close()


def case_C():
    print("C. A bystander's cancel is ignored; the real phone pairs and opens a session")
    pa = Phone(dev=DEV)
    la = Link(ADDR, PORT)
    code, hi, e = ensure_code(la, pa)
    if not code:
        la.close(); return
    lb = Link(ADDR, PORT)
    base = logsnap()
    lb.send_json({"t": "pair.cancel"})
    settle()
    ih.check("a cancel from a socket that never began pairing logs nothing",
             wait_log(base, "cancelled on the phone", 1.5) is None)
    pong(lb, "…and that socket still answers ping")
    r, mac_h = pa.conf(la, hi, e, code)
    if r.get("t") == "pair.ok":
        ih.check("per-connection host: phone A pairs, its code survived the bystander", True)
        ih.check("pair.ok MAC matches", base64.b64decode(r.get("mac", "")) == mac_h)
        hi2 = pa.hello(la)
        ih.check("the just-paired phone is recognised on the same socket",
                 hi2.get("t") == "hi" and bool(hi2.get("hid")))
    else:
        # The bystander's mere connection reset the one shared session: this is a
        # single-connection host taking over, not the cancel leaking across sockets.
        observations.append(
            f"C: single-connection host — the bystander connection took over "
            f"phone A's ceremony (A's conf got {r}); bystander-isolation N/A")
        print(f"     OBSERVED: {observations[-1]}")
    settle()
    shot("C-paired")
    la.close(); lb.close()
    settle()


def case_D():
    print("D. Three wrong codes burn the code")
    p = Phone()
    l = Link(ADDR, PORT)
    code, hi, e = ensure_code(l, p)
    if not code:
        l.close(); return
    wrong = flip(code)
    base = logsnap()
    for i in range(1, 4):
        if i > 1:
            hi, e = p.begin(l)
            if hi.get("t") != "pair.hi":
                ih.check(f"begin #{i} restarts the ceremony (got {hi})", False)
                break
        r, _ = p.conf(l, hi, e, wrong)
        ih.check(f"wrong code #{i} is refused with why=mac",
                 r.get("t") == "pair.no" and r.get("why") == "mac")
    settle()
    ih.check("the host logged the burn",
             wait_log(base, "too many failed attempts") is not None)
    shot("D-burned")
    new_code_after(l, p, "after three wrong tries a begin mints a fresh code")
    l.close()
    settle()


def case_E():
    print("E. Input during the pairing phase is dropped")
    p = Phone()
    l = Link(ADDR, PORT)
    code, hi, e = ensure_code(l, p)
    if not code:
        l.close(); return
    for m in ({"t": "key", "c": "x"}, {"t": "clip.get"}, {"t": "tv.start"},
              {"t": "mouse", "dx": 5, "dy": 5}, {"t": "ping"}):
        l.send_json(m)
    seen = drain(l, 2.0)
    ih.check(f"only a pong comes back while pairing (saw {seen})", seen == ["pong"])
    l.send_json({"t": "pair.cancel"})     # tidy: retire the code
    settle()
    l.close()
    settle()


def case_F():
    print("F. pair.cancel on a fresh socket is harmless")
    l = Link(ADDR, PORT)
    base = logsnap()
    l.send_json({"t": "pair.cancel"})
    settle()
    ih.check("nothing is logged", wait_log(base, "cancelled", 1.0) is None)
    pong(l, "the socket still answers ping")
    l.close()


def case_G():
    print("G. pair.cancel after pair.ok is ignored — the pairing stands")
    p = Phone(dev=DEV)
    l = Link(ADDR, PORT)
    code, hi, e = ensure_code(l, p)
    if not code:
        l.close(); return
    r, _ = p.conf(l, hi, e, code)
    ih.check("the phone pairs", r.get("t") == "pair.ok")
    base = logsnap()
    l.send_json({"t": "pair.cancel"})
    settle()
    ih.check("a cancel after pair.ok logs nothing",
             wait_log(base, "cancelled on the phone", 1.5) is None)
    hi2 = p.hello(l)
    ih.check("the pairing stands — hello is answered hi",
             hi2.get("t") == "hi" and bool(hi2.get("hid")))
    shot("G-paired-stands")
    l.close()
    settle()


def case_H():
    print("H. begin → cancel → begin again on the same socket")
    p = Phone(dev=DEV)
    l = Link(ADDR, PORT)
    code, hi, e = ensure_code(l, p)
    if not code:
        l.close(); return
    l.send_json({"t": "pair.cancel"})
    settle()
    code2 = new_code_after(l, p, "after the cancel the same socket's begin mints a fresh code")
    if not code2:
        l.close(); return
    hi, e = p.begin(l)
    ih.check("the same socket re-enters the ceremony", hi.get("t") == "pair.hi")
    r, _ = p.conf(l, hi, e, code2)
    ih.check("…and pairs with the new code", r.get("t") == "pair.ok")
    l.close()
    settle()


def case_J():
    print("J. Two phones on one code (observed, not asserted)")
    pa, pb = Phone(), Phone()
    la = Link(ADDR, PORT)
    code, hia, ea = ensure_code(la, pa)
    if not code:
        la.close(); return
    lb = Link(ADDR, PORT)
    hib, eb = pb.begin(lb)
    ih.check("phone B can begin on the same code", hib.get("t") == "pair.hi")
    ra, _ = pa.conf(la, hia, ea, code)
    rb, _ = pb.conf(lb, hib, eb, code)
    if ra.get("t") == "pair.ok":
        # Per-connection host: A owns its socket; B (begun before the burn) is the
        # grey area the case documents.
        ih.check("per-connection host: phone A pairs", True)
        observations.append(
            f"J: per-connection — A paired; B's conf (begun before the burn) got {rb}")
    else:
        # Single-connection host: opening B's socket reset the shared session, so B
        # is now the live one and A's conf fails. The LAST connection wins.
        observations.append(
            f"J: single-connection — opening B took over; A's conf got {ra}, "
            f"B's got {rb} (last connection wins)")
    print(f"     OBSERVED: {observations[-1]}")
    la.close(); lb.close()
    settle()


CASES = {"A": case_A, "B": case_B, "C": case_C, "D": case_D, "E": case_E,
         "F": case_F, "G": case_G, "H": case_H, "J": case_J}


def main():
    os.makedirs(SHOT_DIR, exist_ok=True)
    print(f"host {ADDR}:{PORT}")
    for k, fn in CASES.items():
        if ONLY and k not in ONLY:
            continue
        try:
            fn()
        except Exception as e:  # a crash in one case must not hide the others
            ih.check(f"case {k} raised {type(e).__name__}: {e}", False)
    if observations:
        print("\nOBSERVATIONS")
        for o in observations:
            print("  - " + o)
    return ih.report()


if __name__ == "__main__":
    sys.exit(main())
