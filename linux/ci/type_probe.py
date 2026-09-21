#!/usr/bin/env python3
"""Type through a REAL host the way the phone does: pair if needed, open a
sealed RT1 session, and send `text` frames. Pair this with xkey_receiver.py on
a display with the layout under test and you have the whole path — phone
protocol, trust layer, uinput, the X server's layout, a toolkit text field.

    export RT1_FLAVOR=go RT1_SUPPORT_DIR=$HOME/.config/remotype-host \
           RT1_TEST_CODE_FILE=/tmp/rt1code.txt
    python3 ci/type_probe.py 127.0.0.1 50808 "hola ñ;'@é"

Reuses the spec's independent Python implementation (spec/rt1/interop_host.py);
the host must run with REMOTYPE_RT1_TEST_CODE_FILE pointing at the same path so
pairing can read the code the way a user would.
"""
import base64
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "spec", "rt1"))

from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

import interop_host as ih  # noqa: E402
from gen_vectors import b64, ecdh, spki  # noqa: E402


def open_session(addr, port, phone):
    """hello → hi → rt.conf → rt.ok; returns (link, keys)."""
    link = ih.Link(addr, port)
    e = ec.generate_private_key(ec.SECP256R1())
    spk_p = spki(phone.public_key())
    epk_p = spki(e.public_key())
    n_p = os.urandom(16)
    link.send_json({
        "t": "hello", "v": 2, "name": "RT1 type probe", "rt": 1,
        "tag": b64(ih.device_tag(n_p, spk_p)), "n": b64(n_p), "epk": b64(epk_p),
    })
    hi = json.loads(link.read_line() or b"{}")
    if hi.get("t") != "hi":
        raise SystemExit(f"host did not open a session: {hi}")
    with open(os.path.join(ih.SUPPORT, "identity.bin"), "rb") as f:
        raw_id = f.read()
    host_priv = ec.derive_private_key(int.from_bytes(raw_id[:32], "big"), ec.SECP256R1())
    spk_h = spki(host_priv.public_key())
    epk_h_der = base64.b64decode(hi["epk"])
    epk_h = serialization.load_der_public_key(epk_h_der)
    keys = ih.session_keys(
        ih.DEV_ID, hi["hid"], spk_p, spk_h, epk_p, epk_h_der,
        n_p, base64.b64decode(hi["n"]),
        ecdh(e, epk_h), ecdh(e, host_priv.public_key()), ecdh(phone, epk_h),
    )
    link.send_json({"t": "rt.conf", "mac": b64(keys["mac_p"])})
    ok = json.loads(link.read_line() or b"{}")
    if ok.get("t") != "rt.ok":
        raise SystemExit(f"session refused: {ok}")
    return link, keys


def main():
    addr = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 50808
    text = sys.argv[3] if len(sys.argv) > 3 else "hello"
    code_file = os.environ.get("RT1_TEST_CODE_FILE", "/tmp/rt1code.txt")

    phone = ih.load_phone_key()
    # Pair only when the host does not know us: try a session first.
    try:
        link, keys = open_session(addr, port, phone)
    except SystemExit:
        if not ih.pair_via_ceremony(addr, port, phone, code_file):
            raise SystemExit("pairing failed")
        link, keys = open_session(addr, port, phone)

    counter = 0
    for ch in text:
        frame = json.dumps({"t": "key", "c": ch, "mods": 0}).encode()
        link.send_raw(base64.b64encode(ih.seal(frame, keys["c2h"], ih.P2H, counter)))
        counter += 1
        time.sleep(0.05)
    # Prove the session is still alive after all that: sealed ping → pong.
    link.send_raw(base64.b64encode(ih.seal(b'{"t":"ping"}', keys["c2h"], ih.P2H, counter)))
    raw = link.read_line(timeout=3)
    if raw is None:
        raise SystemExit("no pong after typing — the session died")
    plain = ih.open_sealed(base64.b64decode(raw), keys["h2c"], ih.H2P, 0)
    print(f"typed {len(text)} characters; host answered {plain.decode()}")
    link.close()


if __name__ == "__main__":
    main()
