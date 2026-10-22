#!/usr/bin/env python3
"""Check that PK.auth / KEK.auth / db.auth form one Secure Boot hierarchy.

Each .auth file is an EFI_VARIABLE_AUTHENTICATION_2 envelope. This verifies
the PKCS#7 signature of every envelope the way firmware would on SetVariable
(UEFI 2.10, 8.2.2): PK is self-signed by PK, KEK is signed by PK, db is signed
by KEK. All three payloads must carry exactly their matching PEM certificate.
CMS signers must be the exact enrolled key; host CA stores are never used.
Certificate expiry is not used for Secure Boot key authorization.

usage: verify-auth-chain.py <dir with PK.auth KEK.auth db.auth PK.pem KEK.pem db.pem>
"""

import base64
import os
import datetime
import struct
import subprocess
import sys
import tempfile

GLOBAL = bytes.fromhex("61dfe48bca93d211aa0d00e098032b8c")
SECURITY_DB = bytes.fromhex("cbb219d73a3d9645a3bcdad00e67656f")
CERT_X509 = bytes.fromhex("a159c0a5e494a74a87b5ab155c2bf072")
PKCS7_OID = bytes.fromhex("06092a864886f70d010702")
DATA_OID = bytes.fromhex("06092a864886f70d010701")
CERT_PKCS7 = bytes.fromhex("9dd2af4adf68ee498aa9347d375665a7")
# NV | BS | RT | TIME_BASED_AUTHENTICATED_WRITE_ACCESS
ATTRS = 0x27

CHAIN = [  # (variable, vendor GUID, signer)
    ("PK", GLOBAL, "PK"),
    ("KEK", GLOBAL, "PK"),
    ("db", SECURITY_DB, "KEK"),
]


def der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def der_element(data: bytes, expected: int) -> tuple[bytes, bytes]:
    """Read a definite, minimally encoded DER element; never accept truncation."""
    if len(data) < 2 or data[0] != expected:
        raise ValueError("invalid DER tag or truncated element")
    size, start = data[1], 2
    if size & 0x80:
        count = size & 0x7f
        if not count or count > 4 or len(data) < 2 + count or data[2] == 0:
            raise ValueError("invalid DER length")
        size, start = int.from_bytes(data[2:2 + count], "big"), 2 + count
        if size < 128:
            raise ValueError("non-minimal DER length")
    end = start + size
    if end > len(data):
        raise ValueError("truncated DER value")
    return data[start:end], data[end:]


def as_content_info(sig: bytes) -> bytes:
    """Accept only detached id-data SignedData, including EDK2's bare form."""
    fields, trailing = der_element(sig, 0x30)
    if trailing:
        raise ValueError("trailing data after PKCS#7")
    if fields.startswith(PKCS7_OID):
        explicit, remaining = der_element(fields[len(PKCS7_OID):], 0xa0)
        fields, trailing = der_element(explicit, 0x30)
        if remaining or trailing:
            raise ValueError("invalid PKCS#7 ContentInfo")
        wrapped = sig
    else:
        body = PKCS7_OID + b"\xa0" + der_len(len(sig)) + sig
        wrapped = b"\x30" + der_len(len(body)) + body
    _, fields = der_element(fields, 0x02)  # version
    _, fields = der_element(fields, 0x31)  # digestAlgorithms
    content, _ = der_element(fields, 0x30)
    if content != DATA_OID:
        raise ValueError("authenticated variables require detached id-data content")
    return wrapped


def parse_auth(blob: bytes) -> tuple[bytes, bytes]:
    if len(blob) < 40:
        raise ValueError("truncated authentication envelope")
    year, month, day, hour, minute, second = struct.unpack_from("<H5B", blob)
    if year < 1900:
        raise ValueError("authentication timestamp year is outside the EFI_TIME range")
    datetime.datetime(year, month, day, hour, minute, second)
    if any(blob[7:16]):
        raise ValueError("reserved authentication timestamp fields must be zero")
    length, revision, cert_type = struct.unpack_from("<IHH", blob, 16)
    if revision != 0x200 or cert_type != 0xEF1 or blob[24:40] != CERT_PKCS7:
        raise ValueError("invalid WIN_CERTIFICATE_UEFI_GUID/PKCS7 header")
    if length <= 24 or 16 + length >= len(blob):
        raise ValueError("invalid authentication envelope length")
    return as_content_info(blob[40:16 + length]), blob[16 + length:]


def enrolled_certificate(payload: bytes) -> bytes:
    """This ROM's policy is exactly one X.509 certificate per key database."""
    if len(payload) < 44 or payload[:16] != CERT_X509:
        raise ValueError("expected one X.509 signature list")
    list_size, header_size, sig_size = struct.unpack_from("<III", payload, 16)
    if list_size != len(payload) or header_size != 0 or sig_size <= 16 or sig_size != list_size - 28:
        raise ValueError("expected exactly one X.509 entry and no signature header")
    certificate = payload[44:]
    _, trailing = der_element(certificate, 0x30)
    if trailing:
        raise ValueError("trailing bytes in X.509 certificate")
    return certificate


def pem_to_der(path: str) -> bytes:
    return subprocess.run(
        ["openssl", "x509", "-in", path, "-outform", "DER"],
        check=True, capture_output=True,
    ).stdout


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    keys = sys.argv[1]
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        for name, guid, signer in CHAIN:
            with open(os.path.join(keys, f"{name}.auth"), "rb") as source:
                blob = source.read()
            signature, payload = parse_auth(blob)
            # Bind the next verification key to the certificate actually
            # enrolled by this signed payload, not an unrelated sidecar PEM.
            if enrolled_certificate(payload) != pem_to_der(os.path.join(keys, f"{name}.pem")):
                raise ValueError(f"{name}.auth does not enroll {name}.pem")
            signed = name.encode("utf-16-le") + guid + struct.pack("<I", ATTRS) + blob[:16] + payload
            data_path = os.path.join(tmp, f"{name}.data")
            p7_path = os.path.join(tmp, f"{name}.p7")
            open(data_path, "wb").write(signed)
            open(p7_path, "wb").write(signature)
            signer_path = os.path.join(tmp, f"{signer}.pem")
            # Canonicalize one certificate so extra PEM blocks cannot add a signer.
            encoded = base64.encodebytes(pem_to_der(os.path.join(keys, f"{signer}.pem")))
            with open(signer_path, "wb") as signer_file:
                signer_file.write(b"-----BEGIN CERTIFICATE-----\n" + encoded
                                  + b"-----END CERTIFICATE-----\n")
            result = subprocess.run(
                ["openssl", "cms", "-verify", "-binary", "-inform", "DER",
                 "-in", p7_path, "-content", data_path,
                 # Verify the signature with the exact enrolled signer.
                 # -nointern excludes embedded substitutes; -noverify skips
                 # PKIX path building, NOT the cryptographic signature check.
                 # Secure Boot keys are explicit anchors, not TLS CAs.
                 "-nointern", "-certfile", signer_path,
                 "-noverify", "-no-CAfile", "-no-CApath", "-no-CAstore",
                 "-out", os.devnull],
                capture_output=True, text=True,
            )
            ok = result.returncode == 0
            failed |= not ok
            print(f"{name:<4} signed by {signer:<4} {'OK' if ok else 'FAILED'}")
            if not ok:
                print(result.stderr.strip(), file=sys.stderr)
            print(f"{name}.auth carries {name}.pem: OK")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError) as error:
        print(f"Certificate chain verification FAILED: {error}", file=sys.stderr)
        sys.exit(1)
