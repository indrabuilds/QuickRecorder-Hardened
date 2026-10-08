import subprocess,os,time,re,json,signal,sys
from pathlib import Path
app=sys.argv[1]
post=sys.argv[2]
root=Path(sys.argv[3])
root.mkdir(parents=True,exist_ok=True)
coordinates=root/'actual-coordinates'
results=[]
def wait_for(fn,timeout=12):
 end=time.time()+timeout
 while time.time()<end:
  result=fn()
  if result: return result
  time.sleep(.05)
 raise RuntimeError('Timed out waiting for test UI')
def phase(layout):
 log=root/(layout+'-ui.log')
 coordinates.unlink(missing_ok=True)
 env=dict(os.environ,QR_STATUSBAR_DEBUG='1',QR_TEST_LAYOUT=layout,QR_TEST_SWALLOW='1' if layout=='full' else '0',QR_TEST_COORDINATES=str(coordinates))
 with log.open('w') as out:
  process=subprocess.Popen([app],env=env,stdout=out,stderr=out)
  try:
   wait_for(lambda:coordinates.exists())
   time.sleep(1.2)
   def origin(): return [float(x) for x in coordinates.read_text().split(',')]
   def ranges(): return {k:(float(a),float(b)) for k,a,b in re.findall(r'register (stop|pause) x=([\d.]+)\.\.\.([\d.]+)',log.read_text())}
   def move(dx):
    x,y=origin();subprocess.run([post,str(x+dx),str(y+10),'move'],check=True)
   if layout=='mini': move(-5);move(34)
   wait_for(lambda:len(ranges())==2)
   def click(key):
    x,y=origin();a,b=ranges()[key]
    subprocess.run([post,str(x+(a+b)/2),str(y+10),'click'],check=True)
   expected=[]
   for _ in range(10):
    for key,action in [('stop','stop'),('pause','pause'),('pause','resume')]:
     click(key);expected.append(action)
   os.kill(process.pid,signal.SIGUSR1)
   wait_for(lambda:'reset -> generation 2' in log.read_text())
   time.sleep(.8)
   if layout=='mini':move(-5);move(34)
   wait_for(lambda:'gen=2' in log.read_text() and len(ranges())==2)
   for key,action in [('stop','stop'),('pause','pause'),('pause','resume')]:
    click(key);expected.append(action)
   time.sleep(.2)
   actual=re.findall(r'^ACTION (\S+)$',log.read_text(),re.M)
   assert actual==expected,{'layout':layout,'expected':expected,'actual':actual}
   print(f'PASS: {layout} layout: {len(actual)} exact actions across repeated clicks and a view rebuild',flush=True)
   results.append({'layout':layout,'clicks':len(actual),'actions':len(actual),'rebuildVerified':True,'swallowingView':layout=='full'})
  finally:
   process.terminate()
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:process.kill();process.wait()
phase('full');phase('mini')
(root/'ui-results.json').write_text(json.dumps({'os':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),'tests':results,'recordingCaptured':False},indent=2)+'\n')
