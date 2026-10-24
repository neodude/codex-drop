"""Retention/migration regressions: temporary data only, never the live receiver."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock
import uuid

import mac_receiver
from mac_receiver import JobQueue, Conflict
from runtime_storage import prepare_storage

DAY = 86400
PNG = (Path(__file__).resolve().parent.parent / 'test-image.png').read_bytes()

class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.queue = JobQueue(Path(self.tmp.name)); self.now = time.time()
    def job(self, age, state='verified', batch=False):
        key = str(uuid.uuid4())
        if batch:
            self.queue.create_batch(key, 2)
            for i in range(2): self.queue.upload_batch_image(key, i, PNG)
            self.queue.commit_batch(key)
        else: self.queue.enqueue(key, PNG)
        with self.queue.connect() as db:
            db.execute('UPDATE jobs SET created=?,updated=?,state=?,result=? WHERE id=?',
                       (self.now-age,self.now-age,state,json.dumps({'status':state,'pasteAttempted':False}),key))
        return key
    def test_cutoff_recent_running_and_new_clipboard_independent(self):
        old=self.job(30*DAY+1); boundary=self.job(30*DAY); recent=self.job(DAY); running=self.job(40*DAY,'running')
        self.queue.cleanup_expired(now=self.now)
        for key,present in [(old,False),(boundary,True),(recent,True),(running,True)]:
            self.assertEqual((self.queue.directory/'images'/f'{key}.png').exists(),present)
        self.assertEqual(self.queue.get(old)['state'],'verified')
        self.assertEqual(self.queue.enqueue(old,PNG)['state'],'verified')
    def test_batch_keeps_metadata_and_cannot_retry_expired(self):
        key=self.job(31*DAY,'blocked',True); self.queue.cleanup_expired(now=self.now)
        self.assertFalse(list((self.queue.directory/'images').glob(key+'*.png')))
        self.assertEqual(self.queue.create_batch(key,2)['state'],'blocked')
        with self.assertRaises(Conflict): self.queue.retry(key)
    def test_stale_upload_expires_but_active_job_does_not(self):
        key=self.job(31*DAY,'uploading',True); self.queue.cleanup_expired(now=self.now)
        self.assertEqual(self.queue.get(key)['state'],'blocked')
        self.assertEqual(self.queue.commit_batch(key)['state'],'blocked')
    def test_owned_orphans_only_no_symlink_following(self):
        images=self.queue.directory/'images'; old=images/(str(uuid.uuid4())+'.png'); old.write_bytes(PNG)
        other=images/'unrelated.png'; other.write_bytes(PNG)
        outside=self.queue.directory/'secret.png'; outside.write_bytes(PNG)
        link=images/(str(uuid.uuid4())+'.png'); link.symlink_to(outside)
        for p in (old,other,outside): os.utime(p,(self.now-40*DAY,)*2)
        self.queue.cleanup_expired(now=self.now)
        self.assertFalse(old.exists()); self.assertTrue(other.exists()); self.assertTrue(outside.exists()); self.assertTrue(link.is_symlink())
    def test_crashed_upload_temporaries_expire_only_when_owned_old_and_unprotected(self):
        images=self.queue.directory/'images'
        def temporary(key=None, index=''):
            return images/f'{key or uuid.uuid4()}{index}.tmp-{uuid.uuid4()}'
        old=temporary(); old_batch=temporary(index='-1')
        expired=self.job(31*DAY); expired_old=temporary(expired); expired_recent=temporary(expired)
        recent_job=self.job(DAY,'uploading'); active_old=temporary(recent_job)
        running=self.job(40*DAY,'running'); running_old=temporary(running)
        recent=temporary(); boundary=temporary(); unowned=temporary()
        outside=self.queue.directory/f'{uuid.uuid4()}.tmp-{uuid.uuid4()}'
        malformed=[images/f'{uuid.uuid4()}.tmp-not-a-uuid', images/f'{uuid.uuid4()}.tmp-{uuid.uuid4()}.png',
                   images/f'{uuid.uuid4()}.tmp-ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDEF', images/f'other.tmp-{uuid.uuid4()}']
        for path in [old,old_batch,expired_old,expired_recent,active_old,running_old,recent,boundary,unowned,outside,*malformed]:
            path.write_bytes(PNG)
            os.utime(path,(self.now-40*DAY,)*2)
        for path in (expired_recent,recent): os.utime(path,(self.now-DAY,)*2)
        os.utime(boundary,(self.now-30*DAY,)*2)
        link=temporary(); link.symlink_to(outside)
        directory=temporary(); directory.mkdir()
        original_lstat=Path.lstat
        def lstat(path,*args,**kwargs):
            info=original_lstat(path,*args,**kwargs)
            if path == unowned:
                fields=list(info); fields[4] += 1
                return os.stat_result(fields)
            return info
        with mock.patch.object(Path,'lstat',lstat): self.queue.cleanup_expired(now=self.now)
        for path in (old,old_batch,expired_old): self.assertFalse(path.exists(),f'old owned screenshot temporary retained: {path.name}')
        for path in (expired_recent,active_old,running_old,recent,boundary,unowned,outside,directory,*malformed):
            self.assertTrue(path.exists(),f'protected/non-owned file removed: {path.name}')
        self.assertTrue(link.is_symlink())

    def test_failed_removal_retries_next_day_and_keeps_receipt(self):
        key=self.job(31*DAY); image=self.queue.directory/'images'/f'{key}.png'
        original=Path.unlink
        def refuse(path,*args,**kwargs):
            if path == image: raise PermissionError('fixture denial')
            return original(path,*args,**kwargs)
        with mock.patch.object(Path,'unlink',refuse):
            self.assertEqual(self.queue.cleanup_expired(now=self.now)['failures'],1)
        self.assertTrue(image.exists())
        self.assertEqual(self.queue.get(key)['state'],'verified')
        self.queue.cleanup_expired(now=self.now+DAY)
        self.assertFalse(image.exists())

    def test_daily_maintenance_and_credentials_survive(self):
        key=self.job(31*DAY); token=self.queue.directory/'http-token';token.write_text('test credential')
        self.assertIsNotNone(self.queue.cleanup_expired(now=self.now))
        self.assertIsNone(self.queue.cleanup_expired(now=self.now+DAY-1))
        self.assertIsNotNone(self.queue.cleanup_expired(now=self.now+DAY))
        self.assertEqual(token.read_text(),'test credential')

class RetentionScheduleTests(unittest.TestCase):
    def scheduler(self, result=None):
        self.assertTrue(callable(getattr(mac_receiver,'RetentionMaintenance',None)), 'shared retention scheduler missing')
        queue=mock.Mock()
        queue.cleanup_expired.return_value={'removed':0,'failures':0} if result is None else result
        return mac_receiver.RetentionMaintenance(queue),queue

    def test_startup_daily_and_sleep_use_wall_clock(self):
        scheduler,queue=self.scheduler()
        for now in (1000,1001,1000+DAY-1): scheduler.check(now=now)
        queue.cleanup_expired.assert_called_once_with(now=1000)
        scheduler.check(now=1000+DAY)
        scheduler.check(now=1000+4*DAY)
        self.assertEqual(queue.cleanup_expired.call_args_list,[mock.call(now=1000),mock.call(now=1000+DAY),mock.call(now=1000+4*DAY)])

    def test_backward_clock_rechecks_without_waiting_for_future_deadline(self):
        scheduler,queue=self.scheduler()
        scheduler.check(now=1000); scheduler.check(now=999); scheduler.check(now=1000)
        self.assertEqual(queue.cleanup_expired.call_args_list,[mock.call(now=1000),mock.call(now=999)])

    def test_persisted_not_due_receipt_is_rechecked_hourly_until_daily_pass(self):
        scheduler,queue=self.scheduler()
        queue.cleanup_expired.side_effect=[None,None,{'removed':1,'failures':0}]
        for now in (1000,4599,4600,8199,8200,8201): scheduler.check(now=now)
        self.assertEqual(queue.cleanup_expired.call_args_list,[mock.call(now=1000),mock.call(now=4600),mock.call(now=8200)])
        scheduler.check(now=8200+DAY-1)
        self.assertEqual(queue.cleanup_expired.call_count,3)

    def test_cleanup_errors_retry_hourly_and_file_removal_failures_daily(self):
        import sqlite3
        for error in (OSError('fixture'),ValueError('fixture'),sqlite3.Error('fixture')):
            with self.subTest(error=type(error).__name__):
                scheduler,queue=self.scheduler()
                queue.cleanup_expired.side_effect=[error,{'removed':0,'failures':1},{'removed':1,'failures':0}]
                with mock.patch('builtins.print') as report:
                    for now in (1000,4599,4600,4600+DAY-1,4600+DAY): scheduler.check(now=now)
                self.assertEqual(queue.cleanup_expired.call_args_list,[mock.call(now=1000),mock.call(now=4600),mock.call(now=4600+DAY)])
                self.assertEqual(report.call_count,2)

    def test_shared_worker_loop_runs_maintenance_before_delivery_without_busy_retry(self):
        self.assertTrue(callable(getattr(mac_receiver,'consume_queue',None)), 'shared worker loop missing')
        queue=mock.Mock();queue.cleanup_expired.return_value={'removed':0,'failures':0}
        worker=mock.Mock();worker.once.side_effect=[False,True]
        stop=mock.Mock();stop.is_set.side_effect=[False,False,True]
        order=mock.Mock();order.attach_mock(queue.cleanup_expired,'cleanup');order.attach_mock(worker.once,'delivery')
        with mock.patch.object(mac_receiver.time,'time',side_effect=[1000,1001]):
            mac_receiver.consume_queue(queue,worker,stop)
        self.assertEqual(order.mock_calls,[mock.call.cleanup(now=1000),mock.call.delivery(),mock.call.delivery()])
        stop.wait.assert_called_once_with(0.15)

    def test_http_and_lan_launch_the_shared_maintenance_worker(self):
        import lan_receiver
        class Thread:
            def __init__(self,target,**kwargs): self.target=target
            def start(self): self.target()
            def join(self): pass
        for module,command in ((mac_receiver,['serve']),(lan_receiver,[])):
            with self.subTest(module=module.__name__),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);queue=mock.Mock(directory=root)
                queue.cleanup_expired.return_value={'removed':0,'failures':0}
                stop=mock.Mock();stop.is_set.side_effect=[False,True]
                server=mock.Mock(server_port=9443);server.serve_forever.side_effect=KeyboardInterrupt()
                process=mock.Mock();process.poll.return_value=0
                with mock.patch('sys.argv',['receiver','--data-dir',directory,*command]), \
                     mock.patch.object(module,'ROOT',root/'receiver'), \
                     mock.patch.object(module,'JobQueue',return_value=queue), \
                     mock.patch.object(module,'token_for',return_value='fixture-token'), \
                     mock.patch.object(module,'DeliveryWorker') as worker, \
                     mock.patch.object(module,'consume_queue',create=True) as consume, \
                     mock.patch.object(module.threading,'Thread',Thread), \
                     mock.patch.object(module.threading,'Event',return_value=stop), \
                     mock.patch.object(module,'process_lock') as lock:
                    lock.return_value.__enter__.return_value=None
                    if module is mac_receiver:
                        with mock.patch.object(module,'make_server',return_value=server): module.main()
                    else:
                        with mock.patch.object(module,'prepare_identity',return_value={'service':'fixture','pin':'fixture'}), \
                             mock.patch.object(module,'make_tls_server',return_value=server), \
                             mock.patch.object(module.subprocess,'Popen',return_value=process): module.main()
                    consume.assert_called_once_with(queue,worker.return_value,mock.ANY)

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.old=self.root/'repo'/'receiver-data';self.dest=self.root/'support'/'Codex Drop'
        self.queue=JobQueue(self.old)
    def test_migrates_same_identity_and_absolute_batch_paths_once(self):
        key=str(uuid.uuid4());self.queue.create_batch(key,1);self.queue.upload_batch_image(key,0,PNG)
        for name,data in [('http-token',b'test secret'),('tls-key.pem',b'key'),('tls-cert.pem',b'cert'),('lan-identity.json',b'identity'),('codex-drop.log',b'log')]:
            (self.old/name).write_bytes(data)
        before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in self.old.iterdir() if p.suffix=='.pem' or p.name=='http-token'}
        prepare_storage(self.old,self.dest)
        self.assertFalse(self.old.exists());self.assertEqual(prepare_storage(self.old,self.dest),self.dest.resolve())
        q=JobQueue(self.dest);self.assertEqual(q.commit_batch(key)['state'],'queued')
        with q.connect() as db: self.assertTrue(db.execute('SELECT path FROM batch_images').fetchone()[0].startswith(str(self.dest.resolve())))
        self.assertEqual(before,{n:hashlib.sha256((self.dest/n).read_bytes()).hexdigest() for n in before})
    def test_new_storage_is_private_without_legacy_or_new_credentials(self):
        fresh=self.root/'uncreated-legacy'
        prepare_storage(fresh,self.dest)
        self.assertEqual(self.dest.stat().st_mode & 0o777,0o700)
        self.assertFalse((self.dest/'http-token').exists())

    def test_destination_symlink_is_rejected(self):
        self.dest.parent.mkdir(parents=True)
        self.dest.symlink_to(self.old,target_is_directory=True)
        with self.assertRaises(RuntimeError): prepare_storage(self.old,self.dest)
        self.assertTrue((self.old/'queue.sqlite3').exists())

    def test_completed_storage_preparation_does_not_stop_or_lock_active_receiver(self):
        prepare_storage(self.old,self.dest)
        with (self.dest/'receiver.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(prepare_storage(self.old,self.dest),self.dest.resolve())

    def test_running_legacy_receiver_refuses_without_changes(self):
        with (self.old/'receiver.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(RuntimeError): prepare_storage(self.old,self.dest)
        self.assertTrue(self.old.exists());self.assertFalse(self.dest.exists())
    def test_conflicting_destination_or_symlink_refuses(self):
        self.dest.mkdir(parents=True);(self.dest/'http-token').write_text('different identity')
        with self.assertRaises(RuntimeError): prepare_storage(self.old,self.dest)
        self.assertTrue((self.old/'queue.sqlite3').exists())
    def test_resumes_after_atomic_move_before_path_rewrite(self):
        key=str(uuid.uuid4());self.queue.enqueue(key,PNG)
        self.dest.parent.mkdir(parents=True)
        (self.old/'.storage-migration.json').write_text(json.dumps({'version':1,'source':str(self.old.resolve()),'destination':str(self.dest.resolve())}))
        os.rename(self.old,self.dest)
        prepare_storage(self.old,self.dest)
        q=JobQueue(self.dest)
        with q.connect() as db: self.assertEqual(db.execute('SELECT image FROM jobs').fetchone()[0],str(self.dest.resolve()/'images'/f'{key}.png'))
    def test_rejects_symlink_inside_legacy(self):
        (self.old/'link').symlink_to(self.root)
        with self.assertRaises(RuntimeError): prepare_storage(self.old,self.dest)
        self.assertTrue(self.old.exists())

if __name__=='__main__': unittest.main()
