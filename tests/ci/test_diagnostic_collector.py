# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collect-sdk-bytes.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

def string(raw):
    return struct.pack("<Q", len(raw)) + raw + b"\0" * (-len(raw) % 8)

def nar(content=b"payload"):
    return b"".join(map(string, [b"nix-archive-1", b"(", b"type", b"regular", b"contents", content, b")"]))

def manifest():
    return {"entries": [{"path": ".", "type": "file", "executable": False, "size": 7, "sha256": hashlib.sha256(b"payload").hexdigest()}]}

class CollectorTests(unittest.TestCase):
    def test_nar_exact_bytes_and_no_extraction(self):
        raw = nar()
        self.assertEqual(c.validate_nar(raw, manifest()), hashlib.sha256(raw).hexdigest())

    def test_nar_rejects_truncation_padding_payload_and_trailing_bytes(self):
        for raw in [nar()[:-1], nar() + b"extra", nar(b"changed"), nar().replace(b"payload\0", b"payloadX")]:
            with self.subTest(raw=raw[-20:]), self.assertRaises(ValueError):
                c.validate_nar(raw, manifest())

    def test_nar_rejects_parent_entry_and_missing_manifest_nodes(self):
        raw = b"".join(map(string, [b"nix-archive-1", b"(", b"type", b"directory", b"entry", b"(", b"name", b"..", b"node", b")"]))
        with self.assertRaises(ValueError):
            c.validate_nar(raw, {"entries": [{"path": ".", "type": "directory"}]})
        with self.assertRaises(ValueError):
            c.validate_nar(nar(), {"entries": manifest()["entries"] + [{"path": "missing", "type": "file"}]})

    def test_unknown_root_rejected(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            c.inventory(Path(directory), lambda: 1)

    def fixture(self, root):
        original = c.ROOTS
        c.ROOTS = {"fixture": str(root)}
        self.addCleanup(setattr, c, "ROOTS", original)

    def test_leaf_links_recorded_without_following(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            (root / "payload").write_bytes(b"data")
            (root / "alias").symlink_to("payload")
            result = c.inventory(root, lambda: 1)
            self.assertEqual(result["totalFileBytes"], 4)
            self.assertEqual(next(row for row in result["entries"] if row["path"] == "alias")["target"], "payload")

    def test_escaping_links_and_special_files_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            (root / "escape").symlink_to("../outside")
            with self.assertRaises(ValueError): c.inventory(root, lambda: 1)
            (root / "escape").unlink()
            os.mkfifo(root / "fifo")
            with self.assertRaises(ValueError): c.inventory(root, lambda: 1)

    def test_symlink_root_and_file_limit_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory); root = parent / "root"; root.mkdir(); link = parent / "link"; link.symlink_to(root)
            self.fixture(link)
            with self.assertRaises(ValueError): c.inventory(link, lambda: 1)
            c.ROOTS = {"fixture": str(root)}
            with (root / "large").open("wb") as file: file.truncate(c.FILE_LIMIT + 1)
            with self.assertRaises(ValueError): c.inventory(root, lambda: 1)
