import json
from pathlib import Path
import tempfile
import unittest

from lan_receiver import pairing_payload, prepare_identity

class LANIdentityTests(unittest.TestCase):
    def test_identity_is_private_and_stable(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            first = prepare_identity(root)
            second = prepare_identity(root)
            self.assertEqual(first, second)
            self.assertRegex(first['pin'], r'^[0-9a-f]{64}$')
            self.assertRegex(first['service'], r'^CodexShot-[0-9a-f-]{36}$')
            self.assertEqual((root/'tls-key.pem').stat().st_mode & 0o777, 0o600)
            self.assertEqual((root/'lan-identity.json').stat().st_mode & 0o777, 0o600)
    def test_pairing_contains_only_explicit_versioned_config(self):
        import base64
        value = pairing_payload({'service':'CodexShot-test','pin':'ab'*32}, 'x'*43)
        self.assertTrue(value.startswith('codexshot://pair?data='))
        raw=value.split('data=',1)[1]
        decoded=json.loads(base64.urlsafe_b64decode(raw+'='*(-len(raw)%4)))
        self.assertEqual(decoded, {'v':1,'service':'CodexShot-test','pin':'ab'*32,'token':'x'*43})
    def test_partial_identity_is_refused_instead_of_rotated(self):
        with tempfile.TemporaryDirectory() as path:
            root=Path(path); (root/'tls-key.pem').write_text('partial')
            with self.assertRaises(ValueError): prepare_identity(root)
    def test_changed_certificate_is_refused(self):
        with tempfile.TemporaryDirectory() as path:
            root=Path(path); prepare_identity(root)
            data=json.loads((root/'lan-identity.json').read_text()); data['pin']='00'*32
            (root/'lan-identity.json').write_text(json.dumps(data))
            with self.assertRaises(ValueError): prepare_identity(root)


class LANTLSTests(unittest.TestCase):
    def setUp(self):
        import ssl, threading
        from lan_receiver import make_tls_server
        from mac_receiver import JobQueue
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.queue = JobQueue(self.root)
        self.identity = prepare_identity(self.root)
        self.token = 'test-' + 'x' * 38
        self.server = make_tls_server(self.queue, self.token, self.root, 0, '127.0.0.1')
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2); self.temp.cleanup()
    def request(self, method, path, body=None, authorized=True):
        import http.client, ssl
        context=ssl._create_unverified_context() # Test harness verifies the actual DER pin below; iPhone uses its pin delegate.
        client=http.client.HTTPSConnection('127.0.0.1',self.server.server_port,context=context,timeout=3)
        headers={'Content-Type':'image/png','X-Request-ID':'1b2db6c3-6212-4c15-9078-cf8b5697f8a7'}
        if authorized: headers['Authorization']='Bearer '+self.token
        try:
            client.connect()
            import hashlib
            self.assertEqual(hashlib.sha256(client.sock.getpeercert(binary_form=True)).hexdigest(),self.identity['pin'])
            client.request(method,path,body,headers); response=client.getresponse()
            return response.status,json.loads(response.read())
        finally: client.close()
    def test_tls_auth_and_idempotent_receipt_without_delivery(self):
        self.assertEqual(self.request('GET','/v1/jobs',authorized=False)[0],401)
        png=(Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()
        first=self.request('POST','/v1/screenshots',png)
        second=self.request('POST','/v1/screenshots',png)
        self.assertEqual((first[0],second[0]),(202,202))
        self.assertEqual(first[1]['job']['id'],second[1]['job']['id'])
        self.assertEqual(len(self.queue.list()),1)
        self.assertEqual(self.queue.list()[0]['state'],'queued')
    def test_batch_staging_and_commit_share_one_pinned_tls_socket(self):
        key='1b2db6c3-6212-4c15-9078-cf8b5697f8a7'
        png=(Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()
        client=self.tls_socket()
        steps=[('/v1/batches',b'{"count":2}','application/json'),
               (f'/v1/batches/{key}/images/0',png,'image/png'),
               (f'/v1/batches/{key}/images/1',png,'image/png'),
               (f'/v1/batches/{key}/commit',b'{}','application/json')]
        for index,(path,body,content) in enumerate(steps):
            client.sendall(self.raw_request('POST',path,f'Content-Type: {content}\r\nContent-Length: {len(body)}\r\nX-Request-ID: {key}\r\n',body))
            response,receipt=self.read_response(client)
            self.assertEqual(response.status,202)
            self.assertEqual(receipt['job']['state'],'queued' if index==3 else 'uploading')
        client.sendall(self.raw_request(path='/v1/jobs/'+key))
        self.assertEqual(self.read_response(client)[1]['state'],'queued')

    def test_invalid_image_is_not_queued(self):
        self.assertEqual(self.request('POST','/v1/screenshots',b'x'*40)[0],400)
        self.assertEqual(self.queue.list(),[])

    def test_tls_receipt_accepts_fresh_arrival_after_uncertainty_without_replaying_history(self):
        first_key = '2773d602-fefa-4ba4-adad-725389ae2f8e'
        png = (Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()
        self.queue.enqueue(first_key, png)
        self.queue.claim()
        self.queue.finish(first_key, {'status': 'uncertain', 'pasteAttempted': True, 'reason': 'timeout'})
        status, body = self.request('POST', '/v1/screenshots', png)
        self.assertEqual(status, 202)
        self.assertTrue(body['received'])
        self.assertEqual(body['job']['state'], 'queued')
        self.assertIsNone(body['job']['result'])
        self.assertEqual(self.request('POST', '/v1/screenshots', png), (status, body))
        self.assertEqual(self.queue.claim()['id'], body['job']['id'])
        self.assertEqual(self.queue.get(first_key)['state'], 'uncertain')

    def tls_socket(self):
        import socket, ssl
        client = ssl._create_unverified_context().wrap_socket(socket.socket(), server_hostname='localhost')
        client.settimeout(3)
        client.connect(('127.0.0.1', self.server.server_port))
        self.addCleanup(client.close)
        return client

    def raw_request(self, method='GET', path='/v1/jobs', headers='', body=b'', authorized=True):
        auth = 'Authorization: Bearer '+self.token+'\r\n' if authorized else ''
        return (f'{method} {path} HTTP/1.1\r\nHost: localhost\r\n{auth}{headers}\r\n').encode()+body

    def read_response(self, client):
        import http.client
        response = http.client.HTTPResponse(client)
        response.begin()
        body = json.loads(response.read())
        return response, body

    def test_authorized_status_polls_share_one_live_tls_socket(self):
        # A raw socket cannot silently reconnect, unlike HTTPSConnection.
        client = self.tls_socket()
        for path in ['/v1/jobs', '/v1/jobs/missing', '/v1/jobs']:
            client.sendall(self.raw_request(path=path))
            response, _ = self.read_response(client)
            self.assertEqual(response.version, 11)
            self.assertEqual(response.status, 404 if path.endswith('missing') else 200)
            self.assertFalse(response.will_close)

    def test_rejected_unconsumed_bodies_close_before_a_pipelined_request(self):
        cases = [
            ('batch_duplicate_length', 'POST', '/v1/batches', 'Content-Type: application/json\r\nContent-Length: 11\r\nContent-Length: 11\r\n', b'{"count":1}', True, 400),
            ('batch_chunked', 'POST', '/v1/batches', 'Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n', b'0\r\n\r\n', True, 400),
            ('batch_commit_chunked', 'POST', '/v1/batches/1b2db6c3-6212-4c15-9078-cf8b5697f8a7/commit', 'Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n', b'0\r\n\r\n', True, 400),
            ('batch_image_duplicate_length', 'POST', '/v1/batches/1b2db6c3-6212-4c15-9078-cf8b5697f8a7/images/0', 'Content-Type: image/png\r\nContent-Length: 40\r\nContent-Length: 40\r\n', b'x'*40, True, 400),
            ('unauthorized', 'POST', '/v1/screenshots', 'Content-Length: 4\r\n', b'junk', False, 401),
            ('origin', 'POST', '/v1/screenshots', 'Origin: https://example.test\r\nContent-Length: 4\r\n', b'junk', True, 401),
            ('unknown_path', 'POST', '/missing', 'Content-Length: 4\r\n', b'junk', True, 404),
            ('missing_length', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\n', b'junk', True, 400),
            ('invalid_length', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: invalid\r\n', b'junk', True, 400),
            ('duplicate_length', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: 40\r\nContent-Length: 40\r\n', b'x'*40, True, 400),
            ('signed_length', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: +40\r\n', b'x'*40, True, 400),
            ('negative_length', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: -40\r\n', b'junk', True, 400),
            ('oversized', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: 9999999999\r\n', b'junk', True, 413),
            ('get_body', 'GET', '/v1/jobs', 'Content-Length: 4\r\n', b'junk', True, 400),
            ('get_invalid_length', 'GET', '/v1/jobs', 'Content-Length: invalid\r\n', b'junk', True, 400),
            ('get_chunked', 'GET', '/v1/jobs', 'Transfer-Encoding: chunked\r\n', b'0\r\n\r\n', True, 400),
            ('get_duplicate_length', 'GET', '/v1/jobs', 'Content-Length: 0\r\nContent-Length: 4\r\n', b'junk', True, 400),
            ('post_chunked', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nTransfer-Encoding: chunked\r\n', b'0\r\n\r\n', True, 400),
            ('ambiguous_framing', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nTransfer-Encoding: chunked\r\nContent-Length: 40\r\n', b'x'*40, True, 400),
            ('empty_transfer_encoding', 'GET', '/v1/jobs', 'Transfer-Encoding:\r\n', b'junk', True, 400),
            ('wrong_type', 'POST', '/v1/screenshots', 'Content-Type: text/plain\r\nContent-Length: 40\r\n', b'x'*40, True, 415),
            ('too_small', 'POST', '/v1/screenshots', 'Content-Type: image/png\r\nContent-Length: 4\r\n', b'junk', True, 413),
        ]
        for label, method, path, headers, body, authorized, status in cases:
            with self.subTest(label=label):
                client = self.tls_socket()
                client.sendall(self.raw_request(method, path, headers, body, authorized)+self.raw_request())
                response, _ = self.read_response(client)
                self.assertEqual(response.status, status)
                self.assertEqual(response.getheader('Connection'), 'close')
                self.assertEqual(client.recv(1), b'')
                client.close()
        self.assertEqual(self.queue.list(), [])

    def test_incomplete_body_timeout_closes_connection(self):
        self.server.RequestHandlerClass.timeout = 0.05
        client = self.tls_socket()
        client.sendall(self.raw_request('POST', '/v1/screenshots',
                       'Content-Type: image/png\r\nContent-Length: 40\r\n', b'junk'))
        response, _ = self.read_response(client)
        self.assertEqual(response.status, 400)
        self.assertEqual(response.getheader('Connection'), 'close')
        self.assertEqual(client.recv(1), b'')
        self.assertEqual(self.queue.list(), [])

    def test_upload_then_status_share_one_tls_socket(self):
        client = self.tls_socket()
        png = (Path(__file__).resolve().parent.parent/'test-image.png').read_bytes()
        key = '1b2db6c3-6212-4c15-9078-cf8b5697f8a7'
        client.sendall(self.raw_request('POST', '/v1/screenshots',
                       f'Content-Type: image/png\r\nContent-Length: {len(png)}\r\nX-Request-ID: {key}\r\n', png))
        self.assertEqual(self.read_response(client)[0].status, 202)
        client.sendall(self.raw_request(path='/v1/jobs/'+key))
        response, body = self.read_response(client)
        self.assertEqual(response.status, 200)
        self.assertEqual(body['state'], 'queued')

    def test_consumed_invalid_image_allows_following_status_poll(self):
        client = self.tls_socket()
        client.sendall(self.raw_request('POST', '/v1/screenshots',
                       'Content-Type: image/png\r\nContent-Length: 40\r\n', b'x'*40))
        self.assertEqual(self.read_response(client)[0].status, 400)
        client.sendall(self.raw_request())
        self.assertEqual(self.read_response(client)[0].status, 200)

    def test_localhost_server_keeps_http10_default(self):
        import http.client, threading
        from mac_receiver import make_server
        server = make_server(self.queue, self.token)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        try:
            client.request('GET', '/v1/jobs', headers={'Authorization': 'Bearer '+self.token})
            response = client.getresponse()
            self.assertEqual(response.version, 10)
            self.assertTrue(response.will_close)
            response.read()
        finally:
            client.close(); server.shutdown(); server.server_close(); thread.join(timeout=2)



class LANStartupCleanupTests(unittest.TestCase):
    def test_pairing_launch_failure_cleans_every_acquired_resource(self):
        from unittest.mock import patch
        import lan_receiver
        class Server:
            server_port=9443
            closed=False
            def server_close(self): self.closed=True
        class Process:
            terminated=False
            def poll(self): return None
            def terminate(self): self.terminated=True
            def wait(self,timeout=None): return 0
        with tempfile.TemporaryDirectory() as path:
            server=Server(); advertiser=Process()
            prepare_identity(Path(path))
            with patch('sys.argv',['lan_receiver','--data-dir',path,'--show-pairing']), patch.object(lan_receiver,'make_tls_server',return_value=server), patch.object(lan_receiver.subprocess,'Popen',side_effect=[advertiser,OSError('fixture pairing launch failure')]):
                with self.assertRaises(OSError): lan_receiver.main()
            self.assertTrue(server.closed, 'TLS listener leaked on startup failure')
            self.assertTrue(advertiser.terminated, 'Bonjour advertiser leaked on startup failure')
            self.assertFalse((Path(path)/'pairing-code.txt').exists(), 'Private QR secret leaked on startup failure')

    def test_private_pairing_file_exists_without_window_and_is_removed_on_stop(self):
        from unittest.mock import patch
        import lan_receiver
        class Server:
            server_port=9443
            closed=False
            def server_close(self): self.closed=True
            def serve_forever(inner):
                pairing_path=Path(path)/'pairing-code.txt'
                self.assertEqual(pairing_path.stat().st_mode & 0o777, 0o600)
                self.assertTrue(pairing_path.read_text().startswith('codexshot://pair?data='))
                raise KeyboardInterrupt()
        class Process:
            terminated=False
            def poll(self): return None
            def terminate(self): self.terminated=True
            def wait(self, timeout=None): return 0
        with tempfile.TemporaryDirectory() as path:
            prepare_identity(Path(path)); server=Server(); advertiser=Process()
            with patch('sys.argv',['lan_receiver','--data-dir',path]), patch.object(lan_receiver,'make_tls_server',return_value=server), patch.object(lan_receiver.subprocess,'Popen',return_value=advertiser) as launch:
                lan_receiver.main()
            self.assertEqual(launch.call_count,1)
            self.assertTrue(server.closed and advertiser.terminated)
            self.assertFalse((Path(path)/'pairing-code.txt').exists())


class LANSignalCleanupTests(unittest.TestCase):
    def test_termination_signals_clean_resources_and_restore_handlers(self):
        from unittest.mock import patch
        import lan_receiver, signal
        class Server:
            server_port=9443
            closed=False
            def __init__(self, signum): self.signum=signum
            def server_close(self): self.closed=True
            def serve_forever(self): signal.getsignal(self.signum)(self.signum,None)
        class Process:
            terminated=False
            def poll(self): return None
            def terminate(self): self.terminated=True
            def wait(self,timeout=None): return 0
        for signum in (signal.SIGTERM,signal.SIGHUP):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as path:
                prepare_identity(Path(path)); previous=signal.getsignal(signum)
                server=Server(signum); advertiser=Process(); pairing=Process()
                with patch('sys.argv',['lan_receiver','--data-dir',path,'--show-pairing']), patch.object(lan_receiver,'make_tls_server',return_value=server), patch.object(lan_receiver.subprocess,'Popen',side_effect=[advertiser,pairing]):
                    lan_receiver.main()
                self.assertTrue(server.closed)
                self.assertTrue(advertiser.terminated and pairing.terminated)
                self.assertFalse((Path(path)/'pairing-code.txt').exists())
                self.assertEqual(signal.getsignal(signum),previous)

if __name__=='__main__': unittest.main()
