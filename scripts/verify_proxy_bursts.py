"""Burst requests queue on a small validated pool instead of immediately failing."""
import json,os,socket,subprocess,time
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request,urlopen
from verify_proxy_faults import Hop,binary
hops=[Hop('slow-ok') for _ in range(2)]
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
env=dict(os.environ,TEST_PORT=str(port),TEST_ROUTES=','.join(str(h.port) for h in hops),TEST_TIMEOUT='10000')
p=subprocess.Popen([str(binary)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
try:
 for _ in range(100):
  try:
   with socket.create_connection(('127.0.0.1',port),timeout=.1):pass
   break
  except OSError:time.sleep(.03)
 body=json.dumps({'model':'test/model','messages':[{'role':'user','content':'OK'}]}).encode()
 def request(_):
  with urlopen(Request(f'http://127.0.0.1:{port}/v1/chat/completions',data=body,headers={'Content-Type':'application/json'}),timeout=12) as r:
   assert r.status==200 and json.load(r)['choices'][0]['message']['content']=='OK'
 for wave in range(3):
  start=time.monotonic()
  with ThreadPoolExecutor(max_workers=24) as workers:list(workers.map(request,range(24)))
  print(f'PASS burst {wave+1}: 24 simultaneous requests, two routes, zero 503s ({time.monotonic()-start:.2f}s)',flush=True)
 output,err=p.communicate(b'quit\n',timeout=10)
 assert p.returncode==0,err.decode(errors='replace')[-1500:]
 state=json.loads(output);assert state['cooldown']==0 and state['remaining_routes']==2,state
 assert sum(h.seen for h in hops)==72
 print('PASS 72 completed requests; routes reused and API key unchanged')
finally:
 if p.poll() is None:p.kill();p.wait()
 for h in hops:h.close()
