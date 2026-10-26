"""Original video envelopes and storage, without decoding frames or audio."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
import uuid

from mac_receiver import InvalidImage, JobQueue, validate_image
from test_receiver import generated_png


def box(kind, payload=b"", extended=False):
    if extended:
        return struct.pack(">I4sQ", 1, kind, len(payload) + 16) + payload
    return struct.pack(">I4s", len(payload) + 8, kind) + payload


def video_sample(brand=b"isom", handler=b"vide", codec=b"hvc1", width=16, height=24,
                 media=b"opaque synthetic encoded media", extended=False, data_reference=1):
    visual = bytearray(78)
    visual[6:8] = struct.pack(">H", data_reference)
    visual[24:28] = struct.pack(">HH", width, height)
    stsd = box(b"stsd", b"\0\0\0\0" + struct.pack(">I", 1) + box(codec, visual))
    hdlr = box(b"hdlr", bytes(8) + handler + bytes(12))
    mdia = box(b"mdia", hdlr + box(b"minf", box(b"stbl", stsd)))
    return (box(b"ftyp", brand + bytes(4) + brand, extended=extended)
            + box(b"moov", box(b"trak", mdia)) + box(b"mdat", media))


class OriginalVideoTests(unittest.TestCase):
    def test_mp4_and_quicktime_containers(self):
        self.assertEqual(validate_image(video_sample()), "mp4")
        self.assertEqual(validate_image(video_sample(brand=b"qt  ", codec=b"avc1")), "mov")
        self.assertEqual(validate_image(video_sample(extended=True)), "mp4")
        self.assertEqual(validate_image(box(b"free") + video_sample()), "mp4")

    def test_audio_only_unknown_or_encrypted_samples_are_refused(self):
        for data in [video_sample(handler=b"soun", codec=b"mp4a"),
                     video_sample(codec=b"encv"), video_sample(codec=b"text"),
                     video_sample(brand=b"avif"), video_sample(brand=b"heic"),
                     video_sample(width=0), video_sample(height=0), video_sample(media=b""),
                     video_sample(data_reference=0)]:
            with self.subTest(header=data[:32]), self.assertRaises(InvalidImage):
                validate_image(data)

    def test_truncated_overflowing_and_ambiguous_boxes_are_refused(self):
        valid = video_sample()
        bad_stsd = valid.replace(b"stsd\0\0\0\0\0\0\0\1", b"stsd\0\0\0\0\0\0\0\2")
        for data in [valid[:-1], valid + b"trailing", bad_stsd,
                     struct.pack(">I4s", 7, b"ftyp") + valid[8:],
                     struct.pack(">I4sQ", 1, b"ftyp", 2**64-1),
                     valid + box(b"ftyp", b"qt  " + bytes(4))]:
            with self.subTest(length=len(data)), self.assertRaises(InvalidImage):
                validate_image(data)

    def test_declared_empty_final_box_can_consume_remaining_media(self):
        data = video_sample()
        position = data.index(b"mdat") - 4
        self.assertEqual(validate_image(data[:position] + bytes(4) + data[position+4:]), "mp4")

    def test_video_requires_a_real_visual_sample_description(self):
        data = video_sample()
        start = data.index(b"stsd") - 4
        short = data[:start] + box(b"stsd", bytes(4) + struct.pack(">I", 1) + box(b"hvc1"))
        with self.assertRaises(InvalidImage):
            validate_image(short)
        no_track = box(b"ftyp", b"isom" + bytes(4)) + box(b"moov") + box(b"mdat", b"media")
        with self.assertRaises(InvalidImage):
            validate_image(no_track)

    def test_single_and_mixed_batch_preserve_bytes_and_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            queue = JobQueue(Path(directory))
            data = video_sample()
            received = queue.enqueue(str(uuid.uuid4()), data)
            with queue.connect() as db:
                image = db.execute("SELECT image FROM jobs WHERE id=?", (received["id"],)).fetchone()[0]
            self.assertEqual(Path(image).read_bytes(), data)
            self.assertTrue(image.endswith(".mp4"))
            key = str(uuid.uuid4())
            queue.create_batch(key, 3)
            originals = [generated_png(), video_sample(brand=b"qt  "), data]
            for index, original in enumerate(originals):
                queue.upload_batch_image(key, index, original)
            queue.commit_batch(key)
            with queue.connect() as db:
                rows = db.execute("SELECT path,sha256 FROM batch_images WHERE batch_id=? ORDER BY image_index", (key,)).fetchall()
            self.assertEqual([Path(row["path"]).read_bytes() for row in rows], originals)
            self.assertEqual([row["sha256"] for row in rows], [hashlib.sha256(x).hexdigest() for x in originals])


if __name__ == "__main__":
    unittest.main()
