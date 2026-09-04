"""Quick-add API integration tests. Uses a disposable Kimi home; never edits user config."""
import json, os, subprocess, tempfile, time, tomllib
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
import socket
binary=Path('.verify/design-build/bin/freepro-gui.exe').resolve()
with socket.socket() as s:
 s.bind(('127.0.0.1',0));port=s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='freepro-quickadd-') as tmp:
 root=Path(tmp);(root/'freepro').mkdir();home=root/'.kimi-code';home.mkdir();config=home/'config.toml'
 models=[dict(id='test/muse-free',upstream_id='muse-free',provider_name='Test',provider_prefix='test/',context_window=200000,enabled=True,free=True),dict(id='test/disabled',upstream_id='disabled',provider_name='Test',provider_prefix='test/',enabled=False),dict(id='test/paid',upstream_id='paid',provider_name='Test',provider_prefix='test/',enabled=True,free=False)]
 (root/'freepro/freepro_config.json').write_text(json.dumps(dict(port=port,hide_paid=True,providers=[dict(display_name='Test',base_url='http://127.0.0.1:9/v1',prefix='test/',description='Fixture',keys=[],headers=[],models=models)])),encoding='utf-8')
 original='''# Preserve this comment
[model]
name = "other/model"
[providers.other]
type = "openai"
api_key = "test-private"
base_url = "https://example.invalid/v1"
[models."other/model"]
provider = "other"
model = "model"
capabilities = [
 "tool_use", # comment
]
[custom]
prompt = ''' + "'''\n[providers.freepro]\nthis is text\n'''\n"
 config.write_text(original,encoding='utf-8');original=config.read_bytes()
 def request(path,body=None):
  req=Request(f'http://127.0.0.1:{port}'+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json'})
  try:
   with urlopen(req,timeout=2) as r:return r.status,r.read()
  except HTTPError as e:return e.code,e.read()
 with (root/'log').open('w') as log:
  p=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=log,stderr=log,env=dict(os.environ,APPDATA=tmp,USERPROFILE=tmp,HOME=tmp,FREEPRO_NO_BROWSER='1'),creationflags=subprocess.CREATE_NO_WINDOW)
  try:
   for _ in range(100):
    try:request('/api/status');break
    except OSError:time.sleep(.1)
   code,raw=request('/api/quick-adds/kimi');assert code==200,raw
   status=json.loads(raw);assert Path(status['path'])==config
   token={'token':status['token']}
   assert request('/api/quick-adds/kimi',{'token':'wrong'})[0]==400
   assert config.read_bytes()==original
   code,raw=request('/api/quick-adds/kimi',token);assert code==200,raw
   result=json.loads(raw);assert result['added']>=1,result
   parsed=tomllib.loads(config.read_text(encoding='utf-8'));assert parsed['model']['name']=='other/model'
   assert parsed['custom']['prompt']=='[providers.freepro]\nthis is text\n'
   assert parsed['providers']['other']['api_key']=='test-private'
   assert parsed['providers']['freepro']['base_url']==f'http://127.0.0.1:{port}/v1'
   model=parsed['models']['freepro/test/muse-free'];assert model['support_efforts']==['low','medium','high','xhigh','max']
   assert model['max_context_size']==200000
   assert (home/'config.toml.freepro.bak').read_bytes()==original
   assert 'freepro/test/disabled' not in parsed['models'] and 'freepro/test/paid' not in parsed['models']
   before=config.read_bytes();mtime=config.stat().st_mtime_ns
   code,raw=request('/api/quick-adds/kimi',token);assert code==200 and not json.loads(raw)['changed'],raw
   assert config.read_bytes()==before and config.stat().st_mtime_ns==mtime
   changed=config.read_text(encoding='utf-8').replace('200000','1000').replace('api_key = "freepro-local"','api_key = "keep-local-key"').replace('provider = "freepro"','max_completion_tokens = 1234\nprovider = "freepro"')
   config.write_text(changed,encoding='utf-8')
   code,raw=request('/api/quick-adds/kimi',token);assert code==200 and json.loads(raw)['updated']==1,raw
   parsed=tomllib.loads(config.read_text(encoding='utf-8'));assert parsed['models']['freepro/test/muse-free']['max_completion_tokens']==1234
   assert parsed['providers']['freepro']['api_key']=='keep-local-key'
   for unsafe in ['[providers]\nfreepro = {type="openai"}\n','providers.freepro.type = "openai"\n','[providers.freepro]\napi_key="unfinished\n','[providers.freepro]\ntype="openai"\n[providers.freepro]\ntype="openai"\n','[[providers.freepro]]\ntype="openai"\n']:
    config.write_text(unsafe,encoding='utf-8');before=config.read_bytes()
    code,raw=request('/api/quick-adds/kimi',token);assert code==400,raw
    assert config.read_bytes()==before
   config.unlink();home.joinpath('config.toml.freepro.bak').unlink();home.rmdir()
   code,raw=request('/api/quick-adds/kimi',token);assert code==200,raw
   assert tomllib.loads(config.read_text(encoding='utf-8'))['providers']['freepro']['type']=='openai'
   code,raw=request('/kimi-logo.png');assert code==200 and raw.startswith(b'\x89PNG')
   code,raw=request('/');assert b'data-view="quick-adds"' in raw and b'id="proxy-pill"' not in raw and b'class="rail-bottom"' not in raw
   assert json.loads(request('/api/status')[1])['running']
   print('PASS add, update, idempotence, backup, default path, selected model/settings preservation, reasoning levels, filters, token checks, unsafe TOML refusal, missing file/directory creation, logo and dashboard')
  finally:
   try:p.communicate(b'quit\n',timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
