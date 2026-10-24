#!/usr/bin/env python3
"""Local-only screenshot queue. Receipt is not attachment acknowledgement."""
import argparse
import contextlib
import fcntl
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import struct
import subprocess
import threading
import tempfile
import time
import uuid
import zlib

MAX_IMAGE = 20 * 1024 * 1024
MAX_BATCH = 100 * 1024 * 1024
MAX_BATCH_COUNT = 10
NATIVE_TIMEOUT = 240
ROOT = Path(__file__).resolve().parent
from runtime_storage import DEFAULT_DATA


class Conflict(Exception):
    pass


class InvalidImage(ValueError):
    pass


def validate_png(data):
    if not 33 <= len(data) <= MAX_IMAGE or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise InvalidImage("Expected a PNG no larger than 20 MiB")
    offset, dimensions, saw_data, ended = 8, None, False, False
    while offset + 12 <= len(data):
        length, = struct.unpack_from(">I", data, offset)
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise InvalidImage("Truncated PNG")
        payload = data[offset + 8:end - 4]
        crc, = struct.unpack_from(">I", data, end - 4)
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise InvalidImage("PNG checksum mismatch")
        if dimensions is None:
            if kind != b"IHDR" or length != 13:
                raise InvalidImage("Missing PNG header")
            width, height, _, _, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if not width or not height or width > 10000 or height > 10000 or width * height > 40_000_000:
                raise InvalidImage("PNG dimensions exceed limit")
            if compression or filtering or interlace not in (0, 1):
                raise InvalidImage("Unsupported PNG encoding")
            dimensions = width, height
        elif kind == b"IHDR":
            raise InvalidImage("Duplicate PNG header")
        if kind == b"IDAT":
            saw_data = True
        if kind == b"IEND":
            if length or end != len(data) or not saw_data:
                raise InvalidImage("Invalid PNG ending")
            ended = True
            break
        offset = end
    if not ended:
        raise InvalidImage("Incomplete PNG")
    return dimensions


class JobQueue:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        (self.directory / "images").mkdir(mode=0o700, exist_ok=True)
        os.chmod(self.directory / "images", 0o700)
        self.database = self.directory / "queue.sqlite3"
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, image TEXT NOT NULL,
                    state TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                    result TEXT, updated REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS expired_images (job_id TEXT PRIMARY KEY, expired REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS maintenance (name TEXT PRIMARY KEY, performed REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS batches (
                    id TEXT PRIMARY KEY REFERENCES jobs(id), count INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS batch_images (
                    batch_id TEXT NOT NULL REFERENCES batches(id), image_index INTEGER NOT NULL,
                    path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
                    PRIMARY KEY (batch_id, image_index)
                );
            """)
        os.chmod(self.database, 0o600)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def public(row):
        if row is None:
            return None
        value = dict(row)
        value.pop("image", None)
        value["result"] = json.loads(value["result"]) if value["result"] else None
        return value

    @staticmethod
    def validate_id(key):
        try:
            if str(uuid.UUID(key)) != key:
                raise ValueError()
        except (ValueError, AttributeError, TypeError):
            raise ValueError("Request ID must be a canonical lowercase UUID") from None

    @staticmethod
    def check_capacity(db):
        if db.execute("SELECT count(*) FROM jobs WHERE state IN ('uploading','queued','running')").fetchone()[0] >= 100:
            raise Conflict("Queue is full; resolve pending jobs first")

    def persist_image(self, name, data):
        image = (self.directory / "images" / name).resolve()
        temporary = image.with_suffix(".tmp-" + str(uuid.uuid4()))
        try:
            with temporary.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, image)
            directory_fd = os.open(image.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            temporary.unlink(missing_ok=True)
        return image

    def enqueue(self, key, data):
        self.validate_id(key)
        digest = hashlib.sha256(data).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone()
            if previous:
                if db.execute("SELECT 1 FROM batches WHERE id=?", (key,)).fetchone() or previous["sha256"] != digest:
                    raise Conflict("Request ID already belongs to different bytes")
                return self.public(previous)
            validate_png(data)
            self.check_capacity(db)
            image = self.persist_image(key + ".png", data)
            now = time.time()
            try:
                db.execute("INSERT INTO jobs (id,sha256,image,state,result,created,updated) VALUES (?,?,?,?,?,?,?)",
                           (key, digest, str(image), "queued", None, now, now))
            except BaseException:
                image.unlink(missing_ok=True)
                raise
            return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())

    def create_batch(self, key, count):
        self.validate_id(key)
        if type(count) is not int or not 1 <= count <= MAX_BATCH_COUNT:
            raise ValueError("Batch count must be 1–10")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone()
            if previous:
                batch = db.execute("SELECT count FROM batches WHERE id=?", (key,)).fetchone()
                if not batch or batch["count"] != count:
                    raise Conflict("Request ID already belongs to different content")
                return self.public(previous)
            self.check_capacity(db)
            now = time.time()
            db.execute("INSERT INTO jobs (id,sha256,image,state,created,updated) VALUES (?,?,?,?,?,?)",
                       (key, "batch", "", "uploading", now, now))
            db.execute("INSERT INTO batches (id,count) VALUES (?,?)", (key, count))
            return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())

    def upload_batch_image(self, key, index, data):
        self.validate_id(key)
        if type(index) is not int or not 0 <= index < MAX_BATCH_COUNT:
            raise ValueError("Invalid image index")
        digest = hashlib.sha256(data).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            batch = db.execute("SELECT jobs.*,batches.count FROM jobs JOIN batches USING(id) WHERE id=?", (key,)).fetchone()
            if not batch or index >= batch["count"]:
                raise ValueError("Unknown batch or image index")
            existing = db.execute("SELECT sha256 FROM batch_images WHERE batch_id=? AND image_index=?", (key,index)).fetchone()
            if existing:
                if existing["sha256"] != digest:
                    raise Conflict("Image index already contains different bytes")
                return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())
            if batch["state"] != "uploading":
                raise Conflict("Batch is already committed")
            validate_png(data)
            total = db.execute("SELECT coalesce(sum(size),0) FROM batch_images WHERE batch_id=?", (key,)).fetchone()[0]
            if total + len(data) > MAX_BATCH:
                raise Conflict("Batch total exceeds 100 MiB")
            image = self.persist_image(f"{key}-{index}.png", data)
            try:
                db.execute("INSERT INTO batch_images (batch_id,image_index,path,sha256,size) VALUES (?,?,?,?,?)",
                           (key,index,str(image),digest,len(data)))
            except BaseException:
                image.unlink(missing_ok=True)
                raise
            return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())

    def commit_batch(self, key):
        self.validate_id(key)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            batch = db.execute("SELECT jobs.*,batches.count FROM jobs JOIN batches USING(id) WHERE id=?", (key,)).fetchone()
            if not batch:
                raise ValueError("Unknown batch")
            if batch["state"] != "uploading":
                return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())
            images = db.execute("SELECT * FROM batch_images WHERE batch_id=? ORDER BY image_index", (key,)).fetchall()
            if len(images) != batch["count"] or sum(item["size"] for item in images) > MAX_BATCH:
                raise Conflict("Batch is incomplete or oversized")
            try:
                for item in images:
                    data = Path(item["path"]).read_bytes()
                    if len(data) != item["size"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
                        raise ValueError("Staged image changed")
                    validate_png(data)
            except (OSError, ValueError):
                raise Conflict("Staged image validation failed") from None
            digest = hashlib.sha256(json.dumps([item["sha256"] for item in images]).encode()).hexdigest()
            db.execute("UPDATE jobs SET state='queued',sha256=?,updated=? WHERE id=?", (digest,time.time(),key))
            return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())

    def get(self, key):
        with self.connect() as db:
            return self.public(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone())

    def list(self):
        with self.connect() as db:
            return [self.public(row) for row in db.execute("SELECT * FROM jobs ORDER BY created,id")]

    def claim(self, max_age=None, now=None):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                return None
            if max_age is not None:
                db.execute("UPDATE jobs SET state='blocked',result=?,updated=? WHERE state='queued' AND updated<?",
                           (json.dumps({"status": "blocked", "pasteAttempted": False, "reason": "queued_destination_confirmation_required"}),
                            time.time(), (time.time() if now is None else now) - max_age))
            row = db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY created,rowid LIMIT 1").fetchone()
            if not row:
                return None
            db.execute("UPDATE jobs SET state='running',attempts=attempts+1,updated=? WHERE id=?", (time.time(), row["id"]))
            job = dict(db.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone())
            batch = db.execute("SELECT count FROM batches WHERE id=?", (row["id"],)).fetchone()
            if batch:
                job["images"] = [{"index":item["image_index"], "path":item["path"], "sha256":item["sha256"]}
                                 for item in db.execute("SELECT * FROM batch_images WHERE batch_id=? ORDER BY image_index", (row["id"],))]
            return job

    def finish(self, key, result):
        status = result.get("status")
        attempted = result.get("pasteAttempted")
        if status not in ("verified", "blocked", "uncertain") or type(attempted) is not bool:
            raise ValueError("Invalid delivery result")
        if status == "verified" and not attempted or status == "blocked" and attempted:
            raise ValueError("Inconsistent delivery result")
        # Keep machine-readable diagnostics only, never arbitrary backend output.
        allowed = {"status", "reason", "pasteAttempted", "clipboardRead", "clipboardRestoration", "elapsedMS", "diagnostics"}
        clean = {k: v for k, v in result.items() if k in allowed}
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            batch = db.execute("SELECT count FROM batches WHERE id=?", (key,)).fetchone()
            if batch:
                if "items" in result:
                    clean.update(sanitize_batch_result(result, batch["count"]))
                elif status == "verified":
                    raise ValueError("Batch success requires complete item evidence")
            changed = db.execute("UPDATE jobs SET state=?,result=?,updated=? WHERE id=? AND state='running'",
                                 (status, json.dumps(clean), time.time(), key)).rowcount
            if changed != 1:
                raise Conflict("Job is not running")
            # Other jobs have their own destination-age guard at claim time.
            # A terminal result never requeues itself or quarantines another batch.

    def cleanup_expired(self, now=None):
        """Daily 30-day screenshot retention. Receipts remain, never replay old bytes."""
        now = time.time() if now is None else now
        cutoff = now - 30 * 86400
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT performed FROM maintenance WHERE name='retention'").fetchone()
            if previous and 0 <= now - previous[0] < 86400:
                return None
            # A live delivery can outlive its normal timeout: never remove its files.
            protected = {row[0] for row in db.execute("SELECT id FROM jobs WHERE state='running'")}
            expired = db.execute("SELECT id,state FROM jobs WHERE created<? AND state!='running'", (cutoff,)).fetchall()
            keys = {row["id"] for row in expired}
            for row in expired:
                if row["state"] in ("uploading", "queued"):
                    db.execute("UPDATE jobs SET state='blocked',result=?,updated=? WHERE id=?",
                               (json.dumps({"status":"blocked","pasteAttempted":False,"reason":"screenshots_expired"}),now,row["id"]))
                db.execute("INSERT OR IGNORE INTO expired_images VALUES (?,?)", (row["id"],now))
            db.execute("INSERT OR REPLACE INTO maintenance VALUES ('retention',?)", (now,))
        removed = failures = 0
        # Names are derived from our UUID IDs, not paths supplied by a queue row.
        pattern = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:-[0-9])?(?:\.png|\.result\.json|\.result\.manifest\.json)")
        images = self.directory / "images"
        if images.is_symlink(): raise ValueError("Unsafe screenshot directory")
        for path in images.iterdir():
            match = pattern.fullmatch(path.name)
            if not match or match[1] in protected or path.is_symlink(): continue
            try:
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid(): continue
                if match[1] in keys or info.st_mtime < cutoff:
                    # Do not classify a recent known job as an old orphan.
                    if match[1] not in keys:
                        with self.connect() as db:
                            if db.execute("SELECT 1 FROM jobs WHERE id=?",(match[1],)).fetchone(): continue
                    path.unlink(); removed += 1
            except OSError: failures += 1
        return {"removed":removed,"failures":failures}

    def recover(self, pause_queued=True):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            for row in db.execute("SELECT * FROM jobs WHERE state='running'").fetchall():
                result = {"status": "uncertain", "pasteAttempted": True, "reason": "receiver_restarted_during_delivery"}
                images = [{"path":item["path"], "sha256":item["sha256"]} for item in
                          db.execute("SELECT * FROM batch_images WHERE batch_id=? ORDER BY image_index", (row["id"],))]
                if images:
                    durable = interrupted_batch_result({"id":row["id"], "images":images})
                    if durable and durable["status"] == "uncertain":
                        result = durable
                db.execute("UPDATE jobs SET state='uncertain',result=?,updated=? WHERE id=?",
                           (json.dumps(result),time.time(),row["id"]))
            if pause_queued:
                db.execute("UPDATE jobs SET state='blocked',result=?,updated=? WHERE state='queued'",
                           (json.dumps({"status": "blocked", "pasteAttempted": False, "reason": "receiver_restarted_before_delivery"}), time.time()))

    def retry(self, key):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM expired_images WHERE job_id=?", (key,)).fetchone():
                raise Conflict("Screenshot files expired; share a new request instead")
            row = db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone()
            if not row or row["state"] != "blocked" or json.loads(row["result"]).get("pasteAttempted") is not False:
                raise Conflict("Only a blocked, unattempted job can retry; resolve uncertain jobs explicitly")
            db.execute("UPDATE jobs SET state='queued',result=NULL,updated=? WHERE id=?", (time.time(), key))

    def resolve(self, key, decision):
        if decision not in ("attached", "discard"):
            raise ValueError("Resolution must be attached or discard")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT state FROM jobs WHERE id=?", (key,)).fetchone()
            if not row or row["state"] not in ("uncertain", "blocked", "queued"):
                raise Conflict("Job cannot be resolved in its current state")
            result = {"status": "verified" if decision == "attached" else "dismissed", "reason": "user_resolved_" + decision}
            db.execute("UPDATE jobs SET state=?,result=?,updated=? WHERE id=?",
                       (result["status"], json.dumps(result), time.time(), key))


class DeliveryWorker:
    def __init__(self, queue, deliver, max_queue_age=None):
        self.queue, self.deliver, self.max_queue_age = queue, deliver, max_queue_age

    def once(self):
        job = self.queue.claim(max_age=self.max_queue_age)
        if job is None:
            return False
        try:
            result = self.deliver(job)
            self.queue.finish(job["id"], result)
        except Exception:
            self.queue.finish(job["id"], {"status": "uncertain", "pasteAttempted": True, "reason": "backend_failed_or_timed_out"})
        return True


def sanitize_batch_result(result, count):
    items = result.get("items")
    if type(items) is not list or len(items) != count or type(result.get("totalCount")) is not int or result["totalCount"] != count:
        raise ValueError("Invalid batch result count")
    clean = []
    for index, item in enumerate(items):
        if type(item) is not dict or type(item.get("index")) is not int or item["index"] != index:
            raise ValueError("Invalid batch item index")
        status, attempted = item.get("status"), item.get("pasteAttempted")
        if status not in ("verified", "blocked", "uncertain", "not_attempted") or type(attempted) is not bool:
            raise ValueError("Invalid batch item status")
        if status in ("verified", "uncertain") and not attempted or status in ("blocked", "not_attempted") and attempted:
            raise ValueError("Inconsistent batch item status")
        value = {"index": index, "status": status, "pasteAttempted": attempted}
        for field in ("reason", "clipboardRestoration"):
            if field in item:
                if type(item[field]) is not str or re.fullmatch(r"[a-zA-Z0-9_:-]{1,128}", item[field]) is None:
                    raise ValueError("Invalid batch diagnostic")
                value[field] = item[field]
        if "elapsedMS" in item:
            if type(item["elapsedMS"]) is not int or not 0 <= item["elapsedMS"] <= 10_000_000:
                raise ValueError("Invalid batch elapsed time")
            value["elapsedMS"] = item["elapsedMS"]
        clean.append(value)
    verified = sum(item["status"] == "verified" for item in clean)
    attempted = any(item["pasteAttempted"] for item in clean)
    expected = "verified" if verified == count else "uncertain" if attempted else "blocked"
    if (type(result.get("verifiedCount")) is not int or result["verifiedCount"] != verified or
            result.get("status") != expected or result.get("pasteAttempted") != attempted):
        raise ValueError("Inconsistent batch aggregate")
    # A later image may never be attempted after an unconfirmed earlier item.
    stopped = False
    for item in clean:
        if stopped and (item["status"] != "not_attempted" or item.get("reason") != "earlier_item_unconfirmed"):
            raise ValueError("Batch continued after unconfirmed image")
        if item["status"] != "verified":
            if not stopped and item["status"] == "not_attempted":
                raise ValueError("Missing first unconfirmed item")
            stopped = True
    return {"items": clean, "verifiedCount": verified, "totalCount": count}


def interrupted_batch_result(job):
    if not job.get("images"):
        return None
    path = Path(job["images"][0]["path"]).parent / (job["id"] + ".result.json")
    try:
        result = json.loads(path.read_text())
        if result.get("status") not in ("blocked", "uncertain"):
            return None
        aggregate = sanitize_batch_result(result, len(job["images"]))
        clean = {key:result[key] for key in ("status", "reason", "pasteAttempted", "clipboardRestoration", "elapsedMS") if key in result}
        if "reason" in clean and (type(clean["reason"]) is not str or re.fullmatch(r"[a-zA-Z0-9_:-]{1,128}",clean["reason"]) is None):
            return None
        clean.update(aggregate)
        return clean
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def native_root():
    return Path(os.environ.get("CODEX_DROP_NATIVE_ROOT", str(ROOT.parent)))


def native_delivery(job, test_arguments=(), live_output=False):
    executable = native_root() / "MacAttachmentReceiver"
    images = job.get("images")
    if images is not None:
        result_path = Path(images[0]["path"]).parent / (job["id"] + ".result.json") if images else None
        if not 1 <= len(images) <= MAX_BATCH_COUNT:
            return {"status": "blocked", "pasteAttempted": False, "reason": "invalid_batch_manifest"}
        total = 0
        try:
            for image in images:
                data = Path(image["path"]).read_bytes()
                validate_png(data)
                total += len(data)
                if hashlib.sha256(data).hexdigest() != image["sha256"] or total > MAX_BATCH:
                    raise ValueError("Changed batch image")
        except (OSError, ValueError):
            return {"status": "blocked", "pasteAttempted": False, "reason": "queued_image_checksum_changed"}
        manifest_path = result_path.with_suffix(".manifest.json")
        manifest = {"images": [{"path":str(Path(item["path"]).resolve()), "sha256":item["sha256"]} for item in images]}
        with tempfile.NamedTemporaryFile(dir=manifest_path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(json.dumps(manifest).encode()); stream.flush(); os.fsync(stream.fileno())
        try:
            os.replace(temporary, manifest_path)
        finally:
            temporary.unlink(missing_ok=True)
        arguments = ["--batch", str(manifest_path)]
    else:
        result_path = Path(job["image"]).with_suffix(".result.json")
        if hashlib.sha256(Path(job["image"]).read_bytes()).hexdigest() != job["sha256"]:
            return {"status": "blocked", "pasteAttempted": False, "reason": "queued_image_checksum_changed"}
        arguments = ["--image", job["image"]]
    result_path.unlink(missing_ok=True)
    process = subprocess.Popen([str(executable), *arguments, "--result", str(result_path), *test_arguments],
                               stdout=None if live_output else subprocess.DEVNULL,
                               stderr=None if live_output else subprocess.DEVNULL)
    try:
        status = process.wait(timeout=NATIVE_TIMEOUT if images is not None else 25)
    except BaseException:
        process.terminate() # Allow the adapter's signal handler to restore its clipboard lease.
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        durable = interrupted_batch_result(job) if images is not None else None
        if durable:
            return durable
        raise
    if status:
        durable = interrupted_batch_result(job) if images is not None else None
        if durable:
            return durable
        raise RuntimeError("Native delivery failed")
    return json.loads(result_path.read_text())


def token_for(directory):
    path = Path(directory) / "http-token"
    if not path.exists():
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, prefix=".http-token-", delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            stream.write(secrets.token_urlsafe(32))
            stream.flush(); os.fsync(stream.fileno())
        try:
            try:
                os.link(temporary, path) # Atomic complete-file publication; never replace an existing token.
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)
    if path.is_symlink():
        raise ValueError("Local receiver token must be a regular private file")
    token = path.read_text().strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{43}", token) is None:
        raise ValueError("Local receiver token file is malformed; refusing to start")
    os.chmod(path, 0o600)
    return token


def make_server(queue, token, port=0, *, bind_host="127.0.0.1", persistent_connections=False):
    class Handler(BaseHTTPRequestHandler):
        timeout = 5
        protocol_version = "HTTP/1.1" if persistent_connections else "HTTP/1.0"

        def log_message(self, *_):
            pass # Never log request headers, tokens, image bytes or full paths.

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def reject(self, status, error):
            # Unread bytes must never become the next request on a live socket.
            self.close_connection = True
            self.reply(status, {"error": error})

        def content_length(self, required=False):
            lengths = self.headers.get_all("Content-Length", [])
            if self.headers.get_all("Transfer-Encoding") is not None:
                self.reject(400, "unsupported_request_framing")
                return None
            if not lengths and not required:
                return 0
            if len(lengths) != 1 or re.fullmatch(r"[0-9]+", lengths[0]) is None:
                self.reject(400, "invalid_content_length")
                return None
            try:
                return int(lengths[0])
            except ValueError:
                self.reject(400, "invalid_content_length")
                return None

        def authorized(self):
            supplied = self.headers.get("Authorization", "")
            if self.headers.get("Origin") or not hmac.compare_digest(supplied, "Bearer " + token):
                self.reject(401, "unauthorized")
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            length = self.content_length()
            if length is None:
                return
            if length:
                self.reject(400, "unexpected_request_body")
                return
            if self.path == "/v1/jobs":
                self.reply(200, {"jobs": queue.list()})
            elif self.path.startswith("/v1/jobs/"):
                job = queue.get(self.path.removeprefix("/v1/jobs/"))
                self.reply(200 if job else 404, job or {"error": "not_found"})
            else:
                self.reply(404, {"error": "not_found"})

        def do_POST(self):
            if not self.authorized():
                return
            image_match = re.fullmatch(r"/v1/batches/([0-9a-f-]{36})/images/([0-9])", self.path)
            commit_match = re.fullmatch(r"/v1/batches/([0-9a-f-]{36})/commit", self.path)
            is_image = self.path == "/v1/screenshots" or image_match is not None
            if not is_image and self.path != "/v1/batches" and commit_match is None:
                self.reject(404, "not_found")
                return
            length = self.content_length(required=True)
            if length is None:
                return
            content = "image/png" if is_image else "application/json"
            if self.headers.get("Content-Type") != content:
                self.reject(415, "unexpected_content_type")
                return
            if not (33 <= length <= MAX_IMAGE if is_image else 2 <= length <= 1024):
                self.reject(413, "image_size_limit" if is_image else "json_size_limit")
                return
            try:
                data = self.rfile.read(length)
            except OSError:
                self.reject(400, "incomplete_request_body")
                return
            if len(data) != length:
                self.reject(400, "incomplete_request_body")
                return
            try:
                if is_image:
                    job = (queue.upload_batch_image(image_match[1], int(image_match[2]), data) if image_match else
                           queue.enqueue(self.headers.get("X-Request-ID"), data))
                else:
                    def unique_object(pairs):
                        value = {}
                        for key, item in pairs:
                            if key in value:
                                raise ValueError("Duplicate JSON field")
                            value[key] = item
                        return value
                    def invalid_constant(_):
                        raise ValueError("Invalid JSON constant")
                    value = json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)
                    if type(value) is not dict:
                        raise ValueError("Expected object")
                    if commit_match:
                        if value:
                            raise ValueError("Commit body must be empty object")
                        job = queue.commit_batch(commit_match[1])
                    else:
                        if set(value) != {"count"}:
                            raise ValueError("Expected count only")
                        job = queue.create_batch(self.headers.get("X-Request-ID"), value["count"])
                self.reply(200 if job["state"] in ("verified", "blocked", "uncertain", "dismissed") else 202,
                           {"received": True, "job": job})
            except Conflict:
                self.reply(409, {"error": "request_conflict_or_queue_full"})
            except (ValueError, InvalidImage):
                self.reply(400, {"error": "invalid_image_or_request_id"})
            except OSError:
                self.reply(503, {"error": "storage_unavailable"})

    server = ThreadingHTTPServer((bind_host, port), Handler)
    server.daemon_threads = True
    return server


@contextlib.contextmanager
def process_lock(queue):
    with (queue.directory / "receiver.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Conflict("Another receiver/delivery process is running") from None
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    enqueue = commands.add_parser("enqueue"); enqueue.add_argument("image", type=Path); enqueue.add_argument("--id", default=None)
    commands.add_parser("status")
    retry = commands.add_parser("retry"); retry.add_argument("id")
    resolve = commands.add_parser("resolve"); resolve.add_argument("id"); resolve.add_argument("decision", choices=("attached", "discard"))
    deliver = commands.add_parser("deliver"); deliver.add_argument("--countdown", type=int, default=8)
    serve = commands.add_parser("serve"); serve.add_argument("--port", type=int, default=9237)
    args = parser.parse_args()
    os.umask(0o077)
    from runtime_storage import prepare_storage
    data = args.data_dir if args.data_dir is not None else prepare_storage(ROOT.parent / "receiver-data")
    queue = JobQueue(data)
    if args.command == "enqueue":
        print(json.dumps(queue.enqueue(args.id or str(uuid.uuid4()), args.image.read_bytes()), indent=2))
    elif args.command == "status":
        print(json.dumps(queue.list(), indent=2))
    elif args.command == "retry":
        queue.retry(args.id)
    elif args.command == "resolve":
        queue.resolve(args.id, args.decision)
    else:
        with process_lock(queue):
            queue.recover(pause_queued=args.command == "serve")
            worker = DeliveryWorker(queue, native_delivery, max_queue_age=3 if args.command == "serve" else None)
            if args.command == "deliver":
                print("Focus Codex's MAIN composer with an empty selection now.", flush=True)
                for remaining in range(min(max(args.countdown, 0), 30), 0, -1):
                    print(str(remaining) + "…", flush=True); time.sleep(1)
                worker.once()
                print(json.dumps(queue.list(), indent=2))
            else:
                token = token_for(queue.directory)
                server = make_server(queue, token, args.port)
                stop = threading.Event()
                def consume():
                    while not stop.is_set():
                        if not worker.once():
                            stop.wait(0.15)
                thread = threading.Thread(target=consume, daemon=True); thread.start()
                print(f"Receiver listening on 127.0.0.1:{server.server_port}. Token file: {queue.directory / 'http-token'}", flush=True)
                print("Only a focused, recognized composer can receive an image. Ctrl-C stops the receiver.", flush=True)
                try:
                    server.serve_forever()
                except KeyboardInterrupt:
                    pass
                finally:
                    stop.set(); server.server_close(); thread.join() # Keep the process lock until native cleanup completes.


if __name__ == "__main__":
    try:
        main()
    except (Conflict, InvalidImage, ValueError, OSError) as error:
        raise SystemExit(str(error))
