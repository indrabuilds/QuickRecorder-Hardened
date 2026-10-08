import os,sys,subprocess,time,json,signal,re
from pathlib import Path
app,post,root=sys.argv[1],sys.argv[2],Path(sys.argv[3]);root.mkdir(parents=True,exist_ok=True)
coords=root/'coordinates';regions=root/'regions.json';log=root/'popup-ui.log'
for p in [coords,regions]:p.unlink(missing_ok=True)
def wait(fn,timeout=10):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  value=fn()
  if value:return value
  time.sleep(.05)
 raise RuntimeError('Popup test timed out')
def text():return log.read_text()
def click_region(name):
 values=json.loads(regions.read_text());x,y,w,h=values[name]
 subprocess.run([post,str(x+w/2),str(y+h/2),'click'],check=True)
def icon(mode='click',dx=18):
 x,y=map(float,coords.read_text().split(','))
 subprocess.run([post,str(x+dx),str(y+10),mode],check=True)
def shown():return text().count('popup shown main')
def closed():return text().count('popup closed')
checks=0
with log.open('w') as out:
 env=dict(os.environ,QR_STATUSBAR_DEBUG='1',QR_TEST_MODE='idle',QR_TEST_COORDINATES=str(coords),QR_TEST_REGIONS=str(regions))
 p=subprocess.Popen([app],env=env,stdout=out,stderr=out)
 try:
  wait(lambda:coords.exists() and regions.exists())
  for cycle in range(20):
   opens,closes=shown(),closed()
   icon();wait(lambda:shown()==opens+1 and 'setting' in json.loads(regions.read_text()))
   time.sleep(.2)
   assert closed()==closes,'Opening click immediately dismissed popup'
   icon('move',-4);time.sleep(.1)
   click_region('setting')
   assert closed()==closes,'Moving into/clicking popup dismissed it'
   icon();wait(lambda:closed()==closes+1)
   assert shown()==opens+1,'Icon close reopened popup'
   checks+=1
  icon();wait(lambda:shown()==21)
  click_region('nested-open');wait(lambda:'nested-setting' in json.loads(regions.read_text()))
  before=closed();click_region('nested-setting')
  assert closed()==before and 'ACTION nested-setting' in text(),'Nested interaction dismissed parent'
  checks+=1
  # Escape in the nested window dismisses the nested presentation, then the
  # parent is still usable. The parent setting click also dismisses the child.
  subprocess.run([post,'escape'],check=True)
  click_region('setting');assert closed()==before,'Nested Escape dismissed parent'
  checks+=1
  subprocess.run([post,'escape'],check=True);wait(lambda:closed()==before+1)
  checks+=1
  icon();before=closed();click_region('outside');wait(lambda:closed()==before+1)
  checks+=1
  icon();before=closed();click_region('selector');wait(lambda:closed()==before+1)
  assert 'ACTION selector-chosen' in text(),'Selector did not execute'
  checks+=1
  icon();before=closed();opens=shown();os.kill(p.pid,signal.SIGUSR1)
  wait(lambda:'status rebuild deferred' in text());time.sleep(.2)
  click_region('setting');assert closed()==before and shown()==opens,'Rebuilding anchor dismissed/reopened popup'
  checks+=1
  click_region('outside');wait(lambda:closed()==before+1);wait(lambda:'reset -> generation 2' in text())
  settings=re.findall(r'^ACTION popup-setting$',text(),re.M)
  assert len(settings)==22,(len(settings),'settings count')
  result={'checks':checks,'openCloseCycles':20,'nestedOptions':True,'escape':True,'outsideDismissal':True,'selectorTransition':True,'anchorRebuild':True,'capturedMedia':False}
  (root/'popup-ui-results.json').write_text(json.dumps(result,indent=2)+'\n')
  print('PASS:',checks,'popup lifecycle checks, including 20 open/use/close cycles',flush=True)
 finally:
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
