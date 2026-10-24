"""Native metadata preflight and private file-URL pasteboard regressions; no AX."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

from test_receiver import generated_png
from test_original_images import original_samples, supported_original_samples, webp_variants

ROOT = Path(__file__).resolve().parent.parent


def run_native_preflight(arguments, **kwargs):
    """Every image/batch test is isolated even if its expected refusal regresses."""
    arguments = list(arguments)
    if len(arguments) < 2 or arguments[1] not in ("--image", "--batch"):
        raise AssertionError("Preflight wrapper requires an image or batch command")
    prefix = "com.example.CodexScreenshotReceiver.Test."
    if "--fixture-pasteboard" in arguments:
        index = arguments.index("--fixture-pasteboard")
        if arguments.count("--fixture-pasteboard") != 1 or index + 1 >= len(arguments) or not arguments[index + 1].startswith(prefix):
            raise AssertionError("Native tests require exactly one private fixture pasteboard")
    else:
        arguments.extend(["--fixture-pasteboard", prefix + str(uuid.uuid4())])
    return subprocess.run(arguments, **kwargs)


class NativeBatchPreflightTests(unittest.TestCase):
    def run_manifest(self, manifest, expected):
        with tempfile.TemporaryDirectory(prefix="codex-drop-invalid-batch-") as directory:
            path = Path(directory)
            (path / "batch.json").write_text(json.dumps(manifest))
            process = run_native_preflight([os.environ.get("CODEX_DROP_TEST_RECEIVER", str(ROOT / "MacAttachmentReceiver")), "--batch", str(path / "batch.json"),
                                      "--result", str(path / "result.json")], capture_output=True, timeout=5)
            self.assertEqual(process.returncode, 0)
            result = json.loads((path / "result.json").read_text())
            self.assertEqual(result["status"], "blocked")
            self.assertFalse(result["pasteAttempted"])
            self.assertFalse(result.get("clipboardRead", False))
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

    def test_single_expected_sha256_mismatch_is_refused_before_ui(self):
        with tempfile.TemporaryDirectory(prefix="codex-drop-single-sha-") as directory:
            result_path = Path(directory)/'result.json'
            helper = os.environ.get('CODEX_DROP_TEST_RECEIVER', str(ROOT/'MacAttachmentReceiver'))
            prefix = [helper, '--image', str(ROOT/'test-image.png'), '--result', str(result_path)]
            # Wrong hashes and optional test pairs fail before any AX/private board access.
            cases = [['--expected-sha256', digest] for digest in ('0'*64, 'A'*64, 'short')]
            cases += [['--expected-sha256', '0'*64, '--test-stage-hold', '0', '--test-after-paste-hold', '0',
                       '--fixture-pasteboard', 'com.example.CodexScreenshotReceiver.Test.not-accessed']]
            for options in cases:
                with self.subTest(options=options):
                    result_path.unlink(missing_ok=True)
                    process = run_native_preflight(prefix + options, capture_output=True, timeout=5)
                    self.assertEqual(process.returncode, 0)
                    self.assertTrue(result_path.exists(), process.stdout.decode(errors='replace'))
                    result = json.loads(result_path.read_text())
                    self.assertEqual(result['status'], 'blocked')
                    self.assertEqual(result['reason'], 'batch_image_checksum_changed')
                    self.assertFalse(result['pasteAttempted'])
                    self.assertEqual(result['clipboardRestoration'], 'not_staged')
            for invalid in ([helper, '--batch', '/unused.json', '--result', str(result_path), '--expected-sha256', '0'*64],
                            prefix + ['--expected-sha256', '0'*64, '--expected-sha256', '0'*64]):
                result_path.unlink(missing_ok=True)
                process = run_native_preflight(invalid, capture_output=True, timeout=5)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn(b'invalid_arguments', process.stdout + process.stderr)
                self.assertFalse(result_path.exists())

    def test_all_images_validated_before_any_ui_access(self):
        png = ROOT / "test-image.png"
        with tempfile.TemporaryDirectory(prefix="codex-drop-invalid-png-") as directory:
            invalid = Path(directory) / "invalid.png"
            invalid.write_bytes(b"not a PNG" * 8)
            self.run_manifest({"images": [
                {"path": str(png), "sha256": hashlib.sha256(png.read_bytes()).hexdigest()},
                {"path": str(invalid), "sha256": hashlib.sha256(invalid.read_bytes()).hexdigest()},
            ]}, "invalid_image")


    def image_then_invalid(self, data, expected="batch_image_checksum_changed"):
        # The second file stops preflight before AX, Codex, or any pasteboard access.
        with tempfile.TemporaryDirectory(prefix="codex-drop-limit-png-") as directory:
            path = Path(directory)
            image = path / "image.png"; image.write_bytes(data)
            invalid = path / "invalid.png"; invalid.write_bytes(generated_png())
            self.run_manifest({"images": [
                {"path": str(image), "sha256": hashlib.sha256(image.read_bytes()).hexdigest()},
                {"path": str(invalid), "sha256": "0" * 64}]}, expected)

    def test_native_accepts_over_20_mib_and_exact_50_mib(self):
        for size in (20 * 1024 * 1024 + 1, 50 * 1024 * 1024):
            with self.subTest(size=size): self.image_then_invalid(generated_png(padded_size=size))

    def test_native_refuses_over_50_mib_before_decode(self):
        self.image_then_invalid(generated_png(padded_size=50 * 1024 * 1024 + 1), "image_size_limit")

    def test_native_has_no_pixel_or_axis_quota(self):
        for width, height in ((32769, 1), (1, 32769)):
            with self.subTest(width=width, height=height): self.image_then_invalid(generated_png(width, height))

    def test_original_containers_pass_metadata_preflight(self):
        for suffix, data in supported_original_samples().items():
            with self.subTest(suffix=suffix): self.image_then_invalid(data)

    def test_heic_heif_are_refused_before_clipboard_or_snapshot_staging(self):
        with tempfile.TemporaryDirectory(prefix="codex-native-refused-heif-") as directory:
            for suffix in ("heic", "heif"):
                data = original_samples()[suffix]
                with self.subTest(suffix=suffix):
                    path = Path(directory) / ("original." + suffix); path.write_bytes(data)
                    before = set(Path(directory).iterdir())
                    # A second invalid digest guarantees old accepting binaries stop
                    # in preflight too: this regression can never reach AX/Paste.
                    self.run_manifest({"images": [
                        {"path": str(path), "sha256": hashlib.sha256(data).hexdigest()},
                        {"path": str(ROOT / "test-image.png"), "sha256": "0" * 64},
                    ]}, "unsupported_image_type")
                    self.assertEqual(set(Path(directory).iterdir()), before, "unsupported image created a handoff snapshot")
                    self.assertEqual(path.read_bytes(),data)

    def test_metadata_validation_does_not_decode_pixel_stream(self):
        import struct, zlib
        png = generated_png()
        offset = png.index(b"IDAT")
        size, = struct.unpack_from(">I", png, offset - 4)
        payload = b"x" * size
        broken = png[:offset + 4] + payload + struct.pack(">I", zlib.crc32(b"IDAT" + payload) & 0xFFFFFFFF) + png[offset + 8 + size:]
        # Header metadata is valid. Original delivery deliberately does not decode
        # or repair compressed pixels; the consumer handles the original file.
        self.image_then_invalid(broken)

    def test_symlink_source_is_refused_without_ui_access(self):
        with tempfile.TemporaryDirectory(prefix="codex-original-link-") as directory:
            link = Path(directory) / "image.png"; link.symlink_to(ROOT / "test-image.png")
            self.run_manifest({"images": [{"path": str(link), "sha256": hashlib.sha256(link.read_bytes()).hexdigest()}]}, "image_file_unavailable")

    def test_nonregular_source_is_refused_without_blocking(self):
        with tempfile.TemporaryDirectory(prefix="codex-original-special-") as directory:
            path = Path(directory) / "pipe.png"; os.mkfifo(path)
            self.run_manifest({"images": [{"path": str(path), "sha256": "0" * 64}]}, "unsafe_image_file")

    def test_unsupported_container_is_refused(self):
        import struct
        bmp = struct.pack("<2sIHHI",b"BM",58,0,0,54) + struct.pack("<IiiHHIIiiII",40,1,1,1,24,0,4,0,0,0,0) + bytes(4)
        self.image_then_invalid(bmp,"unsupported_image_type")

    def test_original_batch_total_remains_bounded(self):
        with tempfile.TemporaryDirectory(prefix="codex-original-total-") as directory:
            image = Path(directory) / "large.png"; image.write_bytes(generated_png(padded_size=50 * 1024 * 1024))
            entry = {"path": str(image), "sha256": hashlib.sha256(image.read_bytes()).hexdigest()}
            self.run_manifest({"images": [entry] * 3},"batch_size_limit")

    def test_original_files_round_trip_across_process_via_file_url_only(self):
        executable = os.environ.get("CODEX_DROP_TEST_RECEIVER", str(ROOT / "MacAttachmentReceiver"))
        with tempfile.TemporaryDirectory(prefix="codex originals 🧗 ") as directory:
            for suffix, data in supported_original_samples().items():
                with self.subTest(suffix=suffix):
                    path = Path(directory) / ("original image." + suffix); path.write_bytes(data)
                    process = subprocess.run([executable,"--self-test-original-file",str(path)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(process.returncode,0,process.stderr)
                    self.assertIn("exact SHA256, file-url only, retained after restore",process.stdout)

    def test_lossless_and_animated_webp_round_trip_without_flattening(self):
        executable = os.environ.get("CODEX_DROP_TEST_RECEIVER", str(ROOT/"MacAttachmentReceiver"))
        with tempfile.TemporaryDirectory(prefix="codex original webp variants ") as directory:
            for label, data in webp_variants().items():
                with self.subTest(variant=label):
                    path = Path(directory)/(label+'.webp'); path.write_bytes(data)
                    process = subprocess.run([executable, '--self-test-original-file', str(path)],
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(process.returncode, 0, process.stderr)
                    self.assertIn('webp, exact SHA256, file-url only, retained after restore', process.stdout)
                    self.assertEqual(path.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
