#!/usr/bin/env python3
"""Exercise the actual Swift pinning delegate over isolated loopback HTTPS."""
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
from lan_receiver import make_tls_server, pairing_payload, prepare_identity
from mac_receiver import JobQueue

root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='codexshot-client-checks-') as folder:
    directory=Path(folder); queue=JobQueue(directory)
    identity=prepare_identity(directory); token=secrets.token_urlsafe(32)
    server=make_tls_server(queue,token,directory,0,'127.0.0.1')
    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    code=pairing_payload(identity,token)
    config=directory/'client.json'
    config.write_text(json.dumps({'code':code,'url':f'https://127.0.0.1:{server.server_port}'})); config.chmod(0o600)
    try:
        result=subprocess.run([str(root/'.codex-artifacts/checks/iphone-client-checks'),str(config)],capture_output=True,text=True,timeout=25)
        print(result.stdout.replace(token,'[redacted]').replace(code,'[redacted]'),end='')
        if result.returncode:
            log=result.stderr.replace(token,'[redacted]').replace(code,'[redacted]')
            (root/'.codex-artifacts/checks/client-failure.log').write_text(log)
            raise SystemExit(f'Swift client checks failed ({result.returncode}); redacted diagnostic saved')
        assert not queue.list(), 'Client checks must not submit images'
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
