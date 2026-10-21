"""Native invalid-batch preflight only: never reaches AX or any pasteboard."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class NativeBatchPreflightTests(unittest.TestCase):
    def run_manifest(self, manifest, expected):
        with tempfile.TemporaryDirectory(prefix="codex-drop-invalid-batch-") as directory:
            path = Path(directory)
            (path / "batch.json").write_text(json.dumps(manifest))
            process = subprocess.run([str(ROOT / "MacAttachmentReceiver"), "--batch", str(path / "batch.json"),
                                      "--result", str(path / "result.json")], capture_output=True, timeout=5)
            self.assertEqual(process.returncode, 0)
            result = json.loads((path / "result.json").read_text())
            self.assertEqual(result["status"], "blocked")
            self.assertFalse(result["pasteAttempted"])
            self.assertEqual(result["clipboardRestoration"], "not_staged")
            self.assertEqual(result["reason"], expected)

    def test_empty_and_excessive_batch(self):
        for images in ([], [{"path": "/missing.png", "sha256": "0" * 64}] * 11):
            with self.subTest(count=len(images)):
                self.run_manifest({"images": images}, "invalid_batch")

    def test_relative_path(self):
        self.run_manifest({"images": [{"path": "test-image.png", "sha256": "0" * 64}]}, "invalid_batch_manifest")

    def test_checksum_mismatch(self):
        self.run_manifest({"images": [{"path": str(ROOT / "test-image.png"), "sha256": "0" * 64}]}, "batch_image_checksum_changed")

    def test_all_images_validated_before_any_ui_access(self):
        png = ROOT / "test-image.png"
        with tempfile.TemporaryDirectory(prefix="codex-drop-invalid-png-") as directory:
            invalid = Path(directory) / "invalid.png"
            invalid.write_bytes(b"not a PNG" * 8)
            self.run_manifest({"images": [
                {"path": str(png), "sha256": hashlib.sha256(png.read_bytes()).hexdigest()},
                {"path": str(invalid), "sha256": hashlib.sha256(invalid.read_bytes()).hexdigest()},
            ]}, "invalid_png")


if __name__ == "__main__":
    unittest.main()
