#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/hid/IOHIDManager.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <zlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include "protocol.h"
#include "Calibration.h"
#include "Controls.h"

// Local per-session service. Only receives packets bearing the launch token.
// --pcm selects the bounded direct PCM transport; default retains Core Haptics.
static volatile sig_atomic_t quitting;
static CHHapticEngine *engines[2];
static atomic_bool engineRunning[2];
static id<CHHapticPatternPlayer> players[2];
static float lastLevel[2]={-1,-1};
static CHHapticPattern *silentPattern;
static double playerStart;
static IOHIDDeviceRef hid;
static pthread_mutex_t outputLock=PTHREAD_MUTEX_INITIALIZER;
static uint8_t pending[47],lastSent[47];
static bool outputDirty,haveLast;
static atomic_bool workerRunning;
static atomic_uint reports,errors;
static atomic_bool stalled;
static uint8_t btSequence;
static bool dry;
static GCDualSenseGamepad *nativePad;
// Optional workaround for a live USB->BT migration producing interleaved resets.
// Off commands are delayed only briefly after an active feedback command.
// A genuine release is applied within resetGrace; effect bytes stay unchanged.
static double resetGrace,lastActive[2],releaseAt[2];
static uint8_t releaseEffect[2][11];
static unsigned suppressedResets[2];
static NSMutableArray *sentHistory;
static uint64_t ledCommands,playerCommands;
static uint32_t ledSource;
static uint8_t ledRGB[3],playerLED;
#include "PCMTransport.h"
static void stopSignal(int s){quitting=1;}
// Read readiness wakes the run loop immediately; the main loop drains and
// authenticates datagrams before rearming this source.
static void socketReady(CFFileDescriptorRef descriptor,CFOptionFlags flags,void *context){}
static void queueOutput(const uint8_t *usb){
 const uint8_t *src=usb+1;
 pthread_mutex_lock(&outputLock);
 // Merge independent valid fields, optionally defer transient trigger resets.
 double now=CFAbsoluteTimeGetCurrent();
 for(int side=0;side<2;side++){
  unsigned bit=4u<<side,offset=10+side*11;if(!(src[0]&bit))continue;
  const uint8_t *effect=src+offset;
  if(effect[0]==0x21){lastActive[side]=now;releaseAt[side]=0;}
  else if(resetGrace>0 && (effect[0]==5||effect[0]==0) && pending[offset]==0x21 && now-lastActive[side]<resetGrace){
   releaseAt[side]=lastActive[side]+resetGrace;memcpy(releaseEffect[side],effect,11);suppressedResets[side]++;continue;
  }else releaseAt[side]=0;
  pending[0]|=bit;memcpy(pending+offset,effect,11);
 }
 if(src[1]&4){pending[1]|=4;memcpy(pending+44,src+44,3);}
 if(src[1]&0x10){pending[1]|=0x10;pending[43]=src[43];}
 if(src[1]&1){pending[1]|=1;pending[8]=src[8];}
 outputDirty=pending[0]||pending[1];
 pthread_mutex_unlock(&outputLock);
 if(pcmMode)pcmNotify();
}
static void *outputWorker(void *unused){
 @autoreleasepool {
 while(atomic_load(&workerRunning)){
  uint8_t payload[47],snapshot[47];bool changed=false;
  pthread_mutex_lock(&outputLock);
  if(outputDirty){memcpy(snapshot,pending,47);outputDirty=false;changed=DSBControlDelta(snapshot,lastSent,haveLast,payload);}
  pthread_mutex_unlock(&outputLock);
  if(changed&&!atomic_load(&stalled)){
   uint8_t b[78]={0x31};b[1]=(btSequence++&15)<<4;b[2]=0x10;memcpy(b+3,payload,47);
   uint8_t seed=0xa2;uLong crc=crc32(0,&seed,1);crc=crc32(crc,b,74);for(int i=0;i<4;i++)b[74+i]=crc>>(8*i);
   double start=CFAbsoluteTimeGetCurrent();IOReturn r=dry?0:IOHIDDeviceSetReport(hid,kIOHIDReportTypeOutput,0x31,b,sizeof(b));
   atomic_fetch_add(&reports,1);if(r)atomic_fetch_add(&errors,1);
   if(r||CFAbsoluteTimeGetCurrent()-start>.25){atomic_store(&stalled,true);fprintf(stderr,"HID output stopped: error=0x%x duration=%.3f\n",r,CFAbsoluteTimeGetCurrent()-start);}
   pthread_mutex_lock(&outputLock);
   memcpy(lastSent,snapshot,47);haveLast=true;
   NSMutableArray *r2=[NSMutableArray array];for(int i=10;i<21;i++)[r2 addObject:@(payload[i])];
   [sentHistory addObject:@{@"at":@([[NSDate date] timeIntervalSince1970]),@"r2":r2}];if(sentHistory.count>40)[sentHistory removeObjectAtIndex:0];
   pthread_mutex_unlock(&outputLock);
  }
  usleep(16000);
 }
 }
 return NULL;
}
static bool setLevel(int ch,float level){
 level=fmaxf(0,fminf(1,level));if(fabsf(lastLevel[ch]-level)<.001)return true;
 if(dry){lastLevel[ch]=level;return true;}
 if(!atomic_load(&engineRunning[ch]))return level==0;
 NSError *error=nil;
 CHHapticDynamicParameter *p=[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level relativeTime:0];
 @try { if(![players[ch] sendParameters:@[p] atTime:CHHapticTimeImmediate error:&error]){fprintf(stderr,"Core Haptics update failed: %s\n",error.description.UTF8String);return false;} }
 @catch(NSException *exception){atomic_store(&engineRunning[ch],false);fprintf(stderr,"Core Haptics became unavailable: %s\n",exception.reason.UTF8String);return false;}
 lastLevel[ch]=level;return true;
}
static bool prepare(GCController *pad){
 NSArray *localities=@[GCHapticsLocalityLeftHandle,GCHapticsLocalityRightHandle];
 for(int i=0;i<2;i++){
  engines[i]=[pad.haptics createEngineWithLocality:localities[i]];
  if(!engines[i]){fprintf(stderr,"No haptic engine locality=%s supported=%s\n",[localities[i] UTF8String],pad.haptics.supportedLocalities.description.UTF8String);return false;}
  engines[i].autoShutdownEnabled=NO;
  engines[i].stoppedHandler=^(CHHapticEngineStoppedReason reason){atomic_store(&engineRunning[i],false);fprintf(stderr,"Core Haptics stopped: %ld\n",(long)reason);quitting=1;};
  engines[i].resetHandler=^{atomic_store(&engineRunning[i],false);fprintf(stderr,"Core Haptics reset; session must restart\n");quitting=1;};
  NSError *e=nil;if(![engines[i] startAndReturnError:&e]){fprintf(stderr,"Engine start ch=%d error=%s\n",i,e.description.UTF8String);return false;}
  atomic_store(&engineRunning[i],true);
  CHHapticEventParameter *one=[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1];
  CHHapticEvent *event=[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[one] relativeTime:0 duration:30];
  CHHapticDynamicParameter *zero=[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0];
  CHHapticPattern *pattern=[[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[zero] error:&e];
  silentPattern=pattern;
  players[i]=[engines[i] createPlayerWithPattern:pattern error:&e];
  if(!players[i]){fprintf(stderr,"Player create ch=%d error=%s\n",i,e.description.UTF8String);return false;}

  if(![players[i] startAtTime:CHHapticTimeImmediate error:&e]){fprintf(stderr,"Player start ch=%d error=%s\n",i,e.description.UTF8String);return false;}
  lastLevel[i]=0;
 }
 playerStart=CFAbsoluteTimeGetCurrent();
 return true;
}
static bool renewPlayers(void){
 if(dry||CFAbsoluteTimeGetCurrent()-playerStart<25)return true;
 for(int i=0;i<2;i++){NSError *e=nil;id<CHHapticPatternPlayer> next=[engines[i] createPlayerWithPattern:silentPattern error:&e];if(!next)return false;[players[i] stopAtTime:CHHapticTimeImmediate error:NULL];players[i]=next;if(![next startAtTime:CHHapticTimeImmediate error:&e])return false;lastLevel[i]=-1;}
 playerStart=CFAbsoluteTimeGetCurrent();return true;
}
typedef struct {uint32_t pid,seq;double at,rumbleAt;float left,right,rl,rr;bool initialized;} Source;
static Source sources[64];
int main(int argc,char **argv){@autoreleasepool{
 id activity=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated|NSActivityLatencyCritical reason:@"DualSense real-time haptic transport"];
 setbuf(stdout,NULL);sentHistory=[NSMutableArray array];signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);
 NSString *status=nil,*secret=nil;pid_t parent=0;double seconds=43200;bool probe=false;unsigned requestedPort=0;
 for(int i=1;i<argc;i++){
  if(!strcmp(argv[i],"--probe"))probe=true;
  else if(!strcmp(argv[i],"--pcm"))pcmMode=true;
  else if(!strcmp(argv[i],"--trigger-reset-grace-ms")&&i+1<argc){char *end=NULL;long ms=strtol(argv[++i],&end,10);if(*end||ms<0||ms>100)return 64;resetGrace=ms/1000.;}
  else if(!strcmp(argv[i],"--dry-run"))dry=true;
  else if(!strcmp(argv[i],"--token")&&i+1<argc)secret=@(argv[++i]);
  else if(!strcmp(argv[i],"--status")&&i+1<argc)status=@(argv[++i]);
  else if(!strcmp(argv[i],"--parent")&&i+1<argc)parent=atoi(argv[++i]);
  else if(!strcmp(argv[i],"--seconds")&&i+1<argc)seconds=atof(argv[++i]);
  else if(!strcmp(argv[i],"--port")&&i+1<argc){char *end=NULL;long p=strtol(argv[++i],&end,10);if(*end||p<1024||p>65535)return 64;requestedPort=(unsigned)p;}
  else return 64;
 }
 IOHIDManagerRef manager=NULL;unsigned bt=0,usb=0;
 if(!dry){
  manager=IOHIDManagerCreate(NULL,pcmMode?kIOHIDManagerOptionIndependentDevices:0);IOHIDManagerSetDeviceMatching(manager,(__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey:@0x54c,@kIOHIDProductIDKey:@0xce6});IOHIDManagerOpen(manager,0);
  CFSetRef devices=IOHIDManagerCopyDevices(manager);
  if(devices){for(id obj in (__bridge NSSet*)devices){IOHIDDeviceRef d=(__bridge IOHIDDeviceRef)obj;NSString *transport=(__bridge NSString*)IOHIDDeviceGetProperty(d,CFSTR(kIOHIDTransportKey));if([transport isEqualToString:@"USB"])usb++;else if([transport hasPrefix:@"Bluetooth"]){bt++;hid=d;}}if(hid)CFRetain(hid);CFRelease(devices);}
  if(probe){printf("{\"bluetooth\":%u,\"usb\":%u,\"eligible\":%s}\n",bt,usb,bt==1&&!usb?"true":"false");return 0;}
  if(bt!=1||usb){fprintf(stderr,"Requires exactly one Bluetooth DualSense and no USB DualSense\n");return 3;}
  if(IOHIDDeviceOpen(hid,0))return 4;
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  GCController *pad=nil;
  // The raw PCM transport owns HID output. Do not also create a native
  // controller/haptic client: its initialization and teardown can write
  // competing mode/LED commands. Core Haptics is an explicit fallback only.
  if(!pcmMode){
   GCController.shouldMonitorBackgroundEvents=YES;
   for(int i=0;i<80&&!pad;i++){for(GCController *c in GCController.controllers)if([c.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]){pad=c;break;}if(!pad)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];}
   nativePad=(GCDualSenseGamepad *)pad.extendedGamepad;
   if(!pad||!prepare(pad)){fprintf(stderr,"DualSense Core Haptics initialization failed\n");return 5;}
  }
  if(pcmMode){
   IOHIDDeviceRegisterRemovalCallback(hid,pcmRemoved,NULL);
   IOHIDDeviceRegisterInputReportCallback(hid,inputBuffer,sizeof(inputBuffer),pcmInput,NULL);
   IOHIDDeviceScheduleWithRunLoop(hid,CFRunLoopGetMain(),kCFRunLoopCommonModes);
   uint8_t feature[41]={5};CFIndex n=sizeof(feature);
   if(IOHIDDeviceGetReport(hid,kIOHIDReportTypeFeature,5,feature,&n))return 7;
   for(int i=0;i<40&&!inputAlive();i++)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
   if(!inputAlive()){fprintf(stderr,"PCM: no live HID input; no output sent\n");return 8;}
  }
  if(!pcmMode)[[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:pad queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){fprintf(stderr,"Core Haptics controller disconnected\n");quitting=1;}];
 }
 if(pcmMode){
  task_category_policy_data_t policy={TASK_FOREGROUND_APPLICATION};
  kern_return_t result=task_policy_set(mach_task_self(),TASK_CATEGORY_POLICY,(task_policy_t)&policy,TASK_CATEGORY_POLICY_COUNT);
  fprintf(stderr,"PCM task scheduling role result=%d\n",result);
 }
 if(secret.length!=32)return 64;uint8_t token[16];for(int i=0;i<16;i++){unsigned v;if(sscanf(secret.UTF8String+i*2,"%2x",&v)!=1)return 64;token[i]=v;}
 int fd=socket(AF_INET,SOCK_DGRAM,0);struct sockaddr_in addr={.sin_len=sizeof(addr),.sin_family=AF_INET,.sin_port=htons(requestedPort),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 if(bind(fd,(void*)&addr,sizeof(addr)))return 6;socklen_t len=sizeof(addr);getsockname(fd,(void*)&addr,&len);fcntl(fd,F_SETFL,O_NONBLOCK);
 unsigned port=ntohs(addr.sin_port);
 CFFileDescriptorRef socketEvents=NULL;CFRunLoopSourceRef socketSource=NULL;
 if(pcmMode){
  socketEvents=CFFileDescriptorCreate(NULL,fd,false,socketReady,NULL);
  if(!socketEvents){fprintf(stderr,"PCM socket event source unavailable\n");return 9;}
  socketSource=CFFileDescriptorCreateRunLoopSource(NULL,socketEvents,0);
  if(!socketSource){fprintf(stderr,"PCM socket run loop source unavailable\n");return 9;}
  CFRunLoopAddSource(CFRunLoopGetMain(),socketSource,kCFRunLoopDefaultMode);
 }
 pthread_t worker;atomic_store(&workerRunning,true);
 if(pthread_create(&worker,NULL,pcmMode?pcmWorker:outputWorker,NULL)){fprintf(stderr,"Controller writer thread unavailable\n");return 9;}
 if(pcmMode){
  double deadline=CFAbsoluteTimeGetCurrent()+5;
  while(!atomic_load(&pcmWorkerReady)&&CFAbsoluteTimeGetCurrent()<deadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.002,true);
  if(!atomic_load(&pcmWorkerReady)||atomic_load(&stalled)){fprintf(stderr,"PCM writer did not initialize\n");return 9;}
 }
 printf("{\"ready\":true,\"port\":%u,\"pid\":%d}\n",port,getpid());
 NSString *calibrationPath=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/notproton/controllers/dualsense/calibration.json"];
 float pcmGain=1;double nextCalibration=0;
 double start=CFAbsoluteTimeGetCurrent(),nextStatus=0;uint64_t accepted=0,dropped=0,levels=0,outputs=0;float maxL=0,maxR=0;
 while(!quitting&&CFAbsoluteTimeGetCurrent()-start<seconds){@autoreleasepool{
  double now=CFAbsoluteTimeGetCurrent();if(parent&&kill(parent,0)&&errno==ESRCH)break;
  if(atomic_load(&stalled))break;
  if(now>=nextCalibration){pcmGain=DSBPCMGain(calibrationPath);nextCalibration=now+1;}
  for(int j=0;j<1024;j++){
   DSBPacket p;uint8_t datagram[sizeof(p)+1];ssize_t n=recv(fd,datagram,sizeof(datagram),0);if(n<0)break;memcpy(&p,datagram,MIN((size_t)n,sizeof(p)));
   if(n!=sizeof(p)||p.magic!=DSB_MAGIC||memcmp(p.token,token,16)||!isfinite(p.timestamp)||fabs(now-p.timestamp)>.25||!isfinite(p.left)||!isfinite(p.right)){dropped++;continue;}
   Source *s=NULL;for(int k=0;k<64;k++)if(sources[k].pid==p.pid){s=sources+k;break;}
   if(!s)for(int k=0;k<64;k++)if(!sources[k].pid||now-fmax(sources[k].at,sources[k].rumbleAt)>2){s=sources+k;memset(s,0,sizeof(*s));s->pid=p.pid;break;}
   if(!s||(s->initialized&&(int32_t)(p.sequence-s->seq)<=0)){dropped++;continue;}s->initialized=true;s->seq=p.sequence;
   if(p.kind==DSB_LEVEL){s->at=now;s->left=fmaxf(0,fminf(1,p.left));s->right=fmaxf(0,fminf(1,p.right));levels++;}
   else if(pcmMode&&p.kind==DSB_PCM&&(p.report[0]==0||p.report[0]==30)){receivePCM(&p);s->at=now;levels++;}
   else if(p.kind==DSB_OUTPUT&&p.report[0]==2){
    const uint8_t *b=p.report+1;
    if(b[1]&4){
     if(!ledCommands||memcmp(ledRGB,b+44,3)||ledSource!=p.pid)fprintf(stderr,"LED source=%u rgb=%u,%u,%u flags=%02x/%02x\n",p.pid,b[44],b[45],b[46],b[0],b[1]);
     ledCommands++;ledSource=p.pid;memcpy(ledRGB,b+44,3);
    }
    if(b[1]&16){if(!playerCommands||playerLED!=b[43])fprintf(stderr,"Player LED source=%u value=%02x flags=%02x/%02x\n",p.pid,b[43],b[0],b[1]);playerCommands++;playerLED=b[43];}
    queueOutput(p.report);outputs++;
    if((b[0]&3)||(b[38]&4)){s->rumbleAt=now;s->rl=b[3]/255.f;s->rr=b[2]/255.f;if(pcmMode){pthread_mutex_lock(&outputLock);if(legacyLeft!=b[3]||legacyRight!=b[2])legacyDirty=true;legacyLeft=b[3];legacyRight=b[2];pthread_mutex_unlock(&outputLock);}}else{s->rl=s->rr=0;}
   }
   else{dropped++;continue;}accepted++;
  }
  pthread_mutex_lock(&outputLock);
  for(int side=0;side<2;side++)if(releaseAt[side]&&now>=releaseAt[side]){
   pending[0]|=4u<<side;memcpy(pending+10+side*11,releaseEffect[side],11);releaseAt[side]=0;outputDirty=true;
  }
  pthread_mutex_unlock(&outputLock);
  float l=0,r=0;for(int i=0;i<64;i++){Source *s=sources+i;if(now-s->at<.15){l=fmaxf(l,DSBCalibratedPCM(s->left,pcmGain));r=fmaxf(r,DSBCalibratedPCM(s->right,pcmGain));}if(now-s->rumbleAt<.5){l=fmaxf(l,s->rl);r=fmaxf(r,s->rr);}}
  if(pcmMode){
   float a=0,b=0;for(int i=0;i<64;i++)if(now-sources[i].rumbleAt<.5){a=fmaxf(a,sources[i].rl);b=fmaxf(b,sources[i].rr);}
   uint8_t left=(uint8_t)lrintf(a*255),right=(uint8_t)lrintf(b*255);
   pthread_mutex_lock(&outputLock);if(left!=legacyLeft||right!=legacyRight){legacyLeft=left;legacyRight=right;legacyDirty=true;}pthread_mutex_unlock(&outputLock);
  }
  maxL=fmaxf(maxL,l);maxR=fmaxf(maxR,r);if(!pcmMode){if(!renewPlayers())break;if(!setLevel(0,l)||!setLevel(1,r))break;}
  if(status&&now>=nextStatus){
   pthread_mutex_lock(&outputLock);
   NSMutableArray *r2=[NSMutableArray array];for(int i=10;i<21;i++)[r2 addObject:@(pending[i])];
   NSDictionary *pcmStats=@{@"direct":@(pcmMode),@"realtimeResult":@(pcmRealtimeResult),@"audioWorkgroupResult":@(pcmWorkgroupResult),@"maxWaitLateMs":@(atomic_load(&pcmMaxWaitLateNS)/1e6),@"maxLockMs":@(atomic_load(&pcmMaxLockNS)/1e6),@"maxLoopMs":@(atomic_load(&pcmMaxLoopNS)/1e6),@"suspended":@(atomic_load(&pcmSuspended)),@"inputHz":@(atomic_load(&inputHz)),@"pauses":@(atomic_load(&pcmPauses)),@"backgroundFrames":@(atomic_load(&pcmBackgroundFrames)),@"reports":@(atomic_load(&pcmReports)),@"inputReports":@(atomic_load(&inputReports)),@"queueFrames":@(fifoCount),@"underrunFrames":@(atomic_load(&pcmUnderruns)),@"discardedFrames":@(atomic_load(&pcmDiscarded)),@"maxWriteMs":@(maximumWrite*1000),@"maxLagMs":@(maximumLag*1000)};
   NSDictionary *triggers=@{@"resetGraceMs":@(resetGrace*1000),@"suppressedR2Resets":@(suppressedResets[0]),@"r2":r2,@"sentHistory":[sentHistory copy],@"physicalR2Mode":@(pcmMode?-1:nativePad.rightTrigger.mode),@"physicalR2Status":@(pcmMode?-1:nativePad.rightTrigger.status)};
   pthread_mutex_unlock(&outputLock);
   NSDictionary *obj=@{@"state":@"running",@"led":@{@"commands":@(ledCommands),@"sourcePid":@(ledSource),@"rgb":@[@(ledRGB[0]),@(ledRGB[1]),@(ledRGB[2])],@"playerCommands":@(playerCommands),@"player":@(playerLED)},@"pcm":pcmStats,@"triggers":triggers,@"pid":@(getpid()),@"port":@(port),@"accepted":@(accepted),@"dropped":@(dropped),@"pcmBlocks":@(levels),@"pcmGain":@(pcmGain),@"outputCommands":@(outputs),@"hidReports":@(atomic_load(&reports)),@"hidErrors":@(atomic_load(&errors)),@"hidStalled":@(atomic_load(&stalled)),@"left":@(l),@"right":@(r),@"peakLeft":@(maxL),@"peakRight":@(maxR),@"updated":@([[NSDate date] timeIntervalSince1970])};[[NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:status atomically:YES];nextStatus=now+1;}
  if(pcmMode){CFFileDescriptorEnableCallBacks(socketEvents,kCFFileDescriptorReadCallBack);CFRunLoopRunInMode(kCFRunLoopDefaultMode,.002,true);}
  else [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 }}
 if(!pcmMode){setLevel(0,0);setLevel(1,0);}
 // Release triggers only if this session touched them. Leave unrelated Steam output alone.
 resetGrace=0; // Cleanup must never defer release.
 if(!atomic_load(&deviceRemoved)&&(pending[0]&12)){uint8_t reset[64]={2,12};reset[11]=5;reset[22]=5;queueOutput(reset);usleep(40000);}
 atomic_store(&workerRunning,false);if(!atomic_load(&stalled))pthread_join(worker,NULL);
 for(int i=0;i<2;i++){
  // Disconnect can stop the engine before cleanup. PatternPlayer stop then
  // raises an ObjC exception rather than returning NSError on macOS 27.
  @try {if(atomic_load(&engineRunning[i]))[players[i] stopAtTime:CHHapticTimeImmediate error:NULL];[engines[i] stopWithCompletionHandler:nil];}
  @catch(NSException *exception){fprintf(stderr,"Core Haptics already stopped during cleanup: %s\n",exception.reason.UTF8String);}
  atomic_store(&engineRunning[i],false);
 }
 if(hid&&!atomic_load(&stalled)){if(pcmMode)IOHIDDeviceUnscheduleFromRunLoop(hid,CFRunLoopGetMain(),kCFRunLoopCommonModes);IOHIDDeviceClose(hid,0);CFRelease(hid);}
 if(manager&&!atomic_load(&stalled)){IOHIDManagerClose(manager,0);CFRelease(manager);}
 [[NSProcessInfo processInfo] endActivity:activity];
 if(status){
  NSData *data=[NSData dataWithContentsOfFile:status];
  NSMutableDictionary *final=data?[[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] mutableCopy]:[NSMutableDictionary dictionary];
  if(!final)final=[NSMutableDictionary dictionary];
  final[@"state"]=atomic_load(&deviceRemoved)?@"disconnected":atomic_load(&stalled)?@"output-stopped":@"stopped";
  final[@"updated"]=@([[NSDate date] timeIntervalSince1970]);
  [[NSJSONSerialization dataWithJSONObject:final options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:status atomically:YES];
 }
 if(socketEvents){CFFileDescriptorInvalidate(socketEvents);CFRunLoopRemoveSource(CFRunLoopGetMain(),socketSource,kCFRunLoopDefaultMode);CFRelease(socketSource);CFRelease(socketEvents);}
 close(fd);fprintf(stderr,"Stopped: packets=%llu PCM=%llu output=%llu HID=%u errors=%u\n",accepted,levels,outputs,atomic_load(&reports),atomic_load(&errors));
 return atomic_load(&deviceRemoved)?10:atomic_load(&stalled)?11:0;
}}
