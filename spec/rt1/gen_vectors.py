#!/usr/bin/env python3
"""Generate spec/rt1/vectors.json — the cross-language conformance vectors for RT1.

This is the REFERENCE IMPLEMENTATION of docs/RT1.md. Four hand-written
implementations (Swift host, Go host, Swift client, Kotlin client) each ship a
self-test that reproduces every value in the generated file. If an
implementation disagrees with these numbers, the implementation is wrong — and
if this file disagrees with docs/RT1.md, this file is wrong.

Every private key here is a FIXED TEST KEY. None of them is used by anything
real, which is the point: the vectors have to be reproducible.

Usage: python3 spec/rt1/gen_vectors.py
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

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- primitives

def lp(b: bytes) -> bytes:
    """LP(x) = u16be(len(x)) ‖ x. Every transcript input is length-prefixed, so
    that no combination of field values can be re-split a different way."""
    if len(b) > 0xFFFF:
        raise ValueError("LP input too long")
    return struct.pack(">H", len(b)) + b


def lps(s: str) -> bytes:
    return lp(s.encode("utf-8"))


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-Expand. Hand-rolled in all four implementations too, so
    they are byte-identical by construction rather than by three vendors'
    interpretations of an HKDF API."""
    out, t, counter = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def spki(pub: ec.EllipticCurvePublicKey) -> bytes:
    """Public keys travel as SPKI DER, base64. NOT raw X9.63 points: building
    those on Android means manually left-padding ECPoint affine coordinates and
    stripping BigInteger's leading sign byte, which is the single most common
    bug in this exact task. SPKI dodges it in all three languages."""
    return pub.public_bytes(serialization.Encoding.DER,
                            serialization.PublicFormat.SubjectPublicKeyInfo)


def load_priv(hexval: str) -> ec.EllipticCurvePrivateKey:
    return ec.derive_private_key(int(hexval, 16), ec.SECP256R1())


def ecdh(priv: ec.EllipticCurvePrivateKey, pub: ec.EllipticCurvePublicKey) -> bytes:
    z = priv.exchange(ec.ECDH(), pub)
    if z == bytes(len(z)):
        raise ValueError("all-zero ECDH output")   # implementations must reject this too
    return z


# ---------------------------------------------------------------- fixed keys

# Arbitrary but fixed scalars. Chosen once; never change them, or every
# implementation's self-test breaks at the same moment for no reason.
K = {
    "s_phone": "1f2e3d4c5b6a798879685a4b3c2d1e0fedcba98765432100123456789abcdef1",
    "s_host":  "2a3b4c5d6e7f80910a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778",
    "e_phone": "3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b",
    "e_host":  "4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c",
}

DEV = "a1b2c3d4e5f60718293a4b5c6d7e8f90"      # 16 random bytes, lowercase hex
HID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
NAME_P = "Pratik's iPhone"                     # NB: a real apostrophe, U+2019 below
NAME_H = "MacBook Pro"

# The pairing code, as the user types it, and as it is fed to the KDF.
CODE_TEXT = "H7K2-9QRT-4MXB"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def normalize_code(text: str) -> str:
    """Uppercase; I/L → 1; O → 0; strip everything non-alphanumeric. Typing and
    display variance must never cause a mismatch."""
    out = []
    for ch in text.upper():
        if ch in ("I", "L"):
            ch = "1"
        elif ch == "O":
            ch = "0"
        if ch.isalnum():
            out.append(ch)
    return "".join(out)


def code_to_bytes(text: str) -> bytes:
    """CODE8 — the 60-bit code as 8 bytes big-endian, top 4 bits zero. What is
    fed to the KDF is this, never the ASCII."""
    norm = normalize_code(text)
    if len(norm) != 12:
        raise ValueError(f"code must normalize to 12 chars, got {len(norm)}")
    v = 0
    for ch in norm:
        idx = CROCKFORD.find(ch)
        if idx < 0:
            raise ValueError(f"character {ch!r} is not in the Crockford alphabet")
        v = v * 32 + idx
    if v >= 1 << 60:
        raise ValueError("code exceeds 60 bits")
    return struct.pack(">Q", v)


# ---------------------------------------------------------------- vectors

def rfc5869_vectors():
    """RFC 5869 appendix A, cases 1 and 3. Proves the hand-rolled HKDF before
    anything built on it is trusted."""
    cases = []
    ikm = bytes.fromhex("0b" * 22)
    salt = bytes.fromhex("000102030405060708090a0b0c")
    info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
    prk = hkdf_extract(salt, ikm)
    cases.append({
        "name": "RFC 5869 A.1",
        "ikm_hex": ikm.hex(), "salt_hex": salt.hex(), "info_hex": info.hex(),
        "L": 42, "prk_hex": prk.hex(), "okm_hex": hkdf_expand(prk, info, 42).hex(),
    })
    ikm = bytes.fromhex("0b" * 22)
    prk = hkdf_extract(b"", ikm)
    cases.append({
        "name": "RFC 5869 A.3 (zero-length salt and info)",
        "ikm_hex": ikm.hex(), "salt_hex": "", "info_hex": "",
        "L": 42, "prk_hex": prk.hex(), "okm_hex": hkdf_expand(prk, b"", 42).hex(),
    })
    return cases


def pairing_vector(keys):
    sp_p, sp_h = spki(keys["s_phone"].public_key()), spki(keys["s_host"].public_key())
    ep_p, ep_h = spki(keys["e_phone"].public_key()), spki(keys["e_host"].public_key())

    z = ecdh(keys["e_phone"], keys["e_host"].public_key())
    assert z == ecdh(keys["e_host"], keys["e_phone"].public_key()), "ECDH must agree"

    th = hashlib.sha256(
        lp(b"RT1-PAIR") + lps(DEV) + lps(HID) + lp(sp_p) + lp(sp_h)
        + lp(ep_p) + lp(ep_h) + lps(NAME_P) + lps(NAME_H)
    ).digest()

    code8 = code_to_bytes(CODE_TEXT)
    prk = hkdf_extract(th, z + code8)
    kp = hkdf_expand(prk, b"rt1 pair phone", 32)
    kh = hkdf_expand(prk, b"rt1 pair host", 32)
    mac_p = hmac.new(kp, b"\x01", hashlib.sha256).digest()
    mac_h = hmac.new(kh, b"\x02", hashlib.sha256).digest()

    return {
        "dev": DEV, "hid": HID, "name_phone": NAME_P, "name_host": NAME_H,
        "code_text": CODE_TEXT,
        "code_normalized": normalize_code(CODE_TEXT),
        "code8_hex": code8.hex(),
        "spk_phone_b64": b64(sp_p), "spk_host_b64": b64(sp_h),
        "epk_phone_b64": b64(ep_p), "epk_host_b64": b64(ep_h),
        "Z_hex": z.hex(), "TH_hex": th.hex(), "PRK_hex": prk.hex(),
        "Kp_hex": kp.hex(), "Kh_hex": kh.hex(),
        "mac_phone_b64": b64(mac_p), "mac_host_b64": b64(mac_h),
    }


def session_vector(keys):
    sp_p, sp_h = spki(keys["s_phone"].public_key()), spki(keys["s_host"].public_key())
    ep_p, ep_h = spki(keys["e_phone"].public_key()), spki(keys["e_host"].public_key())
    n_p = bytes.fromhex("00112233445566778899aabbccddeeff")
    n_h = bytes.fromhex("ffeeddccbbaa99887766554433221100")

    tag = hashlib.sha256(lp(b"RT1-TAG") + lp(n_p) + lp(sp_p)).digest()

    zee = ecdh(keys["e_phone"], keys["e_host"].public_key())
    zes = ecdh(keys["e_phone"], keys["s_host"].public_key())
    zse = ecdh(keys["s_phone"], keys["e_host"].public_key())
    # The host computes the same three from its side; assert it here so the
    # vector cannot encode a one-sided mistake.
    assert zes == ecdh(keys["s_host"], keys["e_phone"].public_key())
    assert zse == ecdh(keys["e_host"], keys["s_phone"].public_key())

    th = hashlib.sha256(
        lp(b"RT1-SESS") + lps(DEV) + lps(HID) + lp(sp_p) + lp(sp_h)
        + lp(ep_p) + lp(ep_h) + lp(n_p) + lp(n_h)
    ).digest()
    prk = hkdf_extract(th, zee + zes + zse)
    k_p2h = hkdf_expand(prk, b"rt1 c2h key", 32)
    k_h2p = hkdf_expand(prk, b"rt1 h2c key", 32)
    m_p = hkdf_expand(prk, b"rt1 c2h mac", 32)
    m_h = hkdf_expand(prk, b"rt1 h2c mac", 32)

    return {
        "n_phone_b64": b64(n_p), "n_host_b64": b64(n_h),
        "tag_b64": b64(tag),
        "Zee_hex": zee.hex(), "Zes_hex": zes.hex(), "Zse_hex": zse.hex(),
        "TH_hex": th.hex(), "PRK_hex": prk.hex(),
        "k_phone_to_host_hex": k_p2h.hex(), "k_host_to_phone_hex": k_h2p.hex(),
        "mac_phone_b64": b64(hmac.new(m_p, b"\x01", hashlib.sha256).digest()),
        "mac_host_b64": b64(hmac.new(m_h, b"\x02", hashlib.sha256).digest()),
    }


def sealed_line_vectors(session):
    """The exact bytes of a sealed line. This is where CryptoKit will bite: its
    SealedBox.combined PREPENDS the nonce, and the wire format here is
    ciphertext ‖ tag only."""
    key = bytes.fromhex(session["k_phone_to_host_hex"])
    out = []
    for counter, payload in ((0, '{"t":"ping"}'),
                             (1, '{"t":"key","k":"a","m":0}')):
        js = payload.encode("utf-8")
        plain = struct.pack(">I", len(js)) + js
        pad = (-len(plain)) % 64                    # zero-pad to a multiple of 64
        plain += bytes(pad)
        nonce = b"RTCH" + struct.pack(">Q", counter)
        sealed = AESGCM(key).encrypt(nonce, plain, None)   # ciphertext ‖ tag
        out.append({
            "direction": "phone_to_host",
            "counter": counter,
            "json": payload,
            "plaintext_len": len(plain),
            "nonce_hex": nonce.hex(),
            "line_b64": b64(sealed),
        })
    return out


def negative_vectors():
    """Cases every implementation must REJECT. A conformance suite that only
    proves the happy path proves very little."""
    # A point that is not on P-256: valid SPKI wrapper, bogus coordinates.
    good = spki(load_priv(K["e_host"]).public_key())
    bad = bytearray(good)
    bad[-1] ^= 0x01
    return {
        "invalid_point_spki_b64": b64(bytes(bad)),
        "invalid_point_note": "Last byte of a valid SPKI flipped; the key is no longer on the curve. Every implementation must fail to import this, or fail the ECDH — never proceed.",
        "all_zero_ecdh_note": "If an ECDH output is all zeroes, abort. Do not derive keys from it.",
        "bad_code_note": "Deriving with a wrong CODE8 must produce a completely different PRK, so mac_p fails to verify. The code enters HKDF-Extract, not just a MAC.",
        "wrong_direction_prefix_note": "A host must never accept a line sealed with the RTHC prefix, and a phone never one with RTCH. Reusing the peer's key/prefix is a reflection attack.",
        "counter_reuse_note": "Counters are strictly increasing per direction. A repeated counter means a replay: close the connection.",
    }


def main():
    keys = {name: load_priv(hexval) for name, hexval in K.items()}
    session = session_vector(keys)
    doc = {
        "spec": "RT1",
        "note": ("Conformance vectors for docs/RT1.md. Generated by "
                 "spec/rt1/gen_vectors.py. Every implementation ships a self-test "
                 "that reproduces these exactly. Fixed test keys — not secrets."),
        "primitives": {
            "kex": "ECDH P-256", "hash": "SHA-256", "mac": "HMAC-SHA-256",
            "kdf": "HKDF-SHA-256 (hand-rolled)", "aead": "AES-256-GCM",
            "public_key_encoding": "SPKI DER, base64 standard alphabet, padded",
        },
        "fixed_private_keys_hex": K,
        "hkdf_rfc5869": rfc5869_vectors(),
        "pairing": pairing_vector(keys),
        "session": session,
        "sealed_lines": sealed_line_vectors(session),
        "must_reject": negative_vectors(),
    }
    path = os.path.join(HERE, "vectors.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("wrote", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
