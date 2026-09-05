"""Sustained load and abandoned-client recovery on the same local server."""
import json,os,socket,subprocess,time
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request,urlopen
from verify_proxy_faults import Hop,binary

def start(modes,timeout):
 hops=[Hop(m) for m in modes]
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 env=dict(os.environ,TEST_PORT=str(port),TEST_ROUTES=','.join(str(h.port) for h in hops),TEST_TIMEOUT=str(timeout))
 proc=subprocess.Popen([str(binary)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
 for _ in range(100):
  try:
   with urlopen(f'http://127.0.0.1:{port}/fixture/state',timeout=.2) as r:json.load(r)
   return proc,hops,port
  except OSError:time.sleep(.03)
 proc.kill();proc.wait();raise AssertionError('Fixture failed to start')

def stop(proc,hops):
 try:
  output,err=proc.communicate(b'quit\n',timeout=10)
  assert proc.returncode==0,err.decode(errors='replace')[-2000:]
  state=json.loads(output)
  assert state['cooldown']==0 and state['key_state']=='Active',state
 finally:
  if proc.poll() is None:proc.kill();proc.wait()
  for hop in hops:hop.close()

def get(port,path='/fixture/state'):
 with urlopen(f'http://127.0.0.1:{port}'+path,timeout=5) as r:return json.load(r)

def chat(port):
 body=json.dumps({'model':'test/model','messages':[{'role':'user','content':'OK'}]}).encode()
 with urlopen(Request(f'http://127.0.0.1:{port}/v1/chat/completions',data=body,headers={'Content-Type':'application/json'}),timeout=12) as r:
  assert r.status==200 and json.load(r)['choices'][0]['message']['content']=='OK'

proc,hops,port=start(['client-stall','ok'],1000)
client=socket.socket();client.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096)
try:
 client.connect(('127.0.0.1',port))
 body=b'{"model":"test/model","messages":[],"stream":true}'
 client.sendall(b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
 time.sleep(3)
 state=get(port)
 assert state['busy']==0 and state['ready']==2 and state['waiting']==0,state
 print('PASS non-reading client releases its route and worker without restart or route/key penalty',flush=True)
finally:
 client.close();stop(proc,hops)

proc,hops,port=start(['ok'],1000)
clients=[]
try:
 for _ in range(128):
  client=socket.create_connection(('127.0.0.1',port),timeout=5);client.sendall(b'POST /v1/chat/completions HTTP/1.1\r\n');clients.append(client)
 time.sleep(2)
 chat(port)
 assert get(port)['busy']==0
 print('PASS 128 incomplete inbound requests expire; normal requests recover without restart',flush=True)
finally:
 for client in clients:client.close()
 stop(proc,hops)

proc,hops,port=start(['slow-ok','slow-ok'],10000)
try:
 start_time=time.monotonic()
 for wave in range(6):
  with ThreadPoolExecutor(max_workers=64) as workers:list(workers.map(lambda _:chat(port),range(256)))
  state=get(port)
  assert state['busy']==0 and state['waiting']==0 and state['ready']==2,state
  print(f'PASS sustained wave {wave+1}/6: 256 requests, 64 agents, zero 503s; no leaked leases or waiters',flush=True)
 print(f'PASS 1536 requests over {time.monotonic()-start_time:.1f}s on one server, with the production key rotator',flush=True)
finally:stop(proc,hops)
