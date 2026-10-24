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
