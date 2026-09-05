"""Opt-in live benchmark. Uses an isolated profile; never edits the real config."""
import argparse
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true', help='authorize real provider requests')
parser.add_argument('--binary', required=True)
parser.add_argument('--config', required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--requests', type=int, default=100)
parser.add_argument('--concurrency', type=int, default=100)
parser.add_argument('--timeout-ms', type=int, default=120000)
parser.add_argument('--ready', type=int, default=128)
args = parser.parse_args()
if not args.live:
    parser.error('--live is required: this test sends real model requests')
if not 1 <= args.concurrency <= args.requests <= 1000:
    parser.error('require 1 <= concurrency <= requests <= 1000')

original = json.loads(Path(args.config).read_text(encoding='utf-8'))
provider = next(p for p in original['providers'] if args.model.startswith(p['prefix']))
provider['use_free_proxy'] = True
binary = Path(args.binary).resolve()

with tempfile.TemporaryDirectory(prefix='freepro-live-load-') as tmp:
    root = Path(tmp)
    config_dir = root / 'freepro'
    # Windows/Linux profile location; macOS uses Application Support.
    import sys
    if sys.platform == 'darwin':
        config_dir = root / 'Library/Application Support/freepro'
    config_dir.mkdir(parents=True)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    (config_dir / 'freepro_config.json').write_text(json.dumps({
        'port': port, 'timeout_ms': args.timeout_ms, 'providers': [provider],
    }), encoding='utf-8')
    env = dict(os.environ, APPDATA=tmp, USERPROFILE=tmp, HOME=tmp,
               XDG_CONFIG_HOME=tmp, FREEPRO_NO_BROWSER='1')
    with (root / 'server.log').open('w') as log:
        process = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE,
                                   stdout=log, stderr=log,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        def status():
            with urlopen(f'http://127.0.0.1:{port}/api/status', timeout=5) as response:
                return json.load(response)

        def capacity():
            state = status()
            return {k: state.get(k) for k in ('pool_ready', 'pool_busy', 'pool_waiting',
                    'pool_blocked', 'pool_proven_ready', 'pool_proven_busy')}

        try:
            for _ in range(100):
                try:
                    status()
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('isolated server failed to start')
            for _ in range(120):
                if status()['pool_ready'] >= args.ready:
                    break
                time.sleep(1)
            print(json.dumps({'before': capacity(), 'requests': args.requests,
                              'concurrency': args.concurrency,
                              'timeout_ms': args.timeout_ms}), flush=True)
            barrier = threading.Barrier(args.concurrency)
            body = json.dumps({'model': args.model, 'messages': [
                {'role': 'user', 'content': 'Reply with just OK.'}],
                'reasoning_effort': 'low', 'max_tokens': 1024, 'stream': False}).encode()

            def call(index):
                if index < args.concurrency:
                    barrier.wait(timeout=15)
                started = time.monotonic()
                try:
                    request = Request(f'http://127.0.0.1:{port}/v1/chat/completions',
                                      data=body, headers={'Content-Type': 'application/json'})
                    with urlopen(request, timeout=args.timeout_ms / 1000 + 15) as response:
                        answer = json.load(response)
                        content = answer.get('choices', [{}])[0].get('message', {}).get('content')
                        code, nonempty = response.status, bool(content)
                except HTTPError as error:
                    error.close()
                    code, nonempty = error.code, False
                except (OSError, ValueError):
                    code, nonempty = 'transport_error', False
                return code, round(time.monotonic() - started, 3), nonempty

            started = time.monotonic()
            with ThreadPoolExecutor(max_workers=args.concurrency) as workers:
                results = list(workers.map(call, range(args.requests)))
            times = sorted(r[1] for r in results)
            print(json.dumps({'statuses': dict(Counter(str(r[0]) for r in results)),
                              'nonempty_completions': sum(r[2] for r in results),
                              'seconds': round(time.monotonic() - started, 2),
                              'p50_seconds': times[len(times) // 2],
                              'p95_seconds': times[min(len(times) - 1, int(len(times) * .95))],
                              'max_seconds': times[-1], 'after': capacity()}), flush=True)
        finally:
            try:
                process.communicate(b'quit\n', timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
