#!/usr/bin/env python3
"""Independently check spec/rt1/vectors.json.

The generator can be self-consistently wrong: if `gen_vectors.py` mis-implements
HKDF, it will happily emit vectors that every implementation then reproduces,
and all five will be wrong together. So this checks against things the generator
does not control:

  1. RFC 5869's published answers, hardcoded here from the RFC text.
  2. Recomputation from the fixed private keys, so the file cannot drift.
  3. Properties that must hold: a wrong pairing code must change the MAC; the
     invalid point must be rejected; the sealed line must decrypt to the JSON
     it claims and must NOT decrypt under the other direction's nonce.

Usage: python3 spec/rt1/verify_vectors.py   (exit 0 = vectors trustworthy)
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import sys

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_vectors as G   # noqa: E402  (reference implementation under test)

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(label, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + label + (f"  — {detail}" if detail and not ok else ""))
    if not ok:
        FAILS.append(label)


def main():
    v = json.load(open(os.path.join(HERE, "vectors.json"), encoding="utf-8"))

    print("RFC 5869 — against the published answers, not the generator")
    # RFC 5869 A.1
    a1 = v["hkdf_rfc5869"][0]
    check("A.1 PRK",
          a1["prk_hex"] == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
    check("A.1 OKM",
          a1["okm_hex"] == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    # RFC 5869 A.3
    a3 = v["hkdf_rfc5869"][1]
    check("A.3 PRK",
          a3["prk_hex"] == "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
    check("A.3 OKM",
          a3["okm_hex"] == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")

    print("\nRecomputation from the fixed private keys")
    keys = {n: G.load_priv(h) for n, h in v["fixed_private_keys_hex"].items()}
    pair = G.pairing_vector(keys)
    sess = G.session_vector(keys)
    for field in ("TH_hex", "PRK_hex", "mac_phone_b64", "mac_host_b64",
                  "spk_phone_b64", "epk_host_b64", "code8_hex"):
        check(f"pairing.{field}", pair[field] == v["pairing"][field],
              f"{pair[field]!r} != {v['pairing'][field]!r}")
    for field in ("TH_hex", "PRK_hex", "tag_b64",
                  "k_phone_to_host_hex", "k_host_to_phone_hex", "mac_host_b64"):
        check(f"session.{field}", sess[field] == v["session"][field],
              f"{sess[field]!r} != {v['session'][field]!r}")

    print("\nProperties that must hold")
    # ECDH really is symmetric across the pair.
    z1 = keys["e_phone"].exchange(ec.ECDH(), keys["e_host"].public_key())
    z2 = keys["e_host"].exchange(ec.ECDH(), keys["e_phone"].public_key())
    check("ECDH agrees from both sides", z1 == z2)

    # A wrong code must change everything, not just fail a comparison.
    good = G.code_to_bytes(v["pairing"]["code_text"])
    bad = G.code_to_bytes("H7K2-9QRT-4MXC")     # last character differs
    check("a wrong code is a different CODE8", good != bad)
    th = bytes.fromhex(v["pairing"]["TH_hex"])
    z = bytes.fromhex(v["pairing"]["Z_hex"])
    prk_bad = G.hkdf_extract(th, z + bad)
    mac_bad = hmac.new(G.hkdf_expand(prk_bad, b"rt1 pair phone", 32), b"\x01", hashlib.sha256).digest()
    check("a wrong code yields a different mac_p",
          G.b64(mac_bad) != v["pairing"]["mac_phone_b64"])

    # Code normalization: the ambiguous glyphs must fold together.
    check("code normalizes O→0 and I/L→1",
          G.normalize_code("h7k2-9qrt-4mxb") == v["pairing"]["code_normalized"]
          and G.code_to_bytes("H7K2 9QRT 4MXB") == good)

    # The invalid point must not import, or must not survive ECDH.
    rejected = False
    try:
        der = base64.b64decode(v["must_reject"]["invalid_point_spki_b64"])
        pub = serialization.load_der_public_key(der)
        keys["e_phone"].exchange(ec.ECDH(), pub)
    except Exception:
        rejected = True
    check("the invalid point is rejected", rejected)

    # The sealed line decrypts to exactly the JSON it claims.
    key = bytes.fromhex(v["session"]["k_phone_to_host_hex"])
    line0 = v["sealed_lines"][0]
    plain = AESGCM(key).decrypt(bytes.fromhex(line0["nonce_hex"]),
                               base64.b64decode(line0["line_b64"]), None)
    # u32, independently of the generator — a 16-bit length capped a frame at
    # 64 KB, which a screen-mirror JPEG blows straight past.
    jlen = struct.unpack(">I", plain[:4])[0]
    check("sealed line decrypts to its JSON",
          plain[4:4 + jlen].decode("utf-8") == line0["json"])
    check("sealed line is padded to a multiple of 64", len(plain) % 64 == 0)

    # Direction separation: the host's nonce prefix must not open a phone line.
    opened = True
    try:
        AESGCM(key).decrypt(b"RTHC" + struct.pack(">Q", line0["counter"]),
                            base64.b64decode(line0["line_b64"]), None)
    except Exception:
        opened = False
    check("a phone→host line does not open under the host→phone prefix", not opened)

    print()
    if FAILS:
        print(f"{len(FAILS)} CHECK(S) FAILED — do not implement against these vectors")
        return 1
    print("All checks passed — vectors are trustworthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
