import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from mac_receiver import Conflict, DeliveryWorker, InvalidImage, JobQueue, make_server, native_delivery


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.queue = JobQueue(Path(self.tmp.name))
        self.png = (Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()
        self.key = str(uuid.uuid4())

    def ready(self, count=2):
        self.queue.create_batch(self.key, count)
        for index in range(count): self.queue.upload_batch_image(self.key, index, self.png)
        return self.queue.commit_batch(self.key)

    def test_staged_uploads_never_claim_until_complete_commit(self):
        self.assertTrue(callable(getattr(self.queue, 'create_batch', None)), 'staged batch API missing')
        self.assertEqual(self.queue.create_batch(self.key, 2)['state'], 'uploading')
        self.queue.upload_batch_image(self.key, 1, self.png)
        self.assertIsNone(self.queue.claim())
        with self.assertRaises(Conflict): self.queue.commit_batch(self.key)
        self.queue.upload_batch_image(self.key, 0, self.png)
        self.assertIsNone(self.queue.claim())
        self.assertEqual(self.queue.commit_batch(self.key)['state'], 'queued')
        job = self.queue.claim()
        self.assertEqual([item['index'] for item in job['images']], [0, 1])
        self.assertTrue(all(Path(item['path']).is_absolute() for item in job['images']))
        self.assertIsNone(self.queue.claim())

    def test_ten_images_duplicate_create_upload_commit_are_idempotent(self):
        self.ready(10)
        first = self.queue.get(self.key)
        self.assertEqual(self.queue.create_batch(self.key, 10), first)
        self.assertEqual(self.queue.upload_batch_image(self.key, 0, self.png), first)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            receipts = list(pool.map(lambda _: self.queue.commit_batch(self.key), range(16)))
        self.assertEqual(receipts, [first]*16)
        DeliveryWorker(self.queue, lambda _: self.aggregate(10)).once()
        final = self.queue.get(self.key)
        self.assertEqual(self.queue.commit_batch(self.key), final)
        self.assertEqual(self.queue.create_batch(self.key, 10), final)
        self.assertEqual(self.queue.upload_batch_image(self.key, 0, self.png), final)
        self.assertEqual(final['attempts'], 1)
        self.assertIsNone(self.queue.claim())

    @staticmethod
    def aggregate(count):
        return {'status': 'verified', 'pasteAttempted': True, 'verifiedCount': count, 'totalCount': count,
                'items': [{'index': index, 'status': 'verified', 'reason': 'attachment_observed',
                           'pasteAttempted': True, 'clipboardRestoration': 'restored', 'elapsedMS': 4}
                          for index in range(count)]}

    def test_invalid_bounds_ids_and_conflicting_data_do_not_change_staging(self):
        for count in (0, 11, True, 1.0, '2'):
            with self.assertRaises(ValueError): self.queue.create_batch(self.key, count)
        for key in ('../bad', self.key.upper(), None):
            with self.assertRaises(ValueError): self.queue.create_batch(key, 2)
        self.queue.create_batch(self.key, 2)
        with self.assertRaises(Conflict): self.queue.create_batch(self.key, 3)
        for index in (-1, 2, True, '0'):
            with self.assertRaises(ValueError): self.queue.upload_batch_image(self.key, index, self.png)
        with self.assertRaises(InvalidImage): self.queue.upload_batch_image(self.key, 0, b'bad')
        self.queue.upload_batch_image(self.key, 0, self.png)
        with self.assertRaises(Conflict): self.queue.upload_batch_image(self.key, 0, self.png+b'changed')
        with self.assertRaises(Conflict): self.queue.enqueue(self.key, self.png)
        self.assertIsNone(self.queue.claim())

    def test_total_size_and_per_image_size_are_enforced(self):
        self.queue.create_batch(self.key, 2)
        with patch('mac_receiver.MAX_IMAGE', len(self.png)-1):
            with self.assertRaises(InvalidImage): self.queue.upload_batch_image(self.key, 0, self.png)
        self.queue.upload_batch_image(self.key, 0, self.png)
        with patch('mac_receiver.MAX_BATCH', len(self.png)*2-1):
            with self.assertRaises(Conflict): self.queue.upload_batch_image(self.key, 1, self.png)
        with self.assertRaises(Conflict): self.queue.commit_batch(self.key)

    def test_concurrent_upload_and_commit_never_deliver_twice(self):
        self.queue.create_batch(self.key, 2)
        def upload(index): return self.queue.upload_batch_image(self.key, index%2, self.png)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(upload, range(16)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(lambda _: self.queue.commit_batch(self.key), range(16)))
        calls=[]
        def deliver(job): calls.append(job['id']); return self.aggregate(2)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: DeliveryWorker(self.queue, deliver).once(), range(16)))
        self.assertEqual(calls, [self.key])

    def test_commit_revalidates_persisted_bytes_and_private_paths(self):
        self.queue.create_batch(self.key, 1)
        self.queue.upload_batch_image(self.key, 0, self.png)
        images=list((self.queue.directory/'images').glob('*.png'))
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0].stat().st_mode & 0o777, 0o600)
        images[0].write_bytes(b'corrupt')
        with self.assertRaises(Conflict): self.queue.commit_batch(self.key)
        self.assertIsNone(self.queue.claim())

    def test_restart_quarantines_running_and_queued_but_never_delivers_staged(self):
        self.ready(); self.queue.claim()
        second=str(uuid.uuid4()); self.queue.create_batch(second, 1)
        self.queue.upload_batch_image(second, 0, self.png); self.queue.commit_batch(second)
        third=str(uuid.uuid4()); self.queue.create_batch(third, 1)
        self.queue.recover()
        self.assertEqual(self.queue.get(self.key)['state'], 'uncertain')
        self.assertEqual(self.queue.get(second)['state'], 'blocked')
        self.assertEqual(self.queue.get(third)['state'], 'uploading')
        self.assertIsNone(self.queue.claim())
        fresh=str(uuid.uuid4()); self.queue.create_batch(fresh, 1)
        self.queue.upload_batch_image(fresh, 0, self.png); self.queue.commit_batch(fresh)
        self.assertEqual(self.queue.claim()['id'], fresh)
        self.assertEqual(self.queue.commit_batch(self.key)['state'], 'uncertain')

    def test_partial_result_is_sanitized_and_retains_item_status(self):
        self.ready(); self.queue.claim()
        result=self.aggregate(2)
        result.update(status='uncertain', verifiedCount=1, secret='private', reason='second_item_unconfirmed')
        result['items'][1].update(status='uncertain', reason='attachment_timeout', secret='private')
        self.queue.finish(self.key, result)
        saved=self.queue.get(self.key)['result']
        self.assertEqual(saved['verifiedCount'], 1)
        self.assertEqual(saved['totalCount'], 2)
        self.assertNotIn('secret', json.dumps(saved))
        self.assertEqual(saved['items'][1]['status'], 'uncertain')

    def test_false_partial_verified_result_is_quarantined(self):
        self.ready()
        result=self.aggregate(2); result['items'][1]['status']='uncertain'
        DeliveryWorker(self.queue, lambda _: result).once()
        self.assertEqual(self.queue.get(self.key)['state'], 'uncertain')

    def test_batch_success_without_complete_item_evidence_is_quarantined(self):
        self.ready()
        DeliveryWorker(self.queue, lambda _: {'status':'verified', 'pasteAttempted':True}).once()
        self.assertEqual(self.queue.get(self.key)['state'], 'uncertain')

    def test_native_timeout_and_restart_preserve_validated_durable_progress(self):
        import subprocess
        self.ready(); job=self.queue.claim()
        journal=self.aggregate(2)
        journal.update(status='uncertain', verifiedCount=1, reason='batch_paste_intent_recorded')
        journal['items'][1].update(status='uncertain', reason='paste_intent_recorded')
        result_path=Path(job['images'][0]['path']).parent/(self.key+'.result.json')
        class Process:
            def __init__(inner): inner.calls=0
            def wait(inner, timeout=None):
                inner.calls += 1
                if inner.calls == 1:
                    result_path.write_text(json.dumps(journal))
                    raise subprocess.TimeoutExpired('fixture', timeout)
                return -15
            def terminate(inner): pass
        with patch('mac_receiver.subprocess.Popen', return_value=Process()):
            result=native_delivery(job)
        self.assertEqual(result['verifiedCount'],1)
        self.queue.recover()
        saved=self.queue.get(self.key)['result']
        self.assertEqual(saved['verifiedCount'],1)
        self.assertEqual(saved['items'][1]['reason'],'paste_intent_recorded')
        self.assertIsNone(self.queue.claim())

    def test_terminal_history_does_not_consume_active_capacity(self):
        import time
        with self.queue.connect() as db:
            for _ in range(100):
                key=str(uuid.uuid4())
                db.execute("INSERT INTO jobs (id,sha256,image,state,created,updated) VALUES (?,?,?,?,?,?)",
                           (key,'fixture','','blocked',time.time(),time.time()))
        self.assertEqual(self.queue.create_batch(self.key,1)['state'],'uploading')
        self.assertEqual(self.queue.enqueue(str(uuid.uuid4()),self.png)['state'],'queued')

    def test_partial_batch_retains_untried_items_and_rejects_continuation(self):
        self.ready(3); self.queue.claim()
        result=self.aggregate(3)
        result.update(status='uncertain', verifiedCount=1)
        result['items'][1].update(status='uncertain', reason='attachment_timeout')
        result['items'][2].update(status='not_attempted', reason='earlier_item_unconfirmed', pasteAttempted=False)
        self.queue.finish(self.key,result)
        self.assertEqual(self.queue.get(self.key)['result']['items'][2]['status'],'not_attempted')
        second=str(uuid.uuid4()); self.queue.create_batch(second,3)
        for index in range(3): self.queue.upload_batch_image(second,index,self.png)
        self.queue.commit_batch(second); self.queue.claim()
        result['items'][2].update(status='verified',reason='attachment_observed',pasteAttempted=True)
        result['verifiedCount']=2
        with self.assertRaises(ValueError): self.queue.finish(second,result)

    def test_new_batch_committed_during_failed_delivery_uses_its_own_age_guard(self):
        for status in ('blocked','uncertain'):
            for stale in (False,True):
                with self.subTest(status=status,stale=stale):
                    first=str(uuid.uuid4()); second=str(uuid.uuid4())
                    self.queue.create_batch(first,1)
                    self.queue.upload_batch_image(first,0,self.png); self.queue.commit_batch(first)
                    started=threading.Event(); release=threading.Event(); outcomes=[]
                    def deliver(job):
                        self.assertEqual(job['id'],first)
                        started.set()
                        self.assertTrue(release.wait(3))
                        return {'status':status,'pasteAttempted':status=='uncertain','reason':'fixture_refusal'}
                    def consume(): outcomes.append(DeliveryWorker(self.queue,deliver,max_queue_age=3).once())
                    thread=threading.Thread(target=consume); thread.start()
                    try:
                        self.assertTrue(started.wait(3))
                        self.queue.create_batch(second,2)
                        for index in range(2): self.queue.upload_batch_image(second,index,self.png)
                        self.queue.commit_batch(second)
                        if stale:
                            with self.queue.connect() as db:
                                db.execute("UPDATE jobs SET updated=updated-10 WHERE id=?",(second,))
                        self.assertIsNone(self.queue.claim(max_age=3),'running delivery must remain exclusive')
                    finally:
                        release.set(); thread.join(timeout=4)
                    self.assertFalse(thread.is_alive())
                    self.assertEqual(outcomes,[True])
                    self.assertEqual(self.queue.get(first)['state'],status)
                    next_job=self.queue.claim(max_age=3)
                    if stale:
                        self.assertIsNone(next_job)
                        self.assertEqual(self.queue.get(second)['state'],'blocked')
                        self.assertEqual(self.queue.get(second)['result']['reason'],'queued_destination_confirmation_required')
                    else:
                        self.assertIsNotNone(next_job,'quick prior failure must not quarantine a fresh committed batch')
                        self.assertEqual(next_job['id'],second)
                        self.queue.finish(second,self.aggregate(2))
                    self.assertEqual(self.queue.get(first)['attempts'],1)
                    self.assertEqual(self.queue.commit_batch(first)['state'],status)
                    self.assertIsNone(self.queue.claim(max_age=3))

    def test_concurrent_create_is_one_staged_job(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            receipts=list(pool.map(lambda _:self.queue.create_batch(self.key,2),range(16)))
        self.assertEqual(receipts,[receipts[0]]*16)
        self.assertEqual(len(self.queue.list()),1)
        self.assertIsNone(self.queue.claim())

    def test_stale_job_does_not_block_new_fresh_job(self):
        self.ready()
        with self.queue.connect() as db: db.execute("UPDATE jobs SET updated=updated-20 WHERE id=?",(self.key,))
        fresh=self.queue.enqueue(str(uuid.uuid4()),self.png)
        self.assertEqual(self.queue.claim(max_age=3)['id'],fresh['id'])
        self.assertEqual(self.queue.get(self.key)['state'],'blocked')

    def test_native_batch_manifest_override_timeout_and_corruption_preflight(self):
        self.ready(); job=self.queue.claim(); calls=[]
        class Process:
            def wait(inner, timeout):
                self.assertGreaterEqual(timeout, 120)
                Path(calls[0][calls[0].index('--result')+1]).write_text(json.dumps(self.aggregate(2)))
                return 0
        def popen(arguments, **kwargs): calls.append(arguments); return Process()
        with patch.dict(os.environ, {'CODEX_DROP_NATIVE_ROOT': self.tmp.name}), patch('mac_receiver.subprocess.Popen', side_effect=popen):
            self.assertEqual(native_delivery(job)['verifiedCount'], 2)
        self.assertEqual(calls[0][0], str(Path(self.tmp.name)/'MacAttachmentReceiver'))
        manifest=Path(calls[0][calls[0].index('--batch')+1])
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(manifest.read_text()), {'images': [{'path':item['path'], 'sha256':hashlib.sha256(self.png).hexdigest()} for item in job['images']]})
        Path(job['images'][0]['path']).write_bytes(b'corrupt')
        with patch('mac_receiver.subprocess.Popen') as launch:
            self.assertEqual(native_delivery(job)['status'], 'blocked'); launch.assert_not_called()


class WorkerShutdownTests(unittest.TestCase):
    def test_local_receiver_waits_for_active_native_worker_before_releasing_lock(self):
        import mac_receiver
        class Server:
            server_port=1
            def serve_forever(inner): raise KeyboardInterrupt()
            def server_close(inner): pass
        class Thread:
            def __init__(inner,**kwargs): pass
            def start(inner): pass
            def join(inner,timeout=None): self.assertIsNone(timeout,'shutdown abandoned active batch worker')
        with tempfile.TemporaryDirectory() as directory:
            with patch('sys.argv',['receiver','--data-dir',directory,'serve']), patch.object(mac_receiver,'make_server',return_value=Server()), patch.object(mac_receiver.threading,'Thread',Thread):
                mac_receiver.main()


class BatchHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.queue=JobQueue(Path(self.tmp.name)); self.key=str(uuid.uuid4())
        self.server=make_server(self.queue, 'fixture', persistent_connections=True)
        self.thread=threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.addCleanup(self.stop)
        self.png=(Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()

    def stop(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)

    def request(self, path, body, content='application/json', auth=True):
        connection=http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        headers={'Content-Type':content, 'X-Request-ID':self.key}
        if auth: headers['Authorization']='Bearer fixture'
        try:
            connection.request('POST', path, body, headers); response=connection.getresponse()
            return response.status, json.loads(response.read())
        finally: connection.close()

    def test_full_protocol_auth_commit_completeness_and_poll_receipt(self):
        base='/v1/batches/'+self.key
        self.assertEqual(self.request('/v1/batches', b'{"count":2}', auth=False)[0], 401)
        self.assertEqual(self.request('/v1/batches', b'{"count":2}')[0], 202)
        self.assertEqual(self.request(base+'/commit', b'{}')[0], 409)
        for index in (1,0): self.assertEqual(self.request(base+'/images/'+str(index), self.png, 'image/png')[0],202)
        self.assertEqual(self.request(base+'/commit', b'{}')[1]['job']['state'], 'queued')
        self.assertEqual(self.request(base+'/commit', b'{}')[1]['job']['attempts'], 0)
        self.assertEqual(self.request(base+'/images/0', self.png+b'different', 'image/png')[0], 409)

    def test_strict_json_content_count_and_route_validation(self):
        for body in (b'{}', b'{"count":true}', b'{"count":11}', b'{"count":1,"count":2}', b'[]', b'{"count":NaN}'):
            self.assertEqual(self.request('/v1/batches', body)[0], 400)
        self.assertEqual(self.request('/v1/batches', b'{"count":1}', 'text/plain')[0], 415)
        self.assertEqual(self.request('/v1/batches', b'x'*1025)[0], 413)
        self.assertEqual(self.queue.list(), [])
        self.request('/v1/batches', b'{"count":1}')
        self.assertEqual(self.request('/v1/batches/'+self.key+'/commit', b'{"unexpected":1}')[0],400)
        self.assertEqual(self.request('/v1/batches/'+self.key+'/images/01', self.png, 'image/png')[0],404)


if __name__=='__main__': unittest.main()
