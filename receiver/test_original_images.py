"""Original-file transport tests: synthetic fixtures, disposable queue, no decoding."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

from mac_receiver import Conflict, InvalidImage, JobQueue
import mac_receiver
from test_receiver import generated_png


def original_samples():
    """Tiny synthetic encoded images; these bytes are never rewritten in delivery."""
    jpeg = base64.b64decode(JPEG_FIXTURE)
    # A JPEG comment verifies opaque metadata survives without parsing it.
    comment = b"Codex Drop synthetic metadata sentinel"
    jpeg = jpeg[:2] + b"\xff\xfe" + struct.pack(">H", len(comment)+2) + comment + jpeg[2:]
    heic = base64.b64decode(HEIC_FIXTURE)
    ftyp_size = int.from_bytes(heic[:4], "big")
    heif = heic[:8] + heic[8:ftyp_size].replace(b"heic", b"mif1") + heic[ftyp_size:]
    return {
        "png": generated_png(), "jpg": jpeg,
        "gif": base64.b64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="),
        "webp": base64.b64decode("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"),
        "heic": heic, "heif": heif,
    }


def supported_original_samples():
    """Only the four formats accepted as Codex image inputs."""
    return {suffix: data for suffix, data in original_samples().items() if suffix in ('png', 'jpg', 'gif', 'webp')}


HEIC_REFUSAL_MESSAGE = ('Codex does not accept HEIC/HEIF as image inputs. Share a JPEG, PNG, GIF or WebP instead. '
                        'In Photos, use Automatic or Most Compatible.')


def webp_variants():
    """Synthetic 16×16 lossless red and red/blue two-frame WebP fixtures.

    Encoded once with cwebp-lossless/img2webp; tests need no encoder installed.
    """
    return {
        "lossless": base64.b64decode('UklGRhwAAABXRUJQVlA4TA8AAAAvD8ADAAcQ/Y/+ByKi/wEA'),
        "animated": base64.b64decode('UklGRoQAAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAA8AAA8AAHgAAAJWUDhMDwAAAC8PwAMABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAA8AAA8AAHgAAABWUDhMDwAAAC8PwAMABxDR//4HIqL/AQA='),
    }


JPEG_FIXTURE = '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAEAAQAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/fyiiigD/9k='
HEIC_FIXTURE = 'AAAAKGZ0eXBoZWljAAAAAG1pZjFNaUhFTWlQcm1pYWZNaUhCaGVpYwAAAoFtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAA5waXRtAAAAAAABAAAAOGlpbmYAAAAAAAIAAAAVaW5mZQIAAAAAAQAAaHZjMQAAAAAVaW5mZQIAAAEAAgAAaHZjMQAAAAAaaXJlZgAAAAAAAAAOYXV4bAACAAEAAQAAAaRpcHJwAAABe2lwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAEAAAABAAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAADnBpeGkAAAAAAQgAAAA3YXV4QwAAAAB1cm46bXBlZzpoZXZjOjIwMTU6YXV4aWQ6MQAAAAAMAAAACE4BpQQAAf5AAAAAcWh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAI0IBAQNwAAADALAAAAMAAAMAHqAUIEHAkwziHuRZVNwICBgCogABAAlEAcBhcshEU2QAAABxaHZjQwEECAAAAL/IAAAAAB7wAPz8+PgAAAsDoAABABdAAQwB//8ECAAAAwC/yAAAAwAAHhcCQKEAAQAjQgEBBAgAAAMAv8gAAAMAAB7AUIEHASMGOIF7kWVTcCAgIAiiAAEACUQBwGHSyERTZAAAACFpcG1hAAAAAAAAAAIAAQaBAgMFiIQAAgUDBoeJhAAAACxpbG9jAAAAAEQAAAIAAQAAAAEAAAK5AAAAKwACAAAAAQAAAuQAAAAlAAAAAW1kYXQAAAAAAAAAYAAAACcoAa+ixkft2//+JRWypaJ+oHto45lf0CI62Cx9i6Hm1EaQ+PQI/mwAAAAhKAGvROiMBv//COE3mZ+uT1RI5UAup5xfU6yC2EKrsT3A'


class OriginalImageValidationTests(unittest.TestCase):
    def test_actual_file_headers_choose_original_suffix(self):
        for suffix, data in supported_original_samples().items():
            with self.subTest(suffix=suffix): self.assertEqual(mac_receiver.validate_image(data), suffix)

    def test_recognized_malformed_and_unsupported_files_are_distinct(self):
        for data in (b"\x89PNG\r\n\x1a\n" + bytes(40), b"\xff\xd8\xff\xe0\x00\x10bad", b"GIF89a" + bytes(10),
                     b"RIFF\xff\xff\xff\xffWEBPVP8 " + bytes(20), b"\x00\x00\x10\x00ftypheic" + bytes(30)):
            with self.subTest(signature=data[:8]):
                with self.assertRaises(InvalidImage): mac_receiver.validate_image(data)
        for data in (b"%PDF-1.7" + bytes(40), b"not an image" * 4):
            with self.assertRaises(InvalidImage) as error: mac_receiver.validate_image(data)
            self.assertEqual(error.exception.reason, "unsupported_image_format")

    def test_heif_item_data_box_and_unsupported_avif_brand(self):
        def box(kind, payload): return struct.pack('>I', len(payload)+8) + kind + payload
        ftyp = box(b'ftyp', b'mif1' + bytes(4) + b'mif1')
        sample = ftyp + box(b'meta', bytes(4) + box(b'idat', b'original-coded-item'))
        with self.assertRaises(InvalidImage) as heif_error: mac_receiver.validate_image(sample)
        self.assertEqual(heif_error.exception.reason, 'unsupported_image_format')
        self.assertEqual(str(heif_error.exception), HEIC_REFUSAL_MESSAGE)
        with self.assertRaises(InvalidImage) as error:
            mac_receiver.validate_image(sample.replace(b'mif1', b'avif'))
        self.assertEqual(error.exception.reason, 'unsupported_image_format')

    def test_heic_and_heif_are_recognized_and_refused_with_recovery(self):
        for suffix in ('heic', 'heif'):
            with self.subTest(suffix=suffix):
                with self.assertRaises(InvalidImage) as error: mac_receiver.validate_image(original_samples()[suffix])
                self.assertEqual(error.exception.reason, 'unsupported_image_format')
                self.assertEqual(str(error.exception), HEIC_REFUSAL_MESSAGE)

    def test_transfer_does_not_impose_a_decoded_pixel_limit(self):
        for width, height in ((32769, 1), (1, 32769), (8000, 8001)):
            with self.subTest(width=width, height=height):
                self.assertEqual(mac_receiver.validate_image(generated_png(width, height)), "png")


class OriginalImageQueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.queue = JobQueue(Path(self.tmp.name))

    def assert_saved(self, path, data, digest):
        path = Path(path)
        self.assertEqual(path.read_bytes(), data)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_lossless_and_animated_webp_original_bytes_and_hashes_are_preserved(self):
        variants = webp_variants()
        self.assertIn(b'VP8L', variants['lossless'])
        self.assertIn(b'ANIM', variants['animated'])
        self.assertEqual(variants['animated'].count(b'ANMF'), 2)
        for label, data in variants.items():
            with self.subTest(variant=label):
                self.assertEqual(mac_receiver.validate_image(data), 'webp')
                key = str(uuid.uuid4()); receipt = self.queue.enqueue(key, data)
                image = self.queue.directory/'images'/f'{key}.webp'
                self.assert_saved(image, data, receipt['sha256'])

    def test_single_images_persist_exact_bytes_metadata_and_correct_suffix(self):
        for suffix, data in supported_original_samples().items():
            with self.subTest(suffix=suffix):
                key = str(uuid.uuid4()); receipt = self.queue.enqueue(key, data)
                with self.queue.connect() as db: job = dict(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())
                self.assertEqual(Path(job['image']).suffix, '.'+suffix)
                self.assert_saved(job['image'], data, receipt['sha256'])
        self.assertEqual(self.queue.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.queue.directory/'images').stat().st_mode & 0o777, 0o700)

    def test_mixed_original_batch_preserves_bytes_hashes_and_idempotency(self):
        samples = list(supported_original_samples().items()); key = str(uuid.uuid4())
        self.queue.create_batch(key, len(samples))
        for index, (_, data) in enumerate(samples): self.queue.upload_batch_image(key, index, data)
        self.queue.commit_batch(key)
        job = self.queue.claim()
        for item, (suffix, data) in zip(job['images'], samples):
            self.assertEqual(Path(item['path']).suffix, '.'+suffix)
            self.assert_saved(item['path'], data, item['sha256'])
        self.assertEqual(self.queue.commit_batch(key)['state'], 'running')
        with self.assertRaises(Conflict): self.queue.upload_batch_image(key, 0, samples[1][1])

    def test_heic_heif_rejection_persists_nothing_and_fresh_jpeg_still_queues(self):
        for suffix in ('heic', 'heif'):
            data = original_samples()[suffix]
            with self.assertRaises(InvalidImage) as single_error: self.queue.enqueue(str(uuid.uuid4()), data)
            self.assertEqual(str(single_error.exception), HEIC_REFUSAL_MESSAGE)
            key = str(uuid.uuid4()); self.queue.create_batch(key, 1)
            with self.assertRaises(InvalidImage) as batch_error: self.queue.upload_batch_image(key, 0, data)
            self.assertEqual(str(batch_error.exception), HEIC_REFUSAL_MESSAGE)
            self.assertEqual(self.queue.get(key)['state'], 'uploading')
            self.assertIsNone(self.queue.claim())
        self.assertEqual(list((self.queue.directory/'images').iterdir()), [])
        fresh = self.queue.enqueue(str(uuid.uuid4()), original_samples()['jpg'])
        self.assertEqual(self.queue.claim()['id'], fresh['id'])

    def test_legacy_staged_heic_and_heif_cannot_be_committed_or_delivered(self):
        for suffix in ('heic', 'heif'):
            with self.subTest(suffix=suffix):
                data = original_samples()[suffix]; key = str(uuid.uuid4())
                self.queue.create_batch(key, 1)
                path = self.queue.directory/'images'/f'{key}-0.{suffix}'
                path.write_bytes(data); path.chmod(0o600)
                with self.queue.connect() as db:
                    db.execute('INSERT INTO batch_images VALUES (?,?,?,?,?)', (key, 0, str(path), hashlib.sha256(data).hexdigest(), len(data)))
                with self.assertRaises(InvalidImage) as error: self.queue.commit_batch(key)
                self.assertEqual(error.exception.reason, 'unsupported_image_format')
                self.assertEqual(str(error.exception), HEIC_REFUSAL_MESSAGE)
                self.assertEqual(self.queue.get(key)['state'], 'uploading')
                self.assertIsNone(self.queue.claim())
                legacy_job = {'id': key, 'images': [{'path': str(path), 'sha256': hashlib.sha256(data).hexdigest()}]}
                with patch('mac_receiver.subprocess.Popen') as launch:
                    result = mac_receiver.native_delivery(legacy_job)
                    launch.assert_not_called()
                self.assertEqual(result['status'], 'blocked')
                self.assertEqual(result['reason'], 'unsupported_image_format')
                self.assertEqual(result['diagnostics']['recovery'], HEIC_REFUSAL_MESSAGE)
                self.assertFalse(result['pasteAttempted'])

    def test_rejection_does_not_persist_unsupported_or_malformed_files(self):
        for data in (b"%PDF-1.7" + bytes(40), b"\xff\xd8\xff\xe0\x00\x10bad"):
            with self.assertRaises(InvalidImage): self.queue.enqueue(str(uuid.uuid4()), data)
        self.assertEqual(self.queue.list(), [])
        self.assertEqual(list((self.queue.directory/'images').iterdir()), [])
        key = str(uuid.uuid4()); self.queue.create_batch(key, 1)
        with self.assertRaises(InvalidImage): self.queue.upload_batch_image(key, 0, b"unsupported" * 10)
        self.assertEqual(list((self.queue.directory/'images').iterdir()), [])
        self.assertEqual(self.queue.get(key)['state'], 'uploading')

    def test_actual_100_mib_batch_limit_is_independent_of_50_mib_per_file(self):
        key = str(uuid.uuid4()); self.queue.create_batch(key, 3)
        data = generated_png(padded_size=50 * 1024 * 1024)
        for index in (0, 1): self.queue.upload_batch_image(key, index, data)
        with self.assertRaises(Conflict): self.queue.upload_batch_image(key, 2, original_samples()['jpg'])
        self.assertEqual(len(list((self.queue.directory/'images').iterdir())), 2)

    def test_ten_images_remain_supported_and_eleven_refused(self):
        key = str(uuid.uuid4()); self.queue.create_batch(key, 10)
        for index in range(10): self.queue.upload_batch_image(key, index, original_samples()['jpg'])
        self.assertEqual(self.queue.commit_batch(key)['state'], 'queued')
        with self.assertRaises(ValueError): self.queue.create_batch(str(uuid.uuid4()), 11)

    def test_original_format_files_and_stable_snapshots_follow_existing_retention(self):
        now = time.time(); images = self.queue.directory/'images'
        paths = []
        for suffix, data in original_samples().items():
            key = str(uuid.uuid4()); path = images/f'{key}.{suffix}'
            if suffix in ('heic', 'heif'):
                # Legacy orphan files still expire after the supported-format policy changes.
                path.write_bytes(data); path.chmod(0o600); os.utime(path, (now-31*86400,)*2)
            else:
                self.queue.enqueue(key, data)
                with self.queue.connect() as db: db.execute("UPDATE jobs SET created=?,state='verified' WHERE id=?", (now-31*86400, key))
            paths.append(path)
            snapshot = images/f'{uuid.uuid4()}.{suffix}'; snapshot.write_bytes(data)
            os.utime(snapshot, (now-31*86400,)*2); paths.append(snapshot)
        jpeg_snapshot = images/f'{uuid.uuid4()}.jpeg'; jpeg_snapshot.write_bytes(original_samples()['jpg'])
        os.utime(jpeg_snapshot, (now-31*86400,)*2); paths.append(jpeg_snapshot)
        recent_snapshot = images/f'{uuid.uuid4()}.jpg'; recent_snapshot.write_bytes(original_samples()['jpg'])
        outside = self.queue.directory/'protected.jpg'; outside.write_bytes(b'untouched')
        link = images/f'{uuid.uuid4()}.jpg'; link.symlink_to(outside)
        self.queue.cleanup_expired(now=now)
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertTrue(link.is_symlink()); self.assertEqual(outside.read_bytes(), b'untouched')
        self.assertTrue(recent_snapshot.exists())

    def test_single_native_delivery_keeps_receipt_hash_when_source_changes_at_spawn(self):
        original, changed = original_samples()['jpg'], original_samples()['gif']
        key = str(uuid.uuid4()); self.queue.enqueue(key, original)
        job = self.queue.claim(); calls = []
        class Process:
            def wait(inner, timeout): return 0
        def mutate_at_spawn(arguments, **kwargs):
            calls.append(arguments)
            expected = arguments[arguments.index('--expected-sha256')+1]
            self.assertEqual(expected, job['sha256'])
            Path(job['image']).write_bytes(changed)
            # The child compares the bytes it reads with this receipt hash.
            self.assertNotEqual(hashlib.sha256(Path(job['image']).read_bytes()).hexdigest(), expected)
            result = {'status': 'blocked', 'reason': 'batch_image_checksum_changed', 'pasteAttempted': False}
            Path(arguments[arguments.index('--result')+1]).write_text(json.dumps(result))
            return Process()
        with patch('mac_receiver.subprocess.Popen', side_effect=mutate_at_spawn):
            result = mac_receiver.native_delivery(job)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['status'], 'blocked')
        self.assertFalse(result['pasteAttempted'])

    def test_mixed_batch_detects_staged_bytes_changed_before_commit(self):
        key = str(uuid.uuid4()); self.queue.create_batch(key, 1)
        self.queue.upload_batch_image(key, 0, original_samples()['jpg'])
        (self.queue.directory/'images'/f'{key}-0.jpg').write_bytes(original_samples()['gif'])
        with self.assertRaises(Conflict): self.queue.commit_batch(key)
        self.assertIsNone(self.queue.claim())


if __name__ == '__main__': unittest.main()
