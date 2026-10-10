import json,os,socket,struct,subprocess,time,tempfile
from pathlib import Path
root=Path(os.environ['DSB_TEST_BUILD']).resolve()
packet=struct.Struct('<II16sIIdff64s'); token=bytes.fromhex('12'*16)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',0));s.settimeout(1)
env=dict(os.environ,DSB_PORT=str(s.getsockname()[1]),DSB_TOKEN=token.hex(),DSB_RAW='1',DYLD_INSERT_LIBRARIES=str(root/'bridge.dylib'))
for arch in ('arm64','x86_64'):
 subprocess.run(['lipo',str(root/'audio-test'),'-thin',arch,'-output',str(root/('audio-test-'+arch))],check=True)
 p=subprocess.run([str(root/('audio-test-'+arch))],env=env,capture_output=True,text=True,timeout=10);assert p.returncode==0,p.stderr+p.stdout
 levels=[]
 while True:
  try:
   v=packet.unpack(s.recv(1024));assert v[0]==0x31425344 and v[2]==token;levels.append((v[6],v[7]))
  except socket.timeout:break
 assert len(levels)>=5 and all(x in ((.125,.5),(0,0)) for x in levels),levels
 assert levels[-1]==(0,0)
 print(arch,'PASS 4-channel routing, levels, stop:',p.stdout.strip())
with tempfile.TemporaryDirectory() as tmp:
 status=Path(tmp)/'status.json'
 p=subprocess.Popen([str(root/'broker'),'--dry-run','--token',token.hex(),'--status',str(status),'--seconds','2.5'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 ready=json.loads(p.stdout.readline());addr=('127.0.0.1',ready['port'])
 def send(seq,secret=token,ago=0):
  s.sendto(packet.pack(0x31425344,1,secret,1234,seq,time.time()-978307200-ago,.3,.4,bytes(64)),addr)
 send(1);send(2,b'0'*16);send(3,ago=1);send(1)
 time.sleep(1.3);v=json.loads(status.read_text());assert v['accepted']==1 and v['dropped']==3,v
 assert v['left']==v['right']==0 and v['peakLeft']>.29,v
 out,err=p.communicate(timeout=5);assert p.returncode==0,err
 print('PASS token/replay/stale rejection and silence watchdog')
