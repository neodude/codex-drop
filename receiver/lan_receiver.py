#!/usr/bin/env python3
"""Explicitly opt-in, paired HTTPS LAN receiver. No native UI in identity/tests."""
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import ssl
import subprocess
import tempfile
import threading
import uuid

from runtime_storage import prepare_storage

from mac_receiver import ROOT, DeliveryWorker, JobQueue, make_server, native_delivery, process_lock, token_for, native_root, consume_queue


def private_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        os.fchmod(stream.fileno(), 0o600)
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    try:
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_identity(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    paths = [directory/name for name in ('tls-key.pem', 'tls-cert.pem', 'lan-identity.json')]
    for path in paths:
        if path.is_symlink(): raise ValueError('LAN identity must use regular private files')
    if any(p.exists() for p in paths) and not all(p.is_file() for p in paths):
        raise ValueError('Partial LAN identity; inspect it before re-pairing, no automatic rotation')
    key, cert, config = paths
    if not any(p.exists() for p in paths):
        with tempfile.TemporaryDirectory(dir=directory) as staging:
            staged = Path(staging)
            subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','825',
                            '-subj','/CN=CodexShot LAN receiver','-keyout',str(staged/'key.pem'),'-out',str(staged/'cert.pem')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            der=ssl.PEM_cert_to_DER_cert((staged/'cert.pem').read_text())
            data={'service':'CodexShot-'+str(uuid.uuid4()),'pin':hashlib.sha256(der).hexdigest()}
            private_write(key, (staged/'key.pem').read_bytes())
            private_write(cert, (staged/'cert.pem').read_bytes())
            private_write(config, json.dumps(data).encode())
    data=json.loads(config.read_text())
    if re.fullmatch(r'CodexShot-[0-9a-f-]{36}', data.get('service','')) is None:
        raise ValueError('Invalid LAN service identity')
    pin=hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    if not secrets.compare_digest(data.get('pin',''), pin):
        raise ValueError('Certificate identity changed; refusing automatic re-pairing')
    for path in paths:
        if path.stat().st_mode & 0o077: raise ValueError('LAN identity files must be private')
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key) # Refuse an invalid/mismatched private key.
    return data


def pairing_payload(identity, token):
    data=json.dumps({'v':1,'service':identity['service'],'pin':identity['pin'],'token':token},separators=(',',':')).encode()
    return 'codexshot://pair?data='+base64.urlsafe_b64encode(data).decode().rstrip('=')


def make_tls_server(queue, token, directory, port=9443, bind_host='0.0.0.0'):
    server=make_server(queue, token, port, bind_host=bind_host, persistent_connections=True)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(directory/'tls-cert.pem', directory/'tls-key.pem')
    # Handshake in the request thread, not accept(): a stalled LAN client must
    # not freeze intake for every other connection.
    original_get=server.get_request
    def get_request():
        connection,address=original_get()
        connection.settimeout(5)
        return context.wrap_socket(connection, server_side=True, do_handshake_on_connect=False),address
    server.get_request=get_request
    return server


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir',type=Path)
    parser.add_argument('--port',type=int,default=9443)
    parser.add_argument('--show-pairing',action='store_true')
    args=parser.parse_args(); os.umask(0o077)
    data = args.data_dir if args.data_dir is not None else prepare_storage(ROOT.parent / "receiver-data")
    queue=JobQueue(data)
    if (ROOT.parent/'.receiver-paused').exists(): raise ValueError('Receiver is paused')
    def interrupt(*_): raise KeyboardInterrupt
    def stop_process(process):
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
    try:
        with contextlib.ExitStack() as cleanup:
            for signum in (signal.SIGTERM, signal.SIGHUP):
                previous = signal.signal(signum, interrupt)
                cleanup.callback(signal.signal, signum, previous)
            cleanup.enter_context(process_lock(queue))
            queue.recover(pause_queued=True)
            identity=prepare_identity(queue.directory); token=token_for(queue.directory)
            server=make_tls_server(queue, token, queue.directory, args.port)
            cleanup.callback(server.server_close)
            advertiser=subprocess.Popen(['/usr/bin/dns-sd','-R',identity['service'],'_codexshot._tcp.','local.',str(server.server_port)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            cleanup.callback(stop_process, advertiser)
            path=queue.directory/'pairing-code.txt'
            # The menu can open this private QR at any time while the server runs.
            path.unlink(missing_ok=True)
            cleanup.callback(path.unlink, missing_ok=True)
            private_write(path, pairing_payload(identity,token).encode())
            if args.show_pairing:
                pairing=subprocess.Popen([str(native_root()/'ReceiverPairing'),str(path)])
                cleanup.callback(stop_process, pairing)
            stop=threading.Event(); worker=DeliveryWorker(queue,native_delivery,max_queue_age=3)
            def consume():
                consume_queue(queue, worker, stop)
            thread=threading.Thread(target=consume,daemon=True); thread.start()
            def stop_worker():
                stop.set(); thread.join() # Native delivery has its own bounded timeout and clipboard cleanup.
            cleanup.callback(stop_worker)
            print(f'Paired HTTPS receiver listening on port {server.server_port}. Use the same Wi-Fi. Ctrl-C stops it.',flush=True)
            print('Sharing brings Codex forward and attaches to its last active thread. Pairing never sends a message.',flush=True)
            server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__=='__main__':
    try: main()
    except (OSError,ValueError,subprocess.SubprocessError):
        raise SystemExit('LAN receiver could not start; inspect local identity/port/permissions. No credentials were printed.')
