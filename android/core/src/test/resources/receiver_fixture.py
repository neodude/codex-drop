#!/usr/bin/env python3
"""Real HTTPS receiver, disposable state and audited fake delivery. Never native UI."""
import json
import os
import re
import secrets
import socket
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

mode = os.environ.get('CODEX_DROP_FIXTURE_MODE', 'verified')
delay = min(15, max(0, float(os.environ.get('CODEX_DROP_FIXTURE_DELAY', '0'))))
audit_path = os.environ.get('CODEX_DROP_FIXTURE_AUDIT')
if audit_path: Path(audit_path + '.events').write_text('')
events, deliveries = [], []
lock = threading.Lock()
def record(event):
    event = {'time':time.monotonic(), **event}
    with lock:
        events.append(event)
        if audit_path:
            with Path(audit_path + '.events').open('a') as stream: stream.write(json.dumps(event)+'\n')
with tempfile.TemporaryDirectory(prefix='codexdrop-android-protocol-') as temporary:
    queue = JobQueue(Path(temporary))
    identity = prepare_identity(queue.directory)
    token = secrets.token_urlsafe(32)
    server = make_tls_server(queue, token, queue.directory, 0, '127.0.0.1')
    original = server.RequestHandlerClass
    class FaultHandler(original):
        def disconnect(self):
            self.close_connection = True
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        def do_POST(self):
            if not self.authorized(): return
            record({'method':'POST','path':self.path,'id':self.headers.get('X-Request-ID')})
            if mode == 'upload_lost' and self.path.endswith('/images/1'):
                self.disconnect(); return
            return super().do_POST()
        def do_GET(self):
            record({'method':'GET','path':self.path})
            if mode == 'confirmation_lost' and re.fullmatch(r'/v1/jobs/[0-9a-f-]{36}', self.path) and not self.path.endswith('00000000-0000-0000-0000-000000000000'):
                self.disconnect(); return
            return super().do_GET()
        def reply(self, status, body):
            if status in (200,202) and self.path == '/v1/batches': record({'method':'CREATED','path':self.path,'id':body['job']['id']})
            if status in (200,202) and self.path.endswith('/commit'): record({'method':'ACCEPTED','path':self.path,'id':body['job']['id']})
            if mode == 'commit_lost' and self.path.endswith('/commit') and status in (200,202):
                self.disconnect(); return
            return super().reply(status, body)
    server.RequestHandlerClass = FaultHandler
    stop = threading.Event()
    def aggregate(job):
        stop.wait(delay)
        count = len(job['images'])
        with lock:
            ordinal = len(deliveries)
            deliveries.append({'time':time.monotonic(),'id':job['id'], 'count':count, 'indices':[item['index'] for item in job['images']]})
        if mode in ('partial_first','blocked_first') and ordinal == 0:
            verified = 1 if mode == 'partial_first' and count > 1 else 0
            status = 'uncertain' if mode == 'partial_first' else 'blocked'
            items = []
            for index in range(count):
                state = 'verified' if index < verified else status if index == verified else 'not_attempted'
                items.append({'index':index,'status':state,'pasteAttempted':state in ('verified','uncertain'),'reason':'earlier_item_unconfirmed' if state == 'not_attempted' else 'fixture_partial'})
            return {'status':status,'pasteAttempted':status=='uncertain','verifiedCount':verified,'totalCount':count,'items':items}
        return BatchTests.aggregate(count)
    def deliver():
        worker = DeliveryWorker(queue, aggregate)
        while not stop.is_set():
            worker.once(); stop.wait(.01)
    threads = [threading.Thread(target=server.serve_forever, daemon=True),threading.Thread(target=deliver, daemon=True)]
    for thread in threads: thread.start()
    # Private disposable pairing is consumed by test orchestration, never printed to logs.
    print(json.dumps({'pairing':pairing_payload(identity,token),'port':server.server_port,'mode':mode}),flush=True)
    try: sys.stdin.readline()
    finally:
        stop.set();server.shutdown();server.server_close()
        for thread in threads: thread.join(timeout=3)
        if audit_path:
            jobs = [{'id':job['id'],'state':job['state'],'attempts':job['attempts']} for job in queue.list()]
            Path(audit_path).write_text(json.dumps({'mode':mode,'events':events,'deliveries':deliveries,'jobs':jobs},indent=2)+'\n')
