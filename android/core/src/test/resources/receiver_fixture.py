#!/usr/bin/env python3
"""Isolated real receiver; fake delivery only. Never UI, clipboard or live data."""
import json
import os
import secrets
import sys
import tempfile
import threading
import time
from pathlib import Path

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / 'receiver'))
from lan_receiver import make_tls_server, pairing_payload, prepare_identity
from mac_receiver import JobQueue, DeliveryWorker
from test_batches import BatchTests

with tempfile.TemporaryDirectory(prefix='codexdrop-android-protocol-') as temporary:
    queue = JobQueue(Path(temporary))
    identity = prepare_identity(queue.directory)
    token = secrets.token_urlsafe(32)
    server = make_tls_server(queue, token, queue.directory, 0, '127.0.0.1')
    stop = threading.Event()
    def deliver():
        def aggregate(job):
            # Optional visual-capture delay, fixture only; never native delivery.
            time.sleep(min(3, max(0, float(os.environ.get('CODEX_DROP_FIXTURE_DELAY', '0')))))
            return BatchTests.aggregate(len(job['images']))
        worker = DeliveryWorker(queue, aggregate)
        while not stop.is_set():
            worker.once()
            stop.wait(.01)
    threads = [threading.Thread(target=server.serve_forever, daemon=True), threading.Thread(target=deliver, daemon=True)]
    for thread in threads: thread.start()
    # Private ephemeral fixture pairing is consumed by the JVM, never logged.
    print(json.dumps({'pairing': pairing_payload(identity, token), 'port': server.server_port}), flush=True)
    try:
        sys.stdin.readline()
    finally:
        stop.set(); server.shutdown(); server.server_close()
        for thread in threads: thread.join(timeout=2)
