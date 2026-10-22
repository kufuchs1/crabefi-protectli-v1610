#!/usr/bin/env python3
"""Adversarial tests for the actual certificate-checking CLI (requires OpenSSL)."""

import importlib.util
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-auth-chain.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("auth_chain", SCRIPT)
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


def openssl(*args):
    return subprocess.run(["openssl", *map(str, args)], check=True, capture_output=True).stdout


class CertificateChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        for name in ("PK", "KEK", "db", "rogue"):
            openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                    "-subj", f"/CN={name}", "-days", "3650",
                    "-keyout", cls.root / f"{name}.key", "-out", cls.root / f"{name}.pem")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def sign(cls, name, guid, signer, certificate, *, attached=False):
        der = openssl("x509", "-in", certificate, "-outform", "DER")
        payload = AUTH.CERT_X509 + struct.pack("<III", 44 + len(der), 0, 16 + len(der)) + bytes(16) + der
        timestamp = struct.pack("<H6BIh2B", 2026, 10, 18, 0, 0, 0, 0, 0, 0, 0, 0)
        data = name.encode("utf-16-le") + guid + struct.pack("<I", AUTH.ATTRS) + timestamp + payload
        datafile = cls.root / "data"
        datafile.write_bytes(data)
        args = ["cms", "-sign", "-binary", "-md", "sha256", "-in", datafile,
                "-signer", cls.root / f"{signer}.pem", "-inkey", cls.root / f"{signer}.key",
                "-outform", "DER"]
        if attached:
            args.append("-nodetach")
        signature = openssl(*args)
        header = struct.pack("<IHH", 24 + len(signature), 0x200, 0xEF1)
        header += bytes.fromhex("9dd2af4adf68ee498aa9347d375665a7")
        return timestamp + header + signature + payload

    def setUp(self):
        self.case = tempfile.TemporaryDirectory()
        self.keys = Path(self.case.name)
        self.addCleanup(self.case.cleanup)
        for name, guid, signer in AUTH.CHAIN:
            shutil.copy(self.root / f"{name}.pem", self.keys)
            (self.keys / f"{name}.auth").write_bytes(
                self.sign(name, guid, signer, self.root / f"{name}.pem"))

    def check(self, success):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.keys)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def mutate(self, offset, data, name="db"):
        path = self.keys / f"{name}.auth"
        blob = bytearray(path.read_bytes())
        if offset < 0:
            offset += len(blob)
        blob[offset:offset + len(data)] = data
        path.write_bytes(blob)

    def test_valid_hierarchy(self):
        self.check(True)

    def test_fetched_hierarchy(self):
        fetched = SCRIPT.parent.parent / "src" / "secureblue-keys"
        if not (fetched / "SOURCE").is_file():
            self.skipTest("run './build.sh payload' to fetch secureblue's keys")
        self.keys = fetched
        self.check(True)

    def test_unenrolled_kek_cannot_authorize_db(self):
        shutil.copyfile(self.root / "rogue.pem", self.keys / "KEK.pem")
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.SECURITY_DB, "rogue", self.root / "db.pem"))
        self.check(False)

    def test_db_payload_must_match_db_pem(self):
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.SECURITY_DB, "KEK", self.root / "rogue.pem"))
        self.check(False)

    def test_wrong_signer(self):
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.SECURITY_DB, "rogue", self.root / "db.pem"))
        self.check(False)

    def test_attached_content_rejected(self):
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.SECURITY_DB, "KEK", self.root / "db.pem", attached=True))
        self.check(False)

    def test_extra_pem_block_cannot_add_a_signer(self):
        path = self.keys / "KEK.pem"
        path.write_bytes(path.read_bytes() + (self.root / "rogue.pem").read_bytes())
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.SECURITY_DB, "rogue", self.root / "db.pem"))
        self.check(False)

    def test_variable_name_is_authenticated(self):
        (self.keys / "db.auth").write_bytes(
            self.sign("KEK", AUTH.SECURITY_DB, "KEK", self.root / "db.pem"))
        self.check(False)

    def test_vendor_guid_is_authenticated(self):
        (self.keys / "db.auth").write_bytes(
            self.sign("db", AUTH.GLOBAL, "KEK", self.root / "db.pem"))
        self.check(False)

    def test_timestamp_is_authenticated(self):
        self.mutate(6, b"\x01")
        self.check(False)

    def test_payload_tampering(self):
        last = (self.keys / "db.auth").read_bytes()[-1]
        self.mutate(-1, bytes([last ^ 1]))
        self.check(False)

    def test_header_revision(self):
        self.mutate(20, b"\x00\x00")
        self.check(False)

    def test_header_type(self):
        self.mutate(22, b"\x00\x00")
        self.check(False)

    def test_header_guid(self):
        self.mutate(24, bytes(16))
        self.check(False)

    def test_truncation(self):
        (self.keys / "db.auth").write_bytes(b"\x00" * 20)
        self.check(False)


if __name__ == "__main__":
    unittest.main()
