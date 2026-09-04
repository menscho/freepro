"""Verify CONNECT starts TLS and failed CONNECT never falls back to plaintext. No keys/network."""
import os,socket,subprocess,threading
from pathlib import Path
root=Path(__file__).resolve().parents[1]
binary=root/'.verify/tunnel-fixture.exe'
subprocess.run(['zig','build-exe','-lws2_32','--dep','http_client','-Mroot='+str(root/'scripts/proxy_tunnel_fixture.zig'),'-Mhttp_client='+str(root/'src/http_client.zig'),'-femit-bin='+str(binary)],check=True)
for status in [200,407]:
    observed=[]
    with socket.socket() as server:
        server.bind(('127.0.0.1',0));server.listen();server.settimeout(8)
        def serve():
            with server.accept()[0] as c:
                c.settimeout(4);data=b''
                while b'\r\n\r\n' not in data: data+=c.recv(4096)
                observed.append(data)
                c.sendall(f'HTTP/1.1 {status} Test\r\nContent-Length: 0\r\n\r\n'.encode())
                try: observed.append(c.recv(4096))
                except (OSError,TimeoutError): observed.append(b'')
        thread=threading.Thread(target=serve);thread.start()
        r=subprocess.run([str(binary)],env=dict(os.environ,TEST_PROXY_PORT=str(server.getsockname()[1])),capture_output=True,timeout=12)
        thread.join(timeout=5)
        assert r.returncode==0,r.stderr.decode(errors='replace')
        assert observed[0].startswith(b'CONNECT origin.invalid:443 '),observed
        assert b'fixture-secret' not in b''.join(observed),observed
        if status==200: assert observed[1][:1]==b'\x16',observed[1][:100]
        else:
            assert not observed[1],observed
            server.settimeout(.1)
            try: extra=server.accept();extra[0].close();raise AssertionError('CONNECT failure attempted a plaintext fallback')
            except TimeoutError: pass
        print('PASS', 'TLS ClientHello follows CONNECT without exposing credentials' if status==200 else 'failed CONNECT has no plaintext fallback')
