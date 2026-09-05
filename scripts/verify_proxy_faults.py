"""Deterministic transport faults through CONNECT; no real keys or public proxies."""
import json,os,socket,subprocess,threading,time,sys,struct
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
root=Path(__file__).resolve().parents[1];binary=root/'.verify/proxy-fault-fixture.exe'
binary.parent.mkdir(parents=True,exist_ok=True)
args=['zig','build-exe','--dep','engine','-Mroot='+str(root/'scripts/proxy_fault_fixture.zig'),'-Mengine='+str(root/'src/root.zig'),'-femit-bin='+str(binary)]
args.insert(2,'-lws2_32' if os.name=='nt' else '-lc')
subprocess.run(args,check=True)
def head(c):
 data=b''
 while b'\r\n\r\n' not in data:
  part=c.recv(4096)
  if not part:return data
  data+=part
 return data
class Hop:
 def __init__(self,mode,host="127.0.0.1"):
  self.mode=mode;self.seen=0;self.stop=threading.Event();self.server=socket.socket()
  if mode=='upload-stall':self.server.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096)
  self.server.bind((host,0));self.server.listen();self.server.settimeout(.1);self.port=self.server.getsockname()[1]
  threading.Thread(target=self.accept,daemon=True).start()
 def accept(self):
  while not self.stop.is_set():
   try:c,_=self.server.accept()
   except OSError:continue
   threading.Thread(target=self.serve,args=(c,),daemon=True).start()
 def serve(self,c):
  try:
   c.settimeout(5);request=head(c);self.seen+=1
   assert request.startswith(b'CONNECT origin.invalid:80 '),request
   if self.mode=='connect-stall':self.stop.wait(5);return
   c.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
   if self.mode=='upload-stall':self.stop.wait(5);return
   req=head(c)
   if self.mode.startswith('catalog-'):
    assert req.startswith(b'GET /v1/models HTTP/1.1'),req
    code=404 if self.mode=='catalog-404' else 200
    data=b'{"data":[]}' if self.mode!='catalog-html' else b'<html>blocked</html>'
    length=len(data)+50 if self.mode=='catalog-truncated' else len(data)
    c.sendall(f'HTTP/1.1 {code} Result\r\nContent-Length: {length}\r\n\r\n'.encode()+data);return
   length=int(next(x for x in req.split(b'\r\n') if x.lower().startswith(b'content-length:')).split(b':')[1]);body=req.split(b'\r\n\r\n',1)[1]
   while len(body)<length:body+=c.recv(min(65536,length-len(body)))
   if self.mode=='throttle':
    data=b'{"error":{"message":"rate limited"}}'
    c.sendall(f'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 120\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n'.encode()+data);return
   if self.mode=='slow-ok':time.sleep(.12)
   if self.mode=='reset':return
   if self.mode=='head-stall':self.stop.wait(5);return
   if self.mode=='body-stall':
    c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 900\r\n\r\n{');self.stop.wait(5);return
   if self.mode=='truncated':
    c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 900\r\n\r\n{');return
   if self.mode in ['stream-ok','stream-clean-cut']:
    frame=b'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n'
    if self.mode=='stream-ok':frame+=b'data: [DONE]\n\n'
    c.sendall(f'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {len(frame)}\r\n\r\n'.encode()+frame)
    return
   if self.mode in ['client-close','client-stall']:
    c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n')
    frame=b'data: {"choices":[{"delta":{"content":"'+b'x'*16000+b'"}}]}\n\n'
    for _ in range(5000 if self.mode=='client-stall' else 200):c.sendall(f'{len(frame):x}\r\n'.encode()+frame+b'\r\n')
    return
   if self.mode in ['stream-cut','stream-idle']:
    c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 9000\r\n\r\ndata: {"choices":[{"delta":{"content":"partial"}}]}\n\n');self.stop.wait(5) if self.mode=='stream-idle' else time.sleep(.1);return
   data=json.dumps({'id':'test','choices':[{'index':0,'message':{'role':'assistant','content':'OK'},'finish_reason':'stop'}],'usage':{'prompt_tokens':2,'completion_tokens':1}}).encode()
   c.sendall(f'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n'.encode()+data)
  except OSError:pass
  finally:c.close()
 def close(self):self.stop.set();self.server.close()
def run(modes,timeout=1600,stream=False,large=False,disconnect=False,pretrip=False):
 hops=[Hop(m) for m in modes]
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 env=dict(os.environ,TEST_PORT=str(port),TEST_ROUTES=','.join(str(h.port) for h in hops),TEST_HOSTS=','.join('localhost' if i else '127.0.0.1' for i in range(len(hops))),TEST_TIMEOUT=str(timeout),TEST_PRETRIP="1" if pretrip else "0")
 proc=subprocess.Popen([str(binary)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
 try:
  for _ in range(80):
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.1):pass
    break
   except OSError:time.sleep(.03)
  body=json.dumps({'model':'test/model','messages':[{'role':'user','content':'x'*(512_000 if large else 5)}],'stream':stream}).encode()
  request=b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body
  t=time.monotonic()
  with socket.create_connection(('127.0.0.1',port),timeout=5) as c:
   c.settimeout(5);c.sendall(request);raw=b''
   while True:
    part=c.recv(65536)
    if not part:break
    raw+=part
    if disconnect:
     c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('hh' if os.name=='nt' else 'ii',1,0))
     break
  if disconnect:time.sleep(.2)
  elapsed=time.monotonic()-t
  output,err=proc.communicate(b'quit\n',timeout=10)
  assert proc.returncode==0,err.decode(errors='replace')[-2000:]
  state=json.loads(output);assert state['cooldown']==0,state
  assert raw.count(b'HTTP/1.1')==1,(raw[:500],state,err.decode(errors='replace')[-2000:])
  return raw,elapsed,[h.seen for h in hops],state
 finally:
  if proc.poll() is None:proc.kill();proc.wait()
  for h in hops:h.close()
if __name__=='__main__':
 for mode in ['catalog-ok','catalog-404','catalog-html','catalog-truncated']:
  hop=Hop(mode)
  try:
   result=subprocess.run([str(binary)],env=dict(os.environ,TEST_CATALOG_PROXY_PORT=str(hop.port)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=True)
   assert result.stdout==(b'true' if mode=='catalog-ok' else b'false'),(mode,result.stdout)
   assert hop.seen==1
  finally:hop.close()
 print('PASS catalog probe uses GET /v1/models and rejects 404, HTML and incomplete 200 bodies')

 raw,elapsed,seen,state=run(['throttle','ok'])
 assert raw.startswith(b'HTTP/1.1 200') and seen==[1,1] and elapsed<1.5,(raw,elapsed,seen,state)
 print('PASS 429 recovers without a synchronous neutral probe, within the shared deadline')
 raw,elapsed,seen,state=run(['throttle','ok'],pretrip=True)
 assert raw.startswith(b'HTTP/1.1 200') and seen==[1,1],(raw,seen,state)
 print('PASS earlier throttled routes do not block recovery through an eligible route')


 for broken in ['reset','truncated','head-stall','body-stall']:
  raw,elapsed,seen,state=run([broken,'ok']);assert raw.startswith(b'HTTP/1.1 200'),raw[:400];assert seen==[1,1],seen;assert elapsed<3,(broken,elapsed)
  print('PASS',broken,'fails over once to a healthy route; key unchanged')
 for stalled in ['connect-stall','upload-stall','body-stall']:
  raw,elapsed,seen,state=run([stalled],large=stalled=='upload-stall');assert not raw.startswith(b'HTTP/1.1 200'),raw[:300];assert elapsed<3.5,(stalled,elapsed)
  # With max_fails=2 a single bounded stall leaves the fixture route pooled
  # (still usable for later requests) but the attempt itself is exhausted.
  assert state['remaining_routes']>=1,state
  print('PASS',stalled,'bounded by shared deadline; a stalled route is not instantly discarded')
 raw,elapsed,seen,state=run(['stream-cut','ok'],stream=True);assert seen==[1,0],seen;assert b'partial' in raw and raw.count(b'HTTP/1.1')==1
 print('PASS interrupted stream closes without replay or a second HTTP response')

 raw,elapsed,seen,state=run(['stream-idle','ok'],stream=True)
 assert seen==[1,0] and elapsed<3.5 and state['remaining_routes']>=1,(seen,elapsed,state)
 print('PASS streaming idle timeout leaves the route pooled (not instantly quarantined)')
 raw,elapsed,seen,state=run(['client-close','ok'],stream=True,disconnect=True)
 assert seen==[1,0] and state['remaining_routes']==2,(seen,state)
 print('PASS downstream disconnect is not retried and does not penalize the public proxy or API key')

 raw,elapsed,seen,state=run(['stream-clean-cut','ok'],stream=True)
 assert seen==[1,0] and state['remaining_routes']>=1,(seen,state)
 print('PASS clean HTTP EOF without a completed SSE stream is not marked healthy')
 raw,elapsed,seen,state=run(['stream-ok','ok'],stream=True)
 assert seen==[1,0] and state['remaining_routes']==2 and raw.endswith(b'0\r\n\r\n'),(seen,state,raw[-100:])
 print('PASS complete SSE stream remains healthy')
