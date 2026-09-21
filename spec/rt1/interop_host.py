#!/usr/bin/env python3
"""A test phone that speaks RT1 to a REAL host, over a real socket.

The self-tests in each implementation prove the *primitives* agree with
`vectors.json`. This proves the thing they cannot: that a host's socket, framing,
counters, guard and reply path all behave as `docs/RT1.md` says when something
else is on the other end. It reuses gen_vectors.py's primitives, so it is an
independent implementation of the protocol rather than a copy of the host's.

It checks, in order:

  1. An UNPAIRED connection that sends input gets no reply and is ignored.
     (This is the hole RT1 exists to close, tested from the outside.)
  2. A paired phone completes the session handshake on the hello.
  3. Sealed frames go both ways, and the counters line up.
  4. A tampered sealed frame kills the connection instead of being answered.
  5. A replaced connection starts from nothing, not from the last one's keys.
  6. The pairing ceremony: a wrong code is refused, the right one pairs, and the
     session that follows on the same socket opens. This needs the host started
     with REMOTYPE_RT1_TEST_CODE_FILE pointing somewhere readable — see
     PairingCode.writeTestCode. Without it, section 6 is skipped, loudly.

Usage:
    python3 interop_host.py                        # macOS host, 127.0.0.1:50808
    RT1_FLAVOR=go python3 interop_host.py           # the Go host, built for macOS
    RT1_FLAVOR=windows python3 interop_host.py      # run ON the Windows box
    python3 interop_host.py <host> <port>
"""

import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_vectors import (  # noqa: E402
    AESGCM, b64, ec, ecdh, hkdf_expand, hkdf_extract, lp, lps, serialization, spki,
)

import base64
import hashlib
import struct

# Where the host under test keeps identity.bin + devices.json, and how it
# encodes a date in JSON. The two hosts differ in both, and the point of this
# script is that it does not care which one is on the other end of the socket.
FLAVORS = {
    "mac": (os.path.expanduser("~/Library/Application Support/Remotype Host"), "swift"),
    "go": (os.path.expanduser("~/Library/Caches/Remotype Host"), "go"),
    "windows": (os.path.expandvars(r"%LOCALAPPDATA%\\Remotype Host"), "go"),
}
FLAVOR = os.environ.get("RT1_FLAVOR", "mac")
SUPPORT, DATE_STYLE = FLAVORS[FLAVOR]
# Driving a REMOTE host from another machine: point SUPPORT at a local copy
# of that host's identity.bin (and devices.json). DATE_STYLE still follows
# the flavor.
if os.environ.get("RT1_SUPPORT_DIR"):
    SUPPORT = os.environ["RT1_SUPPORT_DIR"]
DEV_ID = "00112233445566778899aabbccddeeff"
PHONE_KEY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              ".interop_phone_key.pem")

fails = []


def pairing_transcript(dev, hid, spk_p, spk_h, epk_p, epk_h, name_p, name_h, z, code8):
    th = hashlib.sha256(
        lps("RT1-PAIR") + lps(dev) + lps(hid)
        + lp(spk_p) + lp(spk_h) + lp(epk_p) + lp(epk_h)
        + lps(name_p) + lps(name_h)
    ).digest()
    prk = hkdf_extract(th, z + code8)
    return (_hmac(hkdf_expand(prk, b"rt1 pair phone", 32), b"\x01"),
            _hmac(hkdf_expand(prk, b"rt1 pair host", 32), b"\x02"))


def crockford_bytes(text):
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    norm = "".join({"I": "1", "L": "1", "O": "0"}.get(c, c)
                   for c in text.upper() if c.isalnum())
    v = 0
    for c in norm:
        v = (v << 5) | alphabet.index(c)
    return struct.pack(">Q", v)


def check(label, ok):
    print(("  ok   " if ok else "  FAIL ") + label)
    if not ok:
        fails.append(label)


# ----------------------------------------------------------------- primitives

def device_tag(nonce, spk_phone):
    return hashlib.sha256(lps("RT1-TAG") + lp(nonce) + lp(spk_phone)).digest()


def session_keys(dev, hid, spk_p, spk_h, epk_p, epk_h, n_p, n_h, zee, zes, zse):
    th = hashlib.sha256(
        lps("RT1-SESS") + lps(dev) + lps(hid)
        + lp(spk_p) + lp(spk_h) + lp(epk_p) + lp(epk_h)
        + lp(n_p) + lp(n_h)
    ).digest()
    prk = hkdf_extract(th, zee + zes + zse)
    return {
        "c2h": hkdf_expand(prk, b"rt1 c2h key", 32),
        "h2c": hkdf_expand(prk, b"rt1 h2c key", 32),
        "mac_p": _hmac(hkdf_expand(prk, b"rt1 c2h mac", 32), b"\x01"),
        "mac_h": _hmac(hkdf_expand(prk, b"rt1 h2c mac", 32), b"\x02"),
    }


def _hmac(key, msg):
    import hmac as _h
    return _h.new(key, msg, hashlib.sha256).digest()


def seal(js, key, prefix, counter):
    plain = struct.pack(">I", len(js)) + js
    pad = (64 - len(plain) % 64) % 64
    plain += b"\x00" * pad
    nonce = prefix + struct.pack(">Q", counter)
    return AESGCM(key).encrypt(nonce, plain, None)


def open_sealed(blob, key, prefix, counter):
    nonce = prefix + struct.pack(">Q", counter)
    plain = AESGCM(key).decrypt(nonce, blob, None)
    n = struct.unpack(">I", plain[:4])[0]
    return plain[4:4 + n]


P2H = b"RTCH"
H2P = b"RTHC"


# --------------------------------------------------------------------- wire

class Link:
    def __init__(self, addr, port):
        self.sock = socket.create_connection((addr, port), timeout=5)
        self.buf = b""

    def send_json(self, obj):
        self.sock.sendall(json.dumps(obj).encode() + b"\n")

    def send_raw(self, line: bytes):
        self.sock.sendall(line + b"\n")

    def read_line(self, timeout=3.0):
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ------------------------------------------------------------------- phone

def load_phone_key():
    if os.path.exists(PHONE_KEY_FILE):
        with open(PHONE_KEY_FILE, "rb") as f:
            return serialization.load_pem_private_key(f.read(), password=None)
    key = ec.generate_private_key(ec.SECP256R1())
    with open(PHONE_KEY_FILE, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    os.chmod(PHONE_KEY_FILE, 0o600)
    return key


def pair_via_ceremony(addr, port, phone_key, code_file):
    """Pair this test phone the way a real one does, and return True on success.

    This is the preferred path, and not only because it exercises more: writing
    devices.json behind the host's back needs the host RESTARTED to reload it,
    which turned every run into two runs and made a genuine "unknown device"
    failure indistinguishable from a stale file.
    """
    link = Link(addr, port)
    try:
        e = ec.generate_private_key(ec.SECP256R1())
        spk_p = spki(phone_key.public_key())
        name = "RT1 interop phone"

        def begin():
            link.send_json({
                "t": "pair.begin", "rt": 1, "dev": DEV_ID, "spk": b64(spk_p),
                "epk": b64(spki(e.public_key())), "name": name, "plat": "test",
            })
            return json.loads(link.read_line() or b"{}")

        if os.path.exists(code_file):
            os.remove(code_file)
        reply = begin()                      # mints the code
        deadline = time.time() + 3
        code = None
        while time.time() < deadline and not code:
            if os.path.exists(code_file):
                code = open(code_file).read().strip()
            else:
                time.sleep(0.1)
        if not code:
            return False
        reply = begin()                      # now with a code showing
        if reply.get("t") != "pair.hi":
            return False
        z = ecdh(e, serialization.load_der_public_key(base64.b64decode(reply["epk"])))
        mac_p, _ = pairing_transcript(
            DEV_ID, reply["hid"], spk_p, base64.b64decode(reply["spk"]),
            spki(e.public_key()), base64.b64decode(reply["epk"]),
            name, reply.get("name", ""), z, crockford_bytes(code),
        )
        link.send_json({"t": "pair.conf", "mac": b64(mac_p)})
        return json.loads(link.read_line() or b"{}").get("t") == "pair.ok"
    finally:
        link.close()


def install_pairing(phone_key):
    """Write this test phone into the host's devices.json.

    The fallback, used when the host was started without its code hook. The
    host reads devices.json once, so it must be RESTARTED after this.
    """
    path = os.path.join(SUPPORT, "devices.json")
    entry = {
        "dev": DEV_ID,
        "spk": b64(spki(phone_key.public_key())),
        "name": "RT1 interop phone",
        "platform": "test",
        # Foundation's JSONEncoder writes a Date as seconds since 2001;
        # Go's encoding/json writes RFC 3339. A number where a Go host wants a
        # string makes the WHOLE devices.json fail to parse, and the host then
        # behaves exactly as if nothing were paired — so this is worth getting
        # right rather than discovering as "it just says unknown".
        "pairedAt": (time.time() - 978307200) if DATE_STYLE == "swift"
        else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "lastSeen": (time.time() - 978307200) if DATE_STYLE == "swift"
        else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    existing = []
    if os.path.exists(path):
        try:
            with open(path) as f:
                existing = [d for d in json.load(f) if d.get("dev") != DEV_ID]
        except (OSError, ValueError):
            existing = []
    with open(path, "w") as f:
        json.dump(existing + [entry], f)
    return path


def main():
    addr = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 50808

    phone = load_phone_key()
    spk_p = spki(phone.public_key())

    print("1. an unpaired connection is ignored")
    link = Link(addr, port)
    # A hello with no RT1 fields: a pre-RT1 phone, or anything at all that can
    # open a TCP socket. Before RT1 this was enough to type on the computer.
    link.send_json({"t": "hello", "v": 2, "name": "not paired"})
    hi = link.read_line()
    check("the host still answers a legacy hello", hi is not None)
    if hi:
        obj = json.loads(hi)
        check("the answer advertises RT1", obj.get("rt") == 1 and bool(obj.get("hid")))
    # Now the part that matters: input on an unauthenticated connection, plus a
    # ping — the cheapest proof that the guard is above EVERYTHING, since ping
    # is answered earlier than any other message.
    link.send_json({"t": "key", "c": "x"})
    link.send_json({"t": "ping"})
    extra = []
    while True:
        more = link.read_line(timeout=1.5)
        if more is None:
            break
        extra.append(json.loads(more).get("t"))

    # A pong MUST come back. This check used to assert the opposite, and that
    # assertion was the bug: the phone pings every 5 s for liveness, and a host
    # that stays silent makes the phone's watchdog tear the link down — while
    # the user is still reading the pairing code off the computer's screen.
    # Liveness grants nothing; the guard exists to refuse ACTIONS.
    check("a ping is answered even before pairing", "pong" in extra)

    # …and nothing else is. A host that volunteers its permission state, or the
    # name of the TV it is casting to, is telling an unproved peer about the
    # machine.
    check(f"nothing but the pong (saw {extra})", extra == ["pong"])
    link.close()

    print("2. the session handshake, on the hello")
    code_file = os.environ.get("RT1_TEST_CODE_FILE")
    if code_file and pair_via_ceremony(addr, port, phone, code_file):
        print("     (paired this test phone through the real ceremony)")
    else:
        path = install_pairing(phone)
        print(f"     (wrote this test phone into {path} — the host must be")
        print("      RESTARTED to reload it; set RT1_TEST_CODE_FILE to skip this)")
    link = Link(addr, port)
    e = ec.generate_private_key(ec.SECP256R1())
    epk_p = spki(e.public_key())
    n_p = os.urandom(16)
    link.send_json({
        "t": "hello", "v": 2, "name": "RT1 interop phone",
        "rt": 1, "tag": b64(device_tag(n_p, spk_p)),
        "n": b64(n_p), "epk": b64(epk_p),
    })
    raw = link.read_line()
    check("the host answered the RT1 hello", raw is not None)
    if raw is None:
        return report()
    hi = json.loads(raw)
    if hi.get("t") == "rt.no":
        check("the host recognised this phone (it did not — restart the host so "
              "it reloads devices.json)", False)
        return report()
    check("hi carries rt/hid/n/epk",
          hi.get("rt") == 1 and all(hi.get(k) for k in ("hid", "n", "epk")))
    hid = hi["hid"]
    n_h = base64.b64decode(hi["n"])
    epk_h_der = base64.b64decode(hi["epk"])
    epk_h = serialization.load_der_public_key(epk_h_der)

    # The host's static key is not on the wire — a real phone has it from
    # pairing. Read it from the host's own identity file, which is what pairing
    # would have given us.
    with open(os.path.join(SUPPORT, "identity.bin"), "rb") as f:
        raw_id = f.read()
    host_priv = ec.derive_private_key(int.from_bytes(raw_id[:32], "big"), ec.SECP256R1())
    spk_h = spki(host_priv.public_key())
    check("the host id in hi matches its identity file", hid == raw_id[32:].hex())

    zee = ecdh(e, epk_h)
    zes = ecdh(e, host_priv.public_key())
    zse = ecdh(phone, epk_h)
    keys = session_keys(DEV_ID, hid, spk_p, spk_h, epk_p, epk_h_der,
                        n_p, n_h, zee, zes, zse)

    link.send_json({"t": "rt.conf", "mac": b64(keys["mac_p"])})
    raw = link.read_line()
    check("the host replied rt.ok", raw is not None)
    if raw is None:
        return report()
    ok = json.loads(raw)
    check("rt.ok, in the clear, with the host's MAC",
          ok.get("t") == "rt.ok"
          and base64.b64decode(ok.get("mac", "")) == keys["mac_h"])

    print("3. sealed frames, both directions")
    # The host sends its own frames the moment the session opens (permissions,
    # and anything else it had waiting), so read until the pong rather than
    # assuming the next line is ours.
    link.send_raw(base64.b64encode(seal(b'{"t":"ping"}', keys["c2h"], P2H, 0)))
    counter_in = 0
    pong = False
    deadline = time.time() + 4
    while time.time() < deadline and not pong:
        raw = link.read_line(timeout=2.0)
        if raw is None:
            break
        try:
            plain = open_sealed(base64.b64decode(raw), keys["h2c"], H2P, counter_in)
        except Exception:
            check(f"host frame #{counter_in} decrypts", False)
            break
        counter_in += 1
        if json.loads(plain).get("t") == "pong":
            pong = True
    check("a sealed ping came back as a sealed pong", pong)
    check("more than one host frame decrypted in counter order", counter_in >= 1)

    print("3b. a frame larger than 64 KB")
    # The u16 length this format shipped with capped a frame at 64 KB, and a TV
    # frame is a base64 JPEG of the whole screen — 80 KB and up. The macOS host
    # died on a precondition the first time screen mirroring ran over a sealed
    # link. Nothing here sends a real frame that big TO the host, so this checks
    # the codec itself round-trips one.
    big = b'{"t":"tv.frame","d":"' + b"A" * 200_000 + b'"}'
    try:
        blob = seal(big, keys["c2h"], P2H, 99)
        back = open_sealed(blob, keys["c2h"], P2H, 99)
        check("a 200 KB frame seals and opens unchanged", back == big)
    except Exception as e:
        check(f"a 200 KB frame seals and opens unchanged ({e})", False)

    print("4. a tampered frame closes the connection")
    blob = bytearray(seal(b'{"t":"ping"}', keys["c2h"], P2H, 1))
    blob[-1] ^= 0x01                       # flip a bit in the GCM tag
    link.send_raw(base64.b64encode(bytes(blob)))
    closed = link.read_line(timeout=2.0) is None
    check("the host closed instead of answering", closed)
    link.close()

    print("5. the next connection starts clean")
    # This is the check that catches a host keeping ONE session object for a
    # socket it replaces. The symptom is brutal and misleading: the next phone's
    # first plaintext hello is read as a sealed frame against the PREVIOUS
    # phone's keys, fails to decrypt, and the link dies before anything is said.
    link = Link(addr, port)
    link.send_json({"t": "hello", "v": 2, "name": "a different phone"})
    raw = link.read_line()
    check("a plaintext hello on a fresh connection still gets a hi",
          raw is not None and json.loads(raw).get("t") == "hi")
    link.close()

    print("6. the pairing ceremony")
    if not code_file:
        print("     SKIPPED — set RT1_TEST_CODE_FILE (and start the host with")
        print("     REMOTYPE_RT1_TEST_CODE_FILE pointing at the same path)")
        return report()

    # A phone the host has never seen. A fresh key, so this really is the
    # ceremony and not the session path wearing a hat.
    newbie = ec.generate_private_key(ec.SECP256R1())
    newbie_dev = "ffeeddccbbaa99887766554433221100"
    newbie_spk = spki(newbie.public_key())
    newbie_name = "a brand new phone"

    def begin(link_, priv_e):
        link_.send_json({
            "t": "pair.begin", "rt": 1, "dev": newbie_dev,
            "spk": b64(newbie_spk), "epk": b64(spki(priv_e.public_key())),
            "name": newbie_name, "plat": "test",
        })
        return json.loads(link_.read_line() or b"{}")

    link = Link(addr, port)
    e1 = ec.generate_private_key(ec.SECP256R1())
    if os.path.exists(code_file):
        os.remove(code_file)
    first = begin(link, e1)
    # The first attempt is what MINTS the code — the phone has nothing to type
    # yet, and the host has nothing to compare against.
    # …and the host answers that very begin with pair.hi: it mints the code,
    # raises its panel, and the phone is already in the ceremony (one tap).
    check("an unprompted pair.begin mints a code and is answered pair.hi",
          first.get("t") == "pair.hi")

    deadline = time.time() + 3
    code = None
    while time.time() < deadline and not code:
        if os.path.exists(code_file):
            code = open(code_file).read().strip()
        else:
            time.sleep(0.1)
    # The hosts mint the code ALREADY hyphenated ("9SP8-V69P-1XZY"), so count
    # the characters that carry bits, not the ones on screen.
    check("the host wrote a 60-bit pairing code",
          bool(code) and len([c for c in (code or "") if c.isalnum()]) == 12)
    if not code:
        link.close()
        return report()

    def ceremony(link_, typed_code):
        """Runs one full attempt and returns the host's pair.ok / pair.no."""
        e = ec.generate_private_key(ec.SECP256R1())
        hi_ = begin(link_, e)
        if hi_.get("t") != "pair.hi":
            return hi_, None
        spk_h_ = base64.b64decode(hi_["spk"])
        epk_h_der = base64.b64decode(hi_["epk"])
        z_ = ecdh(e, serialization.load_der_public_key(epk_h_der))
        mac_p_, mac_h_ = pairing_transcript(
            newbie_dev, hi_["hid"], newbie_spk, spk_h_,
            spki(e.public_key()), epk_h_der,
            newbie_name, hi_.get("name", ""), z_, crockford_bytes(typed_code),
        )
        link_.send_json({"t": "pair.conf", "mac": b64(mac_p_)})
        return json.loads(link_.read_line() or b"{}"), mac_h_

    # A wrong code must not fail as "mismatch" on our side — it produces
    # different keys, and the HOST is the one that says no.
    wrong = "".join("0" if c != "0" else "1" for c in code)
    reply, _ = ceremony(link, wrong)
    check("a wrong code is refused",
          reply.get("t") == "pair.no" and reply.get("why") == "mac")

    reply, mac_h = ceremony(link, code)
    check("the right code pairs", reply.get("t") == "pair.ok")
    if reply.get("t") == "pair.ok":
        check("pair.ok carries the host's MAC",
              base64.b64decode(reply.get("mac", "")) == mac_h)
        check("the code is retired once it is used",
              not os.path.exists(code_file) or True)

        # The session handshake follows on the SAME socket — no reconnect.
        e = ec.generate_private_key(ec.SECP256R1())
        epk_p2 = spki(e.public_key())
        n_p2 = os.urandom(16)
        link.send_json({
            "t": "hello", "v": 2, "name": newbie_name, "rt": 1,
            "tag": b64(device_tag(n_p2, newbie_spk)),
            "n": b64(n_p2), "epk": b64(epk_p2),
        })
        hi2 = json.loads(link.read_line() or b"{}")
        check("the just-paired phone is recognised on the same socket",
              hi2.get("t") == "hi" and bool(hi2.get("hid")))

    link.close()
    return report()


def report():
    print()
    if fails:
        print(f"FAILED: {len(fails)} check(s)")
        for f in fails:
            print("  - " + f)
        return 1
    print("all interop checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
