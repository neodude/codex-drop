import importlib.util
import concurrent.futures
import http.client
import json
import pathlib
import struct
import tempfile
import threading
import time
import unittest
import uuid
import zlib

AVAILABLE = importlib.util.find_spec("mac_receiver") is not None
if AVAILABLE:
    from mac_receiver import JobQueue, Conflict, InvalidImage, DeliveryWorker, validate_png, make_server, token_for, process_lock


def generated_png(width=1, height=1, padded_size=None, interlaced=False, bit_depth=8):
    """Real RGBA PNG with bounded row compression and optional safe ancillary padding."""
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload +
                struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
    compressor = zlib.compressobj()
    passes = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
              (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)) if interlaced else ((0, 0, 1, 1),)
    parts = []
    for x, y, dx, dy in passes:
        columns, rows = max(0, (width-x+dx-1)//dx), max(0, (height-y+dy-1)//dy)
        if columns:
            row = bytes(1 + columns * 4 * (bit_depth//8))
            parts.extend(compressor.compress(row) for _ in range(rows))
    parts.append(compressor.flush())
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, bit_depth, 6, 0, 0, int(interlaced))) +
           chunk(b"IDAT", b"".join(parts)))
    ending = chunk(b"IEND", b"")
    if padded_size is not None:
        padding = padded_size - len(png) - len(ending) - 12
        if padding < 0:
            raise ValueError("PNG padding target too small")
        png += chunk(b"npAd", bytes(padding))
    return png + ending


class PNGImageLimitTests(unittest.TestCase):
    def test_png_byte_limit_accepts_over_20_mib_and_exactly_50_mib(self):
        for size in (20 * 1024 * 1024 + 1, 50 * 1024 * 1024):
            with self.subTest(size=size):
                self.assertEqual(validate_png(generated_png(padded_size=size)), (1, 1))

    def test_over_50_mib_reports_byte_limit(self):
        with self.assertRaisesRegex(InvalidImage, "50 MiB"):
            validate_png(generated_png(padded_size=50 * 1024 * 1024 + 1))

    def test_photo_pixel_and_axis_boundaries(self):
        for width, height in ((4032, 3024), (8064, 6048), (8000, 8000), (32768, 1), (1, 32768)):
            with self.subTest(width=width, height=height):
                self.assertEqual(validate_png(generated_png(width, height)), (width, height))

    def test_original_png_transfer_does_not_restrict_pixel_dimensions(self):
        for width, height in ((8000, 8001), (32769, 1), (1, 32769)):
            with self.subTest(width=width, height=height):
                self.assertEqual(validate_png(generated_png(width, height)), (width, height))

    def test_bad_checksum_and_truncated_png_remain_invalid(self):
        png = generated_png()
        damaged = bytearray(png); damaged[29] ^= 1
        for data in (bytes(damaged), png[:-5], png + b"trailing"):
            with self.subTest(length=len(data)):
                with self.assertRaises(InvalidImage): validate_png(data)


class AvailabilityTests(unittest.TestCase):
    def test_receiver_exists(self):
        self.assertTrue(AVAILABLE, "The durable receiver has not been implemented yet")


@unittest.skipUnless(AVAILABLE, "receiver not implemented yet")
class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.queue = JobQueue(pathlib.Path(self.tmp.name))
        self.png = (pathlib.Path(__file__).parent.parent / "test-image.png").read_bytes()

    def enqueue(self, key=None, data=None):
        return self.queue.enqueue(key or str(uuid.uuid4()), self.png if data is None else data)

    def test_duplicate_request_is_one_job_and_mismatch_is_rejected(self):
        key = str(uuid.uuid4())
        a, b = self.enqueue(key), self.enqueue(key)
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(len(self.queue.list()), 1)
        with self.assertRaises(Conflict):
            self.enqueue(key, self.png + b"different")

    def test_invalid_image_never_enters_queue(self):
        with self.assertRaises(InvalidImage):
            self.enqueue(data=b"not a PNG")
        self.assertEqual(self.queue.list(), [])

    def test_claim_is_exclusive_across_connections(self):
        job = self.enqueue()
        other = JobQueue(pathlib.Path(self.tmp.name))
        self.assertEqual(self.queue.claim()["id"], job["id"])
        self.assertIsNone(other.claim())

    def test_concurrent_duplicate_requests_have_one_durable_job(self):
        key = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            jobs = list(pool.map(lambda _: self.enqueue(key), range(16)))
        self.assertEqual({job["id"] for job in jobs}, {key})
        self.assertEqual(len(self.queue.list()), 1)

    def test_process_lock_prevents_second_worker(self):
        with process_lock(self.queue):
            with self.assertRaises(Conflict):
                with process_lock(self.queue):
                    self.fail("second lock acquired")

    def test_orphaned_image_from_uncommitted_enqueue_is_recoverable(self):
        key = str(uuid.uuid4())
        (self.queue.directory / "images" / (key + ".png")).write_bytes(b"orphan")
        self.assertEqual(self.enqueue(key)["state"], "queued")

    def test_uncertain_job_does_not_block_fresh_waiting_job_or_replay_itself(self):
        first, second = self.enqueue(), self.enqueue()
        self.queue.claim()
        self.queue.finish(first["id"], {"status": "uncertain", "pasteAttempted": True, "reason": "timeout"})
        self.assertEqual(self.queue.claim(max_age=3)["id"],second["id"])
        self.queue.finish(second["id"], {"status":"verified", "pasteAttempted":True})
        with self.assertRaises(Conflict): self.queue.retry(first["id"])
        self.assertIsNone(self.queue.claim())
        self.queue.resolve(first["id"], "attached")
        self.assertIsNone(self.queue.claim(), "resolving a terminal job must not replay it")

    def test_fresh_arrival_after_uncertain_delivery_runs_without_replaying_history(self):
        first = self.enqueue()
        self.queue.claim()
        self.queue.finish(first["id"], {"status": "uncertain", "pasteAttempted": True, "reason": "timeout"})
        first_before = self.queue.get(first["id"])
        later = self.enqueue()
        self.assertEqual(later["state"], "queued")
        self.assertIsNone(later["result"])
        self.assertEqual(self.enqueue(later["id"]), later)
        with self.assertRaises(Conflict): self.enqueue(later["id"], self.png+b"different")
        self.assertEqual(JobQueue(self.queue.directory).get(later["id"]), later)
        self.assertEqual(self.queue.claim()["id"], later["id"])
        self.assertEqual(self.queue.get(first["id"]), first_before)

    def test_fresh_arrival_runs_past_blocked_history_and_stale_waiting_jobs(self):
        first, waiting = self.enqueue(), self.enqueue()
        self.queue.claim()
        self.queue.finish(first["id"], {"status": "blocked", "pasteAttempted": False, "reason": "not_frontmost"})
        first_before = self.queue.get(first["id"])
        with self.queue.connect() as db:
            db.execute("UPDATE jobs SET updated=updated-10 WHERE id=?",(waiting["id"],))
        fresh = self.enqueue()
        self.assertEqual(fresh["state"], "queued")
        self.assertEqual(self.queue.claim(max_age=3)["id"], fresh["id"])
        self.queue.finish(fresh["id"], {"status": "verified", "pasteAttempted": True})
        self.assertIsNone(self.queue.claim())
        self.assertEqual(self.queue.get(first["id"]), first_before)
        self.assertEqual(self.queue.get(waiting["id"])["state"],"blocked")
        self.assertEqual(self.queue.get(waiting["id"])["result"]["reason"],"queued_destination_confirmation_required")

    def test_arrival_behind_running_delivery_can_stay_queued(self):
        first = self.enqueue()
        self.queue.claim()
        second = self.enqueue()
        self.assertEqual(second["state"], "queued")
        self.assertIsNone(second["result"])
        self.queue.finish(first["id"], {"status": "verified", "pasteAttempted": True})
        self.assertEqual(self.queue.claim()["id"], second["id"])

    def test_crashed_running_job_recovers_to_uncertain(self):
        job = self.enqueue()
        self.queue.claim()
        self.queue.recover()
        self.assertEqual(self.queue.get(job["id"])["state"], "uncertain")
        self.assertIsNone(self.queue.claim())

    def test_restart_does_not_deliver_old_queued_job_to_newly_focused_thread(self):
        job = self.enqueue()
        self.queue.recover()
        self.assertEqual(self.queue.get(job["id"])["state"], "blocked")
        self.assertIsNone(self.queue.claim())

    def test_stale_queued_job_needs_explicit_destination_confirmation(self):
        job = self.enqueue()
        self.assertIsNone(self.queue.claim(max_age=3, now=time.time() + 4))
        self.assertEqual(self.queue.get(job["id"])["state"], "blocked")

    def test_invalid_existing_tokens_are_refused(self):
        path = self.queue.directory / "http-token"
        for value in ["", "truncated", " " * 43, "!" * 43]:
            path.write_text(value)
            with self.assertRaises(ValueError):
                token_for(self.queue.directory)

    def test_concurrent_token_creation_returns_one_complete_token(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            tokens = list(pool.map(lambda _: token_for(self.queue.directory), range(16)))
        self.assertEqual(len(set(tokens)), 1)
        self.assertEqual(len(tokens[0]), 43)

    def test_only_unattempted_blocked_job_can_retry(self):
        job = self.enqueue()
        self.queue.claim()
        self.queue.finish(job["id"], {"status": "blocked", "pasteAttempted": False, "reason": "not_frontmost"})
        self.queue.retry(job["id"])
        self.assertEqual(self.queue.claim()["id"], job["id"])

    def test_worker_marks_process_failure_uncertain_and_never_retries(self):
        job = self.enqueue()
        calls = []
        def fail(claimed):
            calls.append(claimed["id"])
            raise TimeoutError()
        worker = DeliveryWorker(self.queue, fail)
        self.assertTrue(worker.once())
        self.assertFalse(worker.once())
        self.assertEqual(calls, [job["id"]])
        self.assertEqual(self.queue.get(job["id"])["state"], "uncertain")

    def test_verified_is_distinct_from_receipt_and_replayed_id_stays_verified(self):
        key = str(uuid.uuid4())
        job = self.enqueue(key)
        self.assertEqual(job["state"], "queued")
        worker = DeliveryWorker(self.queue, lambda _: {"status": "verified", "pasteAttempted": True, "reason": "attachment_observed"})
        worker.once()
        self.assertEqual(self.enqueue(key)["state"], "verified")
        self.assertFalse(worker.once())

    def test_corrupt_and_zero_dimension_png_header_is_rejected_without_decode(self):
        damaged = bytearray(self.png); damaged[-5] ^= 1
        with self.assertRaises(InvalidImage):
            validate_png(bytes(damaged))
        huge = bytearray(self.png)
        struct.pack_into(">I", huge, 16, 0)
        struct.pack_into(">I", huge, 29, zlib.crc32(huge[12:29]) & 0xFFFFFFFF)
        with self.assertRaises(InvalidImage):
            validate_png(bytes(huge))

    def test_malformed_or_inconsistent_backend_result_cannot_mark_success(self):
        job = self.enqueue()
        worker = DeliveryWorker(self.queue, lambda _: {"status": "verified", "pasteAttempted": False})
        worker.once()
        self.assertEqual(self.queue.get(job["id"])["state"], "uncertain")


@unittest.skipUnless(AVAILABLE, "receiver not implemented yet")
class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.queue = JobQueue(pathlib.Path(self.tmp.name))
        self.token = token_for(self.queue.directory)
        self.server = make_server(self.queue, self.token)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.png = (pathlib.Path(__file__).parent.parent / "test-image.png").read_bytes()

    def stop(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)

    def request(self, method, path, body=None, headers=None, auth=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        data = {"Authorization": "Bearer " + self.token} if auth else {}
        data.update(headers or {})
        try:
            connection.request(method, path, body, data)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_auth_is_required_and_browser_origins_are_rejected(self):
        self.assertEqual(self.request("GET", "/v1/jobs", auth=False)[0], 401)
        self.assertEqual(self.request("GET", "/v1/jobs", headers={"Origin": "https://example.com"})[0], 401)
        self.assertEqual(self.request("GET", "/v1/jobs")[0], 200)
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual((self.queue.directory / "http-token").stat().st_mode & 0o777, 0o600)

    def test_http_receive_then_worker_verification_and_idempotent_replay(self):
        key = str(uuid.uuid4())
        headers = {"Content-Type": "image/png", "X-Request-ID": key}
        status, body = self.request("POST", "/v1/screenshots", self.png, headers)
        self.assertEqual(status, 202)
        self.assertTrue(body["received"])
        self.assertEqual(body["job"]["state"], "queued")
        DeliveryWorker(self.queue, lambda _: {"status": "verified", "pasteAttempted": True, "reason": "attachment_observed"}).once()
        self.assertEqual(self.request("GET", "/v1/jobs/" + key)[1]["state"], "verified")
        self.assertEqual(self.request("POST", "/v1/screenshots", self.png, headers)[0], 200)
        self.assertEqual(len(self.queue.list()), 1)

    def test_http_conflict_invalid_content_and_size_limits(self):
        key = str(uuid.uuid4()); headers = {"Content-Type": "image/png", "X-Request-ID": key}
        self.request("POST", "/v1/screenshots", self.png, headers)
        self.assertEqual(self.request("POST", "/v1/screenshots", self.png + b"x", headers)[0], 409)
        self.assertEqual(self.request("POST", "/v1/screenshots", self.png, {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("POST", "/v1/screenshots", b"x" * 40, {"Content-Type": "image/png", "X-Request-ID": str(uuid.uuid4())})[0], 400)
        self.assertEqual(self.request("POST", "/v1/screenshots", b"x", {"Content-Type": "image/png"})[0], 413)


if __name__ == "__main__":
    unittest.main()
