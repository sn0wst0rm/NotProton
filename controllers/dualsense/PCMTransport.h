// Included by broker.m: a single writer owns PCM, triggers, LEDs and rumble.
// No Core Haptics engine is started in this mode.
#include "PCM.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <mach/semaphore.h>
#include <mach/sync_policy.h>
#import <AudioToolbox/AudioWorkInterval.h>
static bool pcmMode;
static uint8_t inputBuffer[1024];
static atomic_ullong inputTime;
static atomic_uint inputReports,pcmReports,pcmUnderruns,pcmDiscarded,inputHz,pcmPauses,pcmBackgroundFrames;
static atomic_bool pcmSuspended;
static atomic_bool deviceRemoved;
static int8_t fifo[256][2];
static unsigned fifoHead,fifoCount,pcmOwner,pcmStream;
static double pcmReceived,pcmNonzero;
static bool pcmEnded;
static atomic_uchar legacyLeft,legacyRight;
static bool legacyDirty;
static double maximumWrite,maximumLag;
static mach_timebase_info_data_t pcmTimebase;
static int pcmRealtimeResult=-1;
static atomic_ullong pcmMaxWaitLateNS,pcmMaxLockNS,pcmMaxLoopNS;
static os_workgroup_interval_t pcmWorkgroup;
static bool pcmIntervalOpen;
static int pcmWorkgroupResult=-1;
static atomic_bool pcmWorkerReady;
static semaphore_t pcmWake=MACH_PORT_NULL;
static atomic_bool pcmWakePending;
static bool pcmDeferTestTimers;
static void pcmNotify(void){bool expected=false;if(atomic_load(&pcmWorkerReady)&&atomic_compare_exchange_strong(&pcmWakePending,&expected,true))semaphore_signal(pcmWake);}
// Relative nanosleep/usleep can be coalesced by ~100 ms while another app
// owns Game Mode. Use Mach deadlines and an audio-sized realtime budget.
// Blocking HID writes remain guarded; missed deadlines still discard audio.
static uint64_t pcmTicks(double seconds){return (uint64_t)(seconds*1e9*pcmTimebase.denom/pcmTimebase.numer);}
static void pcmMax(atomic_ullong *value,uint64_t n){uint64_t old=atomic_load(value);while(old<n&&!atomic_compare_exchange_weak(value,&old,n)){};}
static void pcmCycleEnd(void){if(pcmIntervalOpen){int result=os_workgroup_interval_finish(pcmWorkgroup,NULL);if(result)pcmWorkgroupResult=result;pcmIntervalOpen=false;}}
static void pcmCycleBegin(void){pcmCycleEnd();if(pcmWorkgroupResult==0){uint64_t now=mach_absolute_time();pcmIntervalOpen=os_workgroup_interval_start(pcmWorkgroup,now,now+pcmTicks(.021333333),NULL)==0;}}
static void pcmWait(double seconds){if(seconds>0){
 pcmCycleEnd();
 uint64_t start=mach_absolute_time(),due=start+pcmTicks(seconds),now;
 // Game Mode may defer timer-only wakeups even on a realtime thread. Actual
 // HID/UDP arrivals signal this semaphore and let us check the same deadline.
 // Signals are coalesced, so neither bursts nor old notifications build up.
 while((now=mach_absolute_time())<due){
  uint64_t ns=(due-now)*pcmTimebase.numer/pcmTimebase.denom;
  if(pcmDeferTestTimers)ns+=100000000; // Offline regression: emulate deferred timer wakeups.
  mach_timespec_t timeout={(unsigned)(ns/1000000000),(int)(ns%1000000000)};
  if(semaphore_timedwait(pcmWake,timeout)==KERN_SUCCESS)atomic_store(&pcmWakePending,false);
 }
 uint64_t end=mach_absolute_time();if(end>due)pcmMax(&pcmMaxWaitLateNS,(end-due)*pcmTimebase.numer/pcmTimebase.denom);
 pcmCycleBegin();
}}
static double monotonicNow(void){return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1e9;}
static void pcmRemoved(void *ctx,IOReturn result,void *sender){
 atomic_store(&deviceRemoved,true);atomic_store(&stalled,true);quitting=1;
 fprintf(stderr,"PCM device removed; waiting for a fresh Bluetooth connection\n");
}
static void pcmInput(void *ctx,IOReturn r,void *sender,IOHIDReportType type,uint32_t id,uint8_t *b,CFIndex n){
 if(!r&&n>0){
  uint64_t now=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);atomic_store(&inputTime,now);unsigned count=atomic_fetch_add(&inputReports,1)+1;
  static uint64_t epoch;static unsigned previous;
  if(!epoch){epoch=now;previous=count;}
  if(now-epoch>=250000000){atomic_store(&inputHz,(unsigned)((count-previous)*1e9/(now-epoch)));epoch=now;previous=count;}
  pcmNotify();
 }
}
static bool inputAlive(void){return dry||(atomic_load(&inputReports)>=10&&monotonicNow()-atomic_load(&inputTime)/1e9<.2);}
static void receivePCM(const DSBPacket *p){
 unsigned stream=p->report[1]|(p->report[2]<<8)|(p->report[3]<<16),n=p->report[0];
 double now=monotonicNow();pthread_mutex_lock(&outputLock);
 // Independent audio clients cannot concatenate their timelines. Keep one
 // owner until stopped/stale; current facade exposes just one haptic device.
 if(pcmOwner!=p->pid||pcmStream!=stream){
  if(pcmOwner&&!pcmEnded&&now-pcmReceived<.15){atomic_fetch_add(&pcmDiscarded,n);pthread_mutex_unlock(&outputLock);return;}
  pcmOwner=p->pid;pcmStream=stream;fifoHead=fifoCount=0;pcmNonzero=0;
 }
 pcmReceived=now;pcmEnded=!n;
 if(n){
  // Bound queue latency to 64ms. Drop old samples after a scheduling pause,
  // never catch up with a burst of Bluetooth writes.
  if(atomic_load(&pcmSuspended)){atomic_fetch_add(&pcmBackgroundFrames,fifoCount);fifoHead=fifoCount=0;}
  if(fifoCount+n>192){unsigned discard=fifoCount>64?fifoCount-64:0;fifoHead=(fifoHead+discard)%256;fifoCount-=discard;atomic_fetch_add(&pcmDiscarded,discard);}
  for(unsigned i=0;i<n;i++){unsigned at=(fifoHead+fifoCount++)%256;memcpy(fifo[at],p->report+4+i*2,2);if(fifo[at][0]||fifo[at][1])pcmNonzero=now;}
 }
 pthread_mutex_unlock(&outputLock);
 pcmNotify();
}
static bool pcmWrite(uint8_t *b,unsigned n){
 if(atomic_load(&stalled)||!inputAlive())return false;
 double start=monotonicNow();IOReturn r=dry?0:IOHIDDeviceSetReport(hid,kIOHIDReportTypeOutput,b[0],b,n);
 double elapsed=monotonicNow()-start;
 pthread_mutex_lock(&outputLock);maximumWrite=fmax(maximumWrite,elapsed);pthread_mutex_unlock(&outputLock);
 atomic_fetch_add(&reports,1);
 if(r||elapsed>.080){atomic_fetch_add(&errors,1);atomic_store(&stalled,true);fprintf(stderr,"PCM output stopped: error=0x%x report=0x%02x size=%u write_ms=%.3f input_hz=%u head=",r,b[0],n,elapsed*1000,atomic_load(&inputHz));for(unsigned i=0;i<MIN(n,16);i++)fprintf(stderr,"%02x",b[i]);fprintf(stderr,"\n");return false;}return true;
}
static bool pcmControl(const uint8_t payload[47],bool audio){
 uint8_t b[78]={0x31};b[1]=(btSequence++&15)<<4;b[2]=0x10;if(payload)memcpy(b+3,payload,47);
 // Mode bits belong to this writer. A game's legacy zero/rumble command
 // must not switch off an ongoing audio stream.
 if(audio){b[3]&=~3;b[5]=b[6]=0;b[41]&=~4;}else{b[3]|=3;b[5]=legacyRight;b[6]=legacyLeft;b[41]&=~4;}
 DSBCRC(b,78);return pcmWrite(b,78);
}
static void *pcmWorker(void *unused){@autoreleasepool{
 pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
 mach_timebase_info(&pcmTimebase);
 pcmDeferTestTimers=dry&&getenv("DSB_TEST_DEFER_TIMERS")!=NULL;
 kern_return_t semResult=semaphore_create(mach_task_self(),&pcmWake,SYNC_POLICY_FIFO,0);
 if(semResult){fprintf(stderr,"PCM wake semaphore failed: %d\n",semResult);atomic_store(&stalled,true);atomic_store(&pcmWorkerReady,true);return NULL;}
 thread_time_constraint_policy_data_t policy={
  .period=(uint32_t)pcmTicks(64./3000.),.computation=(uint32_t)pcmTicks(.001),
  .constraint=(uint32_t)pcmTicks(.005),.preemptible=TRUE};
 pcmRealtimeResult=thread_policy_set(pthread_mach_thread_np(pthread_self()),THREAD_TIME_CONSTRAINT_POLICY,
  (thread_policy_t)&policy,THREAD_TIME_CONSTRAINT_POLICY_COUNT);
 fprintf(stderr,"PCM deadline scheduling result=%d (1 ms budget / 21.33 ms period)\n",pcmRealtimeResult);
 pcmWorkgroup=AudioWorkIntervalCreate("DualSense Bluetooth PCM",OS_CLOCK_MACH_ABSOLUTE_TIME,NULL);
 os_workgroup_join_token_s joinToken;
 pcmWorkgroupResult=pcmWorkgroup?os_workgroup_join(pcmWorkgroup,&joinToken):-1;
 fprintf(stderr,"PCM audio workgroup result=%d\n",pcmWorkgroupResult);
 atomic_store(&pcmWorkerReady,true);
 bool streaming=false;unsigned index=0;double nextPCM=0,previous=0,nextControl=0,resumeAfter=0,previousLoop=0;
 while(atomic_load(&workerRunning)&&!atomic_load(&stalled)){
  pcmCycleBegin();
  double now=monotonicNow();
  if(previousLoop)pcmMax(&pcmMaxLoopNS,(now-previousLoop)*1e9);previousLoop=now;
  if(!inputAlive()){if(streaming){atomic_store(&stalled,true);fprintf(stderr,"PCM stopped: controller input stale\n");}pcmWait(.002);continue;}
  bool linkFast=dry||atomic_load(&inputHz)>=100;
  atomic_store(&pcmSuspended,!linkFast||now<resumeAfter);
  if(streaming&&atomic_load(&pcmSuspended)){
   int8_t zero[128]={0};uint8_t b[206];unsigned n=DSBPCMReport(b,btSequence++,index,false,zero);
   if(!pcmWrite(b,n))break;pcmWait(.030);if(!pcmControl(NULL,false))break;
   streaming=false;atomic_fetch_add(&pcmPauses,1);
   pthread_mutex_lock(&outputLock);atomic_fetch_add(&pcmBackgroundFrames,fifoCount);fifoHead=fifoCount=0;pthread_mutex_unlock(&outputLock);
  }
  uint8_t payload[47]={0},snapshot[47];bool control=false,controlChange=false,hasAudio=false;
  double lockStart=monotonicNow();pthread_mutex_lock(&outputLock);pcmMax(&pcmMaxLockNS,(monotonicNow()-lockStart)*1e9);
  // Games often keep an audio stream open with zeros in menus. Release
  // audio mode after the actual waveform's tail, not only on stream close.
  // Exact signed samples determine activity; no envelope conversion/gain.
  hasAudio=!atomic_load(&pcmSuspended)&&pcmNonzero>0&&now-pcmNonzero<.15&&(fifoCount||(!pcmEnded&&pcmOwner&&now-pcmReceived<.15));
  if(!hasAudio&&!streaming){fifoHead=fifoCount=0;}
  memcpy(snapshot,pending,47);
  if(outputDirty&&now>=nextControl){outputDirty=false;control=controlChange=DSBControlDelta(snapshot,lastSent,haveLast,payload);}
  if(!hasAudio&&legacyDirty){control=true;legacyDirty=false;}
  pthread_mutex_unlock(&outputLock);
  if(control){
   if(!pcmControl(payload,hasAudio))break;nextControl=monotonicNow()+.016;
   pthread_mutex_lock(&outputLock);if(controlChange){memcpy(lastSent,snapshot,47);haveLast=true;}
   NSMutableArray *r2=[NSMutableArray array];for(int i=10;i<21;i++)[r2 addObject:@(snapshot[i])];
   [sentHistory addObject:@{@"at":@([[NSDate date] timeIntervalSince1970]),@"r2":r2}];if(sentHistory.count>40)[sentHistory removeObjectAtIndex:0];pthread_mutex_unlock(&outputLock);
  }
  if(hasAudio&&!streaming){
   if(!pcmControl(NULL,true))break;
   streaming=true;index=0;nextPCM=monotonicNow()+.030;previous=nextPCM-.022;
  }
  if(streaming&&now>=nextPCM){
   double lag=now-nextPCM;
   pthread_mutex_lock(&outputLock);maximumLag=fmax(maximumLag,lag);pthread_mutex_unlock(&outputLock);
   if(lag>.040){fprintf(stderr,"PCM resync: scheduler pause %.3f ms\n",lag*1000);resumeAfter=now+.5;continue;}
   if(now-previous<.018){pcmWait(.0005);continue;}
   int8_t samples[128]={0};unsigned n;
   pthread_mutex_lock(&outputLock);n=MIN(fifoCount,64);for(unsigned i=0;i<n;i++){memcpy(samples+i*2,fifo[fifoHead],2);fifoHead=(fifoHead+1)%256;fifoCount--;}
   pthread_mutex_unlock(&outputLock);
   if(n<64&&hasAudio)atomic_fetch_add(&pcmUnderruns,64-n);
   uint8_t b[206];unsigned size=DSBPCMReport(b,btSequence++,index,index==0,samples);
   previous=monotonicNow();if(!pcmWrite(b,size))break;atomic_fetch_add(&pcmReports,1);index++;nextPCM+=64./3000.;
   if(!hasAudio){
    // Allow the zero tail to reach the actuators, then restore regular
    // rumble. No LED changes. All writes remain serialized in this thread.
    pcmWait(.030);if(!pcmControl(NULL,false))break;streaming=false;
   }
  }
  if(streaming){
   while(atomic_load(&workerRunning)){
    double remaining=nextPCM-monotonicNow();if(remaining<=0)break;
    pcmWait(remaining);
   }
  }else pcmWait(.002);
 }
 bool failed=atomic_load(&stalled);
 if(inputAlive()&&!atomic_load(&errors)){
  atomic_store(&stalled,false);
  if(streaming){int8_t zero[128]={0};uint8_t b[206];unsigned n=DSBPCMReport(b,btSequence++,index,false,zero);pcmWrite(b,n);pcmWait(.030);}
  legacyLeft=legacyRight=0;pcmControl(NULL,false);if(failed)atomic_store(&stalled,true);
 }
 pcmCycleEnd();if(pcmWorkgroupResult==0)os_workgroup_leave(pcmWorkgroup,&joinToken);pcmWorkgroup=nil;
 atomic_store(&pcmWorkerReady,false);semaphore_destroy(mach_task_self(),pcmWake);
}return NULL;}
