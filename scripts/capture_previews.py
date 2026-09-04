"""Capture the actual dashboard with synthetic data; no user configuration is read."""
import sys, json, threading, time
from pathlib import Path
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
sys.path.insert(0,str(Path('.verify/playwright').resolve()))
from playwright.sync_api import sync_playwright
DAY=int(time.time()//86400)
NAMES=['oc/muse-spark-1.3-contributor-free','oc/deepseek-v4-flash-free','kilo/qwen3-coder:free']
MODELS=[]
for idx,name in enumerate(NAMES):
 days=[dict(day=DAY-i,input=int((7-i)*83000/(idx+1)),output=int((7-i)*17000/(idx+1)),cached=int((7-i)*42000/(idx+1)),requests=(7-i)*14) for i in range(7)]
 MODELS.append(dict(model=name,input=sum(x['input'] for x in days),output=sum(x['output'] for x in days),cached=sum(x['cached'] for x in days),requests=sum(x['requests'] for x in days),days=days))
days=[dict(day=DAY-i,**{key:sum(m['days'][i][src] for m in MODELS) for key,src in [('in','input'),('out','output'),('cached','cached'),('requests','requests')]}) for i in range(7)]
providers=[dict(index=i,display_name=n,prefix=pre,base_url=url,description=desc,note='',site_url=url.split('/v1')[0],use_free_proxy=False,key_count=1,healthy_keys=1,keys=[dict(index=0,id='••••demo',state='Active',enabled=True)],headers=[]) for i,(n,pre,url,desc) in enumerate([('OpenCode Zen','oc/','https://opencode.ai/zen/v1/','Free models through OpenCode Zen.'),('Kilo Code','kilo/','https://api.kilo.ai/api/gateway/','Coding models through Kilo.'),('OpenRouter','or/','https://openrouter.ai/api/v1/','Choose from free community models.'),('NVIDIA NIM','nv/','https://integrate.api.nvidia.com/v1/','Developer access to open models.'),('b.ai','bai/','https://api.b.ai/v1/','Open models for everyday tasks.'),('Custom provider','custom/','https://example.com/v1/','Connect an OpenAI-compatible API.')])]
FIXTURES={
 '/api/status':dict(running=True,port=8080,bound_port=8080,pool_tracked=0,pool_working=0,in_flight=0,total_served=1842,providers=6,total_keys=6,healthy_keys=6,avg_latency_ms=824,total_errors=0,total_failovers=3,proxies_alive=0),
 '/api/usage':dict(total_in=sum(m['input'] for m in MODELS),total_out=sum(m['output'] for m in MODELS),total_cached=sum(m['cached'] for m in MODELS),total_requests=1176,models=MODELS,days=days),
 '/api/providers':dict(providers=providers),
 '/api/models':dict(free_mode=False,hide_paid=True,providers=[dict(index=0,display_name='OpenCode Zen',prefix='oc/',models=[dict(index=i,id=n,upstream_id=n.split('/',1)[1],context_window=256000,enabled=True,is_free=True,reasoning=True,reasoning_levels='low,medium,high,xhigh,max') for i,n in enumerate(NAMES[:2])])]),
 '/api/settings':dict(port=8080,auto_start=True,cooldown_secs=60,timeout_ms=120000,free_mode=False,hide_paid=True),
 '/api/logs':dict(logs=[dict(level='info',msg='Proxy ready on 127.0.0.1:8080'),dict(level='info',msg='Model library synced · 54 enabled'),dict(level='info',msg='Kimi Code configuration is up to date')],count=3),
 '/api/quick-adds/kimi':dict(path='~/.kimi-code/config.toml',token='preview'),
 '/api/update':dict(current='0.1.0',available=False,phase='idle',version='',message=''),
}
class Preview(SimpleHTTPRequestHandler):
 def __init__(self,*args,**kw):super().__init__(*args,directory=str(Path('src/web').resolve()),**kw)
 def log_message(self,*a):pass
 def do_GET(self):
  if self.path.startswith('/api/'):
   raw=json.dumps(FIXTURES.get('/api/logs' if self.path.startswith('/api/logs') else self.path,{})).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(raw)
  else:super().do_GET()
server=ThreadingHTTPServer(('127.0.0.1',0),Preview);threading.Thread(target=server.serve_forever,daemon=True).start()
Path('docs/images').mkdir(parents=True,exist_ok=True)
with sync_playwright() as p:
 browser=p.chromium.launch();page=browser.new_page(viewport={'width':1440,'height':900},device_scale_factor=1,locale='en-US')
 errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
 for view in ['dashboard','providers','models','quick-adds','settings']:
  page.goto(f'http://127.0.0.1:{server.server_port}/#/{view}');page.wait_for_timeout(400)
  print(view,page.evaluate('({width:innerWidth,height:innerHeight,scroll:document.documentElement.scrollHeight,overflow:document.documentElement.scrollWidth>innerWidth})'))
  page.screenshot(path=f'docs/images/{"overview" if view=="dashboard" else view}.png',full_page=True)
 for w,h in [(1366,768),(1280,720),(1920,1080),(390,844)]:
  page.set_viewport_size({'width':w,'height':h});page.goto(f'http://127.0.0.1:{server.server_port}/#/dashboard');page.wait_for_timeout(250)
  metrics=page.evaluate('({scroll:document.documentElement.scrollHeight,overflow:document.documentElement.scrollWidth>innerWidth})');print(w,h,metrics)
  assert not metrics['overflow']
  if w>=1000:assert metrics['scroll']<=h,metrics
 assert not errors,errors
 browser.close()
server.shutdown()
print('PASS viewport layouts, zero horizontal overflow, desktop overview fits without page scrolling, no JavaScript errors')
