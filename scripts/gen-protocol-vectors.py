#!/usr/bin/env python3
"""Golden test vectors for the WiredDisplay session protocol (version 6).

An independent implementation of the wire format, written from the Swift
sources (Shared/Protocol/FrameHeader.swift, Shared/Session/Messages.swift,
Shared/Session/Wire.swift, Shared/Session/SecureChannel.swift). Swift checks
its real code against the output in Tests/Unit/WDSessionTests/
ProtocolVectorTests.swift; a future Android (Kotlin) client checks against the
same file. If this script and Swift disagree, the Swift test fails.

Every key here is derived from a public label: these vectors carry no secret.

Usage (needs the `cryptography` package):
    python3 -I scripts/gen-protocol-vectors.py            # writes the file
    python3 -I scripts/gen-protocol-vectors.py --check    # fails if it is stale
"""
import hashlib
import json
import os
import struct
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "Vectors", "protocol-v6.json")

PROTOCOL_VERSION = 6
FRAME_MAGIC = 0x57445350  # "WDSP"
FRAME_VERSION = 1
HOST, CLIENT = 1, 2
STREAM = {"control": 0, "input": 1, "video": 2, "speaker": 3, "microphone": 4, "camera": 5}
FLAG_KEYFRAME, FLAG_AUTHENTICATED = 1, 2
TAG_LENGTH = 16


def seed(label):
    return hashlib.sha256(("WiredDisplay test vector: " + label).encode()).digest()


def raw_public(key):
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


# ---------- messages (Messages.swift, big-endian except audio samples) ----------

def u8(v): return struct.pack(">B", v)
def u16(v): return struct.pack(">H", v)
def u32(v): return struct.pack(">I", v)
def u64(v): return struct.pack(">Q", v)
def f32(v):
    packed = struct.pack(">f", v)
    assert struct.unpack(">f", packed)[0] == v, f"{v} is not exact in float32"
    return packed


def truncated_utf8(text, max_bytes):
    # Swift drops whole Characters; every character used here is one code point.
    out = ""
    for ch in text:
        if len((out + ch).encode()) > max_bytes:
            break
        out += ch
    return out


def string(text, max_bytes):
    data = truncated_utf8(text, max_bytes).encode()
    return u16(len(data)) + data


def auth_hello(role, identity, ephemeral):
    return u8(9) + u16(PROTOCOL_VERSION) + u8(role) + identity + ephemeral


def auth_proof(signature):
    assert len(signature) == 64
    return u8(10) + signature


CONTROL = [
    ("hello", u8(1) + u16(6) + u8(CLIENT) + string("Tab Ünï 11", 64) + u32(2560) + u32(1600) + u8(2) + u16(120)
     + u8(3) + u16(274)),
    ("hello_name_truncated", u8(1) + u16(6) + u8(CLIENT) + string("é" * 40, 64) + u32(2400) + u32(1080) + u8(3)
     + u16(90) + u8(1) + u16(0)),
    ("streamConfig", u8(2) + u32(2560) + u32(1600) + u32(1440) + u32(900) + u16(60) + u8(2)),
    ("requestKeyframe", u8(3)),
    ("ping", u8(4) + u64(0xFEDCBA9876543210)),
    ("pong", u8(5) + u64(0x0123456789ABCDEF)),
    ("bye", u8(6) + string("selesai", 256)),
    ("audioRoute_speaker", u8(7) + u8(1)),
    ("audioRoute_both", u8(7) + u8(3)),
    ("videoActive_false", u8(8) + u8(0)),
    ("decodeFailed", u8(11)),
    ("brightness", u8(12) + f32(0.75)),
    ("cursor", u8(13) + f32(0.25) + f32(0.5) + u8(1)),
    ("cursorImage", u8(14) + f32(0.015625) + f32(0.03125) + f32(0.125) + f32(0.0) + u16(4) + bytes([0x89, 0x50, 0x4E, 0x47])),
    ("panelSize", u8(15) + u32(1600) + u32(2560)),
]

INPUT = [
    ("pointer_move", u8(1) + u8(1) + u8(0) + f32(0.5) + f32(0.25)),
    ("pointer_down_left", u8(1) + u8(2) + u8(1) + f32(1.0) + f32(0.0)),
    ("pointer_up_right", u8(1) + u8(3) + u8(2) + f32(0.125) + f32(0.875)),
    ("scroll", u8(2) + f32(-12.5) + f32(40.0)),
    ("releaseAll", u8(3)),
    ("key_a_down", u8(4) + u16(0x04) + u8(1)),
    ("key_rightCommand_up", u8(4) + u16(0xE7) + u8(0)),
    ("gestureScroll_changed", u8(5) + f32(1.5) + f32(-3.0) + u8(2) + u8(0)),
    ("gestureScroll_momentum", u8(5) + f32(0.0) + f32(6.25) + u8(0) + u8(2)),
    ("magnify_began", u8(6) + f32(0.0625) + u8(1)),
    ("rotate_ended", u8(7) + f32(-15.0) + u8(3)),
]

# Audio samples are LITTLE-endian (AudioPacket.encoded), unlike everything else.
AUDIO = [
    ("speaker_stereo", 2, [1, -2, 32767, -32768]),
    ("microphone_mono", 1, [256, -1, 0]),
]


def audio_packet(channels, samples):
    return u8(channels) + b"".join(struct.pack("<h", s) for s in samples)


# ---------- frames (FrameHeader.swift, SecureChannel.swift) ----------

def header(stream, flags, session, sequence, timestamp, length):
    return (u32(FRAME_MAGIC) + u8(FRAME_VERSION) + u8(STREAM[stream]) + u16(flags) + u64(session) + u64(sequence)
            + u64(timestamp) + u32(length))


def clear_frame(stream, session, sequence, timestamp, payload):
    return header(stream, 0, session, sequence, timestamp, len(payload)) + payload


def nonce(stream, sequence):
    return bytes([STREAM[stream], 0, 0, 0]) + u64(sequence)


def sealed_frame(key, stream, session, sequence, timestamp, payload, keyframe=False):
    flags = FLAG_AUTHENTICATED | (FLAG_KEYFRAME if keyframe else 0)
    head = header(stream, flags, session, sequence, timestamp, len(payload) + TAG_LENGTH)
    return head + AESGCM(key).encrypt(nonce(stream, sequence), payload, head)  # ciphertext || tag


def hkdf(secret, salt, info, length):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(secret)


def proof_message(role, transcript):
    return b"WiredDisplay proof v2" + bytes([role]) + transcript


def build():
    host_identity = Ed25519PrivateKey.from_private_bytes(seed("host identity"))
    client_identity = Ed25519PrivateKey.from_private_bytes(seed("client identity"))
    host_ephemeral = X25519PrivateKey.from_private_bytes(seed("host ephemeral"))
    # Pick the client ephemeral key so that the pairing-code integer has its
    # top bit set: a signed 64-bit modulo (Kotlin Long %) then gives a wrong code.
    attempt = 0
    while True:
        client_seed = seed(f"client ephemeral {attempt}")
        client_ephemeral = X25519PrivateKey.from_private_bytes(client_seed)
        host_hello = auth_hello(HOST, raw_public(host_identity), raw_public(host_ephemeral))
        client_hello = auth_hello(CLIENT, raw_public(client_identity), raw_public(client_ephemeral))
        shared = host_ephemeral.exchange(X25519PublicKey.from_public_bytes(raw_public(client_ephemeral)))
        assert shared == client_ephemeral.exchange(X25519PublicKey.from_public_bytes(raw_public(host_ephemeral)))
        transcript = hashlib.sha256(b"WiredDisplay auth v2" + host_hello + client_hello).digest()
        code_bytes = hkdf(shared, transcript, b"pairing code", 8)
        code_value = int.from_bytes(code_bytes, "big")
        if code_value >= 1 << 63:
            break
        attempt += 1

    host_to_client = hkdf(shared, transcript, b"host->client", 32)
    client_to_host = hkdf(shared, transcript, b"client->host", 32)
    digits = f"{code_value % 1_000_000:06d}"
    # What a signed Java/Kotlin `Long % 1_000_000` would give (truncated division).
    as_signed = code_value - (1 << 64)
    java_signed_remainder = -((-as_signed) % 1_000_000)

    host_proof = host_identity.sign(proof_message(HOST, transcript))
    client_proof = client_identity.sign(proof_message(CLIENT, transcript))
    Ed25519PublicKey.from_public_bytes(raw_public(host_identity)).verify(host_proof, proof_message(HOST, transcript))
    Ed25519PublicKey.from_public_bytes(raw_public(client_identity)).verify(client_proof, proof_message(CLIENT, transcript))

    host_session, client_session = 0xF0E1D2C3B4A59687, 0x8877665544332211
    ts = 0x0000_0123_4567_89AB
    ping = dict(CONTROL)["ping"]
    pointer = dict(INPUT)["pointer_down_left"]
    microphone = audio_packet(1, [256, -1, 0])
    video_payload = bytes([0, 0, 0, 1, 0x40, 0x01, 0x0C, 0x01]) + bytes(range(8))
    video_sequence = 0x0000_0001_0000_0002

    frames = {
        # host -> client
        "host_auth_hello": clear_frame("control", host_session, 0, ts, host_hello),
        "host_proof": sealed_frame(host_to_client, "control", host_session, 1, ts + 1, auth_proof(host_proof)),
        "host_ping": sealed_frame(host_to_client, "control", host_session, 2, ts + 2, ping),
        "host_video_keyframe": sealed_frame(host_to_client, "video", host_session, video_sequence, ts + 3,
                                            video_payload, keyframe=True),
        # client -> host
        "client_auth_hello": clear_frame("control", client_session, 0, ts + 10, client_hello),
        "client_proof": sealed_frame(client_to_host, "control", client_session, 1, ts + 11, auth_proof(client_proof)),
        "client_input": sealed_frame(client_to_host, "input", client_session, 0, ts + 12, pointer),
        "client_microphone": sealed_frame(client_to_host, "microphone", client_session, 0, ts + 13, microphone),
    }
    # Self-check: every sealed frame opens with the right key and AAD.
    for name, wire in frames.items():
        flags = struct.unpack(">H", wire[6:8])[0]
        if flags & FLAG_AUTHENTICATED:
            key = host_to_client if name.startswith("host") else client_to_host
            stream = wire[5]
            sequence = struct.unpack(">Q", wire[16:24])[0]
            AESGCM(key).decrypt(bytes([stream, 0, 0, 0]) + u64(sequence), wire[36:], wire[:36])

    hx = lambda b: b.hex()
    return {
        "description": "WiredDisplay session protocol v6 golden vectors. Generated by scripts/gen-protocol-vectors.py "
                       "from the Swift sources; checked by Tests/Unit/WDSessionTests/ProtocolVectorTests.swift. "
                       "Keys are derived from public labels and are not secret.",
        "protocolVersion": PROTOCOL_VERSION,
        "notes": [
            "Everything is big-endian except AudioPacket samples, which are little-endian int16.",
            "u64 fields (session ID, sequence, timestamp, ping values) are unsigned; the vectors use values with the top bit set.",
            "Pairing code: first 8 HKDF bytes as a big-endian UNSIGNED 64-bit integer, modulo 1000000, six digits, "
            "shown as 'ddd ddd'. In these vectors a signed 64-bit modulo gives a different, negative result.",
            "AES-256-GCM nonce = stream byte, 0, 0, 0, sequence (u64 BE). AAD = the 36-byte header as sent "
            "(authenticated flag set, payloadLength = plaintext + 16). Wire payload = ciphertext || 16-byte tag.",
            "Our own authHello always goes in the clear as control sequence 0.",
            "Ed25519 signatures from CryptoKit may be randomized; only verify them, never compare them to these bytes.",
        ],
        "keys": {
            "hostIdentitySeed": hx(seed("host identity")),
            "hostIdentityPublic": hx(raw_public(host_identity)),
            "clientIdentitySeed": hx(seed("client identity")),
            "clientIdentityPublic": hx(raw_public(client_identity)),
            "hostEphemeralPrivate": hx(seed("host ephemeral")),
            "hostEphemeralPublic": hx(raw_public(host_ephemeral)),
            "clientEphemeralPrivate": hx(client_seed),
            "clientEphemeralPublic": hx(raw_public(client_ephemeral)),
        },
        "handshake": {
            "hostAuthHelloPayload": hx(host_hello),
            "clientAuthHelloPayload": hx(client_hello),
            "sharedSecret": hx(shared),
            "transcript": hx(transcript),
            "hostToClientKey": hx(host_to_client),
            "clientToHostKey": hx(client_to_host),
            "pairingCodeBytes": hx(code_bytes),
            "pairingCodeUnsigned": str(code_value),
            "pairingCode": f"{digits[:3]} {digits[3:]}",
            "signedModuloWouldGive": java_signed_remainder,
            "hostProofMessage": hx(proof_message(HOST, transcript)),
            "clientProofMessage": hx(proof_message(CLIENT, transcript)),
            "hostProofSignature": hx(host_proof),
            "clientProofSignature": hx(client_proof),
            "hostFingerprint": hashlib.sha256(raw_public(host_identity)).digest()[:8].hex(),
            "clientFingerprint": hashlib.sha256(raw_public(client_identity)).digest()[:8].hex(),
        },
        "session": {
            "hostSessionID": f"{host_session:016x}",
            "clientSessionID": f"{client_session:016x}",
            "baseTimestamp": f"{ts:016x}",
            "videoSequence": f"{video_sequence:016x}",
        },
        "frames": {name: hx(wire) for name, wire in frames.items()},
        "framePlaintexts": {
            "host_ping": hx(ping),
            "host_video_keyframe": hx(video_payload),
            "client_input": hx(pointer),
            "client_microphone": hx(microphone),
        },
        "control": {name: hx(data) for name, data in CONTROL},
        "input": {name: hx(data) for name, data in INPUT},
        "audio": {name: {"channels": ch, "samples": s, "hex": hx(audio_packet(ch, s))} for name, ch, s in AUDIO},
    }


def main():
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as f:
            if f.read() != text:
                sys.exit("protocol-v6.json is stale: run scripts/gen-protocol-vectors.py")
        print("protocol-v6.json is up to date")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
