"""Exercise the native updater helper in an isolated install and user profile."""
import os,sys,json,time,tempfile,subprocess,shutil,socket,hashlib
from pathlib import Path
from urllib.request import urlopen
sys.path.insert(0,str(Path('.verify/py-test').resolve()))
import psutil
binary=Path('.verify/design-build/bin/freepro-gui.exe').resolve()
with tempfile.TemporaryDirectory(prefix='freepro-update-') as tmp:
 root=Path(tmp);target=root/'freepro.exe';stage=root/'freepro.exe.update-test.exe';marker=root/'freepro.exe.update-test.exe.ready'
 shutil.copyfile(binary,stage);target.write_bytes(b'old executable fixture')
 Path(str(target)+'.previous').write_bytes(b'older backup')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 (root/'freepro').mkdir();config=root/'freepro/freepro_config.json'
 fixture=dict(port=port,usage_in=1234,usage_out=567,providers=[dict(display_name='Fixture',base_url='http://127.0.0.1:9/v1',prefix='fixture/',description='test',keys=[dict(key='only-a-test-key',enabled=True)],headers=[])])
 config.write_text(json.dumps(fixture),encoding='utf-8')
 env=dict(os.environ,APPDATA=tmp,USERPROFILE=tmp,HOME=tmp,FREEPRO_NO_BROWSER='1')
 helper_log=(root/'helper.log').open('w')
 helper=subprocess.Popen([str(stage),'--apply-update',str(target),str(marker)],env=env,stdout=helper_log,stderr=helper_log,creationflags=subprocess.CREATE_NO_WINDOW)
 try:
  time.sleep(.4);assert target.read_bytes()==b'old executable fixture','Helper installed before save signal'
  marker.write_text('saved',encoding='utf-8')
  for _ in range(30):
   try:
    with urlopen(f'http://127.0.0.1:{port}/api/status',timeout=.5) as r:status=json.load(r)
    break
   except OSError:time.sleep(.1)
  else:raise AssertionError('Updated app did not restart')
  assert status['running'] and status['port']==port
  assert target.read_bytes()==binary.read_bytes()
  assert Path(str(target)+'.previous').read_bytes()==b'old executable fixture'
  with urlopen(f'http://127.0.0.1:{port}/api/usage',timeout=5) as r:usage=json.load(r)
  assert usage['total_in']==1234 and usage['total_out']==567,usage
  with urlopen(f'http://127.0.0.1:{port}/api/providers',timeout=5) as r:providers=json.load(r)
  assert providers['providers'][0]['display_name']=='Fixture' and providers['providers'][0]['key_count']==1
  print('Restart verified; waiting for helper',flush=True)
  helper.wait(timeout=10);assert helper.returncode==0,(root/'helper.log').read_text(errors='replace')
  print('PASS helper waits for save signal; replaces binary, retains old executable, restarts GUI with same settings, keys and token usage')
 finally:
  if helper.poll() is None:helper.kill();helper.wait()
  helper_log.close()
  for process in psutil.process_iter(['pid','exe']):
   if process.info['exe'] and Path(process.info['exe'])==target:process.terminate();process.wait(timeout=10)
