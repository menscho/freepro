"""A second GUI launch must not become another writer for the same config."""
import json,os,socket,subprocess,tempfile,time,sys
from pathlib import Path
from urllib.request import urlopen
binary=Path(sys.argv[1] if len(sys.argv)>1 else ('zig-out/bin/freepro-gui.exe' if os.name=='nt' else 'zig-out/bin/freepro-gui')).resolve()
with tempfile.TemporaryDirectory(prefix='freepro-instance-') as tmp:
 root=Path(tmp)
 config_dir=root/'freepro' if sys.platform!='darwin' else root/'Library/Application Support/freepro'
 config_dir.mkdir(parents=True)
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 config=config_dir/'freepro_config.json'
 config.write_text(json.dumps(dict(port=port,usage_in=123,providers=[dict(display_name='Fixture',base_url='http://127.0.0.1:9/v1',prefix='fixture/',description='test',keys=[],headers=[])])),encoding='utf-8')
 env=dict(os.environ,APPDATA=tmp,USERPROFILE=tmp,HOME=tmp,XDG_CONFIG_HOME=tmp,FREEPRO_NO_BROWSER='1')
 trace=(root/'first.log').open('w')
 first=subprocess.Popen([str(binary)],env=env,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=trace,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
 try:
  for _ in range(100):
   try:
    with urlopen(f'http://127.0.0.1:{port}/api/status',timeout=.2) as r:assert json.load(r)['running']
    break
   except OSError:time.sleep(.05)
  else:raise AssertionError((root/'first.log').read_text(errors='replace'))
  before=config.read_bytes()
  second=subprocess.run([str(binary),'--background'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  assert second.returncode==0,second.stderr.decode(errors='replace')
  assert b'already running' in second.stdout,second.stdout
  assert config.read_bytes()==before
  assert first.poll() is None
  print('PASS duplicate GUI launch exits without modifying the first instance configuration')
 finally:
  try:first.communicate(b'quit\n',timeout=10)
  except subprocess.TimeoutExpired:first.kill();first.wait()
  trace.close()
