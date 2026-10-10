// Wine-local USB facade. No system audio device or virtual macOS controller.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioUnit/AudioUnit.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>
#include <mach/mach_time.h>
#include "protocol.h"
#include "PCM.h"
#include "descriptor.h"
#define INTERPOSE(new,old) __attribute__((used)) static struct {const void *a,*b;} ip_##old __attribute__((section("__DATA,__interpose")))={(void*)new,(void*)old}
static bool enabled,raw,pcmMode;
static int sock=-1;
static uint8_t token[16];
static atomic_uint sequence;
static struct sockaddr_in dest;
static CFDataRef descriptor;
static CFNumberRef usbInput,usbOutput;
static bool bluetooth(IOHIDDeviceRef d) {
 if(!enabled)return false;
 int vid=0,pid=0;
 CFTypeRef v=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDVendorIDKey));
 if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&vid);
 v=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductIDKey));
 if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&pid);
 CFStringRef tr=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDTransportKey));
 return vid==0x54c&&pid==0xce6&&tr&&CFGetTypeID(tr)==CFStringGetTypeID()&&CFStringHasPrefix(tr,CFSTR("Bluetooth"));
}
static void transmit(uint32_t kind,float left,float right,const uint8_t *report,size_t size) {
 if(!enabled||sock<0)return;
 DSBPacket p={.magic=DSB_MAGIC,.kind=kind,.pid=getpid(),.sequence=atomic_fetch_add(&sequence,1),.timestamp=CFAbsoluteTimeGetCurrent(),.left=left,.right=right};
 memcpy(p.token,token,16);if(report)memcpy(p.report,report,MIN(size,64));
 ssize_t sent=sendto(sock,&p,sizeof(p),MSG_DONTWAIT,(void*)&dest,sizeof(dest));
 static atomic_uint logged;
 unsigned bit=1u<<kind;
 if(!(atomic_fetch_or(&logged,bit)&bit))fprintf(stderr,"DSB: first packet pid=%d kind=%u port=%u bytes=%ld errno=%d\n",getpid(),kind,ntohs(dest.sin_port),(long)sent,sent<0?errno:0);
}
__attribute__((constructor)) static void initialize(void) {
 const char *port=getenv("DSB_PORT"),*secret=getenv("DSB_TOKEN"),*mode=getenv("DSB_RAW");
 if(!port||!secret||strlen(secret)!=32)return;
 int n=atoi(port);if(n<1024||n>65535)return;
 for(int i=0;i<16;i++){unsigned v;if(sscanf(secret+i*2,"%2x",&v)!=1)return;token[i]=v;}
 sock=socket(AF_INET,SOCK_DGRAM,0);if(sock<0)return;
 dest=(struct sockaddr_in){.sin_len=sizeof(dest),.sin_family=AF_INET,.sin_port=htons(n),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 raw=mode&&atoi(mode)==1;
 // RAW travels through existing NotProton --env forwarding on all backends.
 pcmMode=(mode&&!strcmp(mode,"1:pcm"))||(getenv("DSB_PCM")&&!strcmp(getenv("DSB_PCM"),"1"));
 descriptor=CFDataCreate(NULL,usb_descriptor,sizeof(usb_descriptor));int a=78,b=48;
 usbInput=CFNumberCreate(NULL,kCFNumberIntType,&a);usbOutput=CFNumberCreate(NULL,kCFNumberIntType,&b);
 enabled=true;
 fprintf(stderr,"DSB: Bluetooth bridge loaded pid=%d raw=%d pcm=%d port=%u\n",getpid(),raw,pcmMode,ntohs(dest.sin_port));
}
static CFTypeRef property(IOHIDDeviceRef d,CFStringRef key) {
 if(raw&&bluetooth(d)) {
  if(CFEqual(key,CFSTR(kIOHIDTransportKey)))return CFSTR("USB");
  if(CFEqual(key,CFSTR(kIOHIDManufacturerKey)))return CFSTR("Sony Interactive Entertainment");
  if(CFEqual(key,CFSTR(kIOHIDReportDescriptorKey)))return descriptor;
  if(CFEqual(key,CFSTR(kIOHIDMaxInputReportSizeKey)))return usbInput;
  if(CFEqual(key,CFSTR(kIOHIDMaxOutputReportSizeKey)))return usbOutput;
 }
 return IOHIDDeviceGetProperty(d,key);
}
INTERPOSE(property,IOHIDDeviceGetProperty);
typedef struct {IOHIDDeviceRef d;IOHIDReportCallback cb;void *ctx;uint8_t buffer[1024];} Reader;
static Reader readers[16];static pthread_mutex_t readersLock=PTHREAD_MUTEX_INITIALIZER;
static void input(void *c,IOReturn result,void *sender,IOHIDReportType type,uint32_t id,uint8_t *bytes,CFIndex length) {
 Reader *r=c;IOHIDReportCallback cb=r->cb;if(!cb)return;
 if(result==0&&id==0x31&&length>=66){uint8_t usb[64]={1};memcpy(usb+1,bytes+2,63);cb(r->ctx,result,sender,type,1,usb,64);}
 else if(result==0&&id==1&&length<=10){/* Ignore the abbreviated BT report until feature 05 enables full reports. */}
 else cb(r->ctx,result,sender,type,id,bytes,length);
}
static void registerInput(IOHIDDeviceRef d,uint8_t *buffer,CFIndex len,IOHIDReportCallback cb,void *ctx) {
 if(!raw||!bluetooth(d)){IOHIDDeviceRegisterInputReportCallback(d,buffer,len,cb,ctx);return;}
 pthread_mutex_lock(&readersLock);Reader *r=NULL;
 for(int i=0;i<16;i++)if(readers[i].d==d){r=readers+i;break;}
 if(!r)for(int i=0;i<16;i++)if(!readers[i].d){r=readers+i;r->d=(IOHIDDeviceRef)CFRetain(d);break;}
 if(r){r->cb=cb;r->ctx=ctx;}
 pthread_mutex_unlock(&readersLock);
 if(!r){IOHIDDeviceRegisterInputReportCallback(d,buffer,len,cb,ctx);return;}
 IOHIDDeviceRegisterInputReportCallback(d,cb?r->buffer:NULL,cb?sizeof(r->buffer):0,cb?input:NULL,cb?r:NULL);
 if(cb){uint8_t f[64]={5};CFIndex n=41;IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,5,f,&n);}
}
INTERPOSE(registerInput,IOHIDDeviceRegisterInputReportCallback);
// USB clients (including Sony's PC library) disable the physical radio after
// enumeration via feature 08/02. The virtual USB transport uses that radio,
// so acknowledge this exact transport-management request locally. Unknown
// feature reports still pass through unchanged.
static bool virtualRadioDisable(IOHIDReportType type,CFIndex id,const uint8_t *b,CFIndex n) {
 if(type!=kIOHIDReportTypeFeature||id!=8||!b||n!=48||b[0]!=8||b[1]!=2)return false;
 for(CFIndex i=2;i<n;i++)if(b[i])return false;
 return true;
}
static IOReturn setReport(IOHIDDeviceRef d,IOHIDReportType type,CFIndex id,const uint8_t *b,CFIndex n) {
 if(raw&&bluetooth(d)&&type==kIOHIDReportTypeFeature){
  static unsigned count; if(count++<20){
   fprintf(stderr,"DSB: feature write pid=%d id=%ld size=%ld head=",getpid(),(long)id,(long)n);
   for(CFIndex i=0;i<MIN(n,8);i++)fprintf(stderr,"%02x",b[i]);fprintf(stderr,"\n");
  }
 }
 if(raw&&bluetooth(d)&&virtualRadioDisable(type,id,b,n)){
  static unsigned handled=0;if(handled++<4)fprintf(stderr,"DSB: virtual USB radio-disable acknowledged; Bluetooth retained\n");
  return kIOReturnSuccess;
 }
 if(raw&&bluetooth(d)&&type==kIOHIDReportTypeOutput&&id==2&&n>=48&&b[0]==2){transmit(DSB_OUTPUT,0,0,b,n);return kIOReturnSuccess;}
 return IOHIDDeviceSetReport(d,type,id,b,n);
}
INTERPOSE(setReport,IOHIDDeviceSetReport);
static IOReturn getReport(IOHIDDeviceRef d,IOHIDReportType type,CFIndex id,uint8_t *b,CFIndex *n) {
 IOReturn r=IOHIDDeviceGetReport(d,type,id,b,n);
 if(raw&&bluetooth(d)){static unsigned count[256];if(id>=0&&id<256&&count[id]++<4)fprintf(stderr,"DSB: HID get type=%d id=%ld size=%ld result=%x\n",type,(long)id,(long)*n,r);}
 return r;
}
INTERPOSE(getReport,IOHIDDeviceGetReport);

// A four-channel endpoint visible only to the Wine processes which load this library.
// Speaker channels 0/1 are discarded. Only haptic channels 2/3 reach Core Haptics.
#define VDEVICE 0x44533542u
#define VSTREAM 0x44533543u
#define VUID CFSTR("DualSenseSteamBridge-Bluetooth-Haptics-v1")
static bool audioEnabled(void){return enabled&&raw;}
static OSStatus copyResult(UInt32 *n,void *out,const void *in,UInt32 size){if(*n<size)return kAudioHardwareBadPropertySizeError;memcpy(out,in,size);*n=size;return noErr;}
static OSStatus virtualProperty(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32 *size,void *data,bool sizeOnly) {
 uint8_t bytes[256]={0};UInt32 n=4,u=0;Float64 rate=48000;Float32 volume=1;CFStringRef s=NULL;
 switch(a->mSelector){
 case kAudioObjectPropertyName:s=CFSTR("DualSense Wireless Controller (Bluetooth Bridge)");break;
 case kAudioDevicePropertyDeviceUID:s=VUID;break;
 case kAudioObjectPropertyManufacturer:s=CFSTR("Local DualSense Steam Bridge");break;
 case kAudioDevicePropertyModelUID:s=CFSTR("054c:0ce6:wireless");break;
 case kAudioDevicePropertyStreamConfiguration:{AudioBufferList list={.mNumberBuffers=a->mScope==kAudioDevicePropertyScopeInput?0:1,.mBuffers={{.mNumberChannels=4}}};n=sizeof(list);memcpy(bytes,&list,n);break;}
 case kAudioDevicePropertyPreferredChannelLayout:return kAudioHardwareUnknownPropertyError;
 case kAudioDevicePropertyNominalSampleRate:n=8;memcpy(bytes,&rate,n);break;
 case kAudioDevicePropertyAvailableNominalSampleRates:{AudioValueRange range={48000,48000};n=sizeof(range);memcpy(bytes,&range,n);break;}
 case kAudioDevicePropertyStreams:u=VSTREAM;memcpy(bytes,&u,4);if(a->mScope==kAudioDevicePropertyScopeInput)n=0;break;
 case kAudioObjectPropertyClass:u=id==VSTREAM?kAudioStreamClassID:kAudioDeviceClassID;memcpy(bytes,&u,4);break;
 case kAudioDevicePropertyTransportType:u=kAudioDeviceTransportTypeUSB;memcpy(bytes,&u,4);break;
 case kAudioDevicePropertyDeviceIsAlive:u=1;memcpy(bytes,&u,4);break;
 case kAudioDevicePropertyBufferFrameSize:u=480;memcpy(bytes,&u,4);break;
 case kAudioDevicePropertyBufferFrameSizeRange:{AudioValueRange range={480,480};n=sizeof(range);memcpy(bytes,&range,n);break;}
 case kAudioDevicePropertyVolumeScalar:memcpy(bytes,&volume,4);break;
 case kAudioDevicePropertyLatency:case kAudioDevicePropertySafetyOffset:case kAudioDevicePropertyMute:break;
 default:return kAudioHardwareUnknownPropertyError;
 }
 if(s){n=sizeof(s);if(!sizeOnly)CFRetain(s);memcpy(bytes,&s,n);}
 if(sizeOnly){*size=n;return noErr;}return copyResult(size,data,bytes,n);
}
static OSStatus objectSize(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32 q,const void *qual,UInt32 *n){
 if(audioEnabled()&&(id==VDEVICE||id==VSTREAM))return virtualProperty(id,a,n,NULL,true);
 OSStatus r=AudioObjectGetPropertyDataSize(id,a,q,qual,n);
 if(audioEnabled()&&r==noErr&&id==kAudioObjectSystemObject&&a->mSelector==kAudioHardwarePropertyDevices)*n+=4;
 return r;
}
INTERPOSE(objectSize,AudioObjectGetPropertyDataSize);
static OSStatus objectData(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32 q,const void *qual,UInt32 *n,void *out){
 if(audioEnabled()){
  if(id==VDEVICE||id==VSTREAM)return virtualProperty(id,a,n,out,false);
  if(id==kAudioObjectSystemObject&&a->mSelector==kAudioHardwarePropertyTranslateUIDToDevice&&q==sizeof(CFStringRef)&&qual&&CFEqual(*(CFStringRef*)qual,VUID)){UInt32 v=VDEVICE;return copyResult(n,out,&v,4);}
  if(id==kAudioObjectSystemObject&&a->mSelector==kAudioHardwarePropertyDevices){UInt32 cap=*n;OSStatus r=AudioObjectGetPropertyData(id,a,q,qual,n,out);if(r==noErr&&cap>=*n+4){((UInt32*)((char*)out+*n))[0]=VDEVICE;*n+=4;}return r;}
 }
 return AudioObjectGetPropertyData(id,a,q,qual,n,out);
}
INTERPOSE(objectData,AudioObjectGetPropertyData);
static Boolean objectHas(AudioObjectID id,const AudioObjectPropertyAddress *a){if(audioEnabled()&&(id==VDEVICE||id==VSTREAM)){UInt32 n;return virtualProperty(id,a,&n,NULL,true)==0;}return AudioObjectHasProperty(id,a);}
INTERPOSE(objectHas,AudioObjectHasProperty);
static OSStatus objectSet(AudioObjectID id,const AudioObjectPropertyAddress *a,UInt32 q,const void *qual,UInt32 n,const void *in){if(audioEnabled()&&(id==VDEVICE||id==VSTREAM))return noErr;return AudioObjectSetPropertyData(id,a,q,qual,n,in);}
INTERPOSE(objectSet,AudioObjectSetPropertyData);
static OSStatus objectListener(AudioObjectID id,const AudioObjectPropertyAddress *a,AudioObjectPropertyListenerProc cb,void *c){if(audioEnabled()&&(id==VDEVICE||id==VSTREAM))return noErr;return AudioObjectAddPropertyListener(id,a,cb,c);}
INTERPOSE(objectListener,AudioObjectAddPropertyListener);
static OSStatus objectUnlisten(AudioObjectID id,const AudioObjectPropertyAddress *a,AudioObjectPropertyListenerProc cb,void *c){if(audioEnabled()&&(id==VDEVICE||id==VSTREAM))return noErr;return AudioObjectRemovePropertyListener(id,a,cb,c);}
INTERPOSE(objectUnlisten,AudioObjectRemovePropertyListener);
typedef struct Unit {AudioUnit unit;AudioStreamBasicDescription fmt;AURenderCallbackStruct callback;pthread_t thread;atomic_bool running;bool started;float volume;struct Unit *next;} Unit;
static Unit *units;static pthread_mutex_t unitLock=PTHREAD_MUTEX_INITIALIZER;
static Unit *getUnit(AudioUnit unit){pthread_mutex_lock(&unitLock);Unit *u=units;while(u&&u->unit!=unit)u=u->next;pthread_mutex_unlock(&unitLock);return u;}
static AudioStreamBasicDescription defaultFormat(void){return (AudioStreamBasicDescription){48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,16,1,16,4,32,0};}
static OSStatus unitSet(AudioUnit unit,AudioUnitPropertyID p,AudioUnitScope scope,AudioUnitElement elem,const void *data,UInt32 n){
 Unit *u=getUnit(unit);
 if(audioEnabled()&&p==kAudioOutputUnitProperty_CurrentDevice&&n==4&&*(UInt32*)data==VDEVICE){
  if(!u){u=calloc(1,sizeof(*u));u->unit=unit;u->fmt=defaultFormat();u->volume=1;pthread_mutex_lock(&unitLock);u->next=units;units=u;pthread_mutex_unlock(&unitLock);}return noErr;
 }
 if(u){
  if(p==kAudioUnitProperty_StreamFormat&&n==sizeof(u->fmt)){
   AudioStreamBasicDescription f=*(AudioStreamBasicDescription*)data;
   if(f.mFormatID!=kAudioFormatLinearPCM||f.mChannelsPerFrame!=4||f.mSampleRate<8000||f.mSampleRate>192000||(f.mFormatFlags&(kAudioFormatFlagIsNonInterleaved|kAudioFormatFlagIsBigEndian))||f.mBytesPerFrame!=4*(f.mBitsPerChannel/8)||f.mFramesPerPacket!=1||((f.mFormatFlags&kAudioFormatFlagIsFloat)&&f.mBitsPerChannel!=32)||!(f.mBitsPerChannel==8||f.mBitsPerChannel==16||f.mBitsPerChannel==32))return kAudioUnitErr_FormatNotSupported;
   if(u->started)return kAudioUnitErr_CannotDoInCurrentContext;
   u->fmt=f;
  }else if(p==kAudioUnitProperty_SetRenderCallback&&n==sizeof(u->callback))u->callback=*(AURenderCallbackStruct*)data;
  return noErr;
 }
 return AudioUnitSetProperty(unit,p,scope,elem,data,n);
}
INTERPOSE(unitSet,AudioUnitSetProperty);
static OSStatus unitGet(AudioUnit unit,AudioUnitPropertyID p,AudioUnitScope scope,AudioUnitElement elem,void *data,UInt32 *n){Unit *u=getUnit(unit);if(u){if(p==kAudioUnitProperty_StreamFormat)return copyResult(n,data,&u->fmt,sizeof(u->fmt));UInt32 v=p==kAudioUnitProperty_MaximumFramesPerSlice?4096:0;return copyResult(n,data,&v,4);}return AudioUnitGetProperty(unit,p,scope,elem,data,n);}
INTERPOSE(unitGet,AudioUnitGetProperty);
static OSStatus unitInit(AudioUnit unit){if(getUnit(unit))return 0;return AudioUnitInitialize(unit);}
INTERPOSE(unitInit,AudioUnitInitialize);
static OSStatus unitUninit(AudioUnit unit){if(getUnit(unit))return 0;return AudioUnitUninitialize(unit);}
INTERPOSE(unitUninit,AudioUnitUninitialize);
static float sample(const uint8_t *b,const AudioStreamBasicDescription *f){if(f->mFormatFlags&kAudioFormatFlagIsFloat){float v;memcpy(&v,b,4);return isfinite(v)?v:0;}if(f->mBitsPerChannel==16){int16_t v;memcpy(&v,b,2);return v/32768.f;}if(f->mBitsPerChannel==32){int32_t v;memcpy(&v,b,4);return v/2147483648.f;}return ((int)*b-128)/128.f;}
static void *render(void *ctx){Unit *u=ctx;unsigned frames=(unsigned)(u->fmt.mSampleRate/100);size_t size=frames*u->fmt.mBytesPerFrame;uint8_t *buf=calloc(1,size);double frameTime=0;
 DSBResampler resampler;DSBResamplerInit(&resampler,u->fmt.mSampleRate);
 static atomic_uint nextStream;uint32_t stream=atomic_fetch_add(&nextStream,1)+1;
 uint8_t pcm[64]={0,(uint8_t)stream,(uint8_t)(stream>>8),(uint8_t)(stream>>16)};unsigned count=0;
 double next=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1e9;
 pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
 while(atomic_load(&u->running)){
  memset(buf,0,size);AudioBufferList list={.mNumberBuffers=1,.mBuffers={{4,(UInt32)size,buf}}};AudioUnitRenderActionFlags flags=0;AudioTimeStamp ts={.mSampleTime=frameTime,.mHostTime=mach_absolute_time(),.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid};
  OSStatus result=u->callback.inputProc?u->callback.inputProc(u->callback.inputProcRefCon,&flags,&ts,0,frames,&list):0;
  if(result)memset(buf,0,size);
  float l=0,r=0;unsigned stride=u->fmt.mBytesPerFrame,bytes=u->fmt.mBitsPerChannel/8;
  for(unsigned i=0;i<frames;i++){
   float left=sample(buf+i*stride+bytes*2,&u->fmt)*u->volume,right=sample(buf+i*stride+bytes*3,&u->fmt)*u->volume;
   l=fmaxf(l,fabsf(left));r=fmaxf(r,fabsf(right));
   if(pcmMode){int8_t out[2];if(DSBResample(&resampler,left,right,out)){
    memcpy(pcm+4+count*2,out,2);if(++count==30){pcm[0]=30;transmit(DSB_PCM,0,0,pcm,64);count=0;}
   }}
  }
  if(!pcmMode)transmit(DSB_LEVEL,fminf(1,l),fminf(1,r),NULL,0);
  frameTime+=frames;next+=frames/u->fmt.mSampleRate;double now=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1e9;
  if(now-next>.04)next=now;
  while(atomic_load(&u->running)&&(now=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1e9)<next){double remain=next-now;if(remain>.0005)usleep((remain-.0003)*1e6);}
 }
 if(pcmMode){pcm[0]=0;memset(pcm+4,0,60);transmit(DSB_PCM,0,0,pcm,64);}else transmit(DSB_LEVEL,0,0,NULL,0);
 free(buf);return NULL;
}
static OSStatus unitStart(AudioUnit unit){Unit *u=getUnit(unit);if(!u)return AudioOutputUnitStart(unit);if(!u->started){atomic_store(&u->running,true);if(pthread_create(&u->thread,NULL,render,u))return kAudioUnitErr_FailedInitialization;u->started=true;fprintf(stderr,"DSB: virtual haptic stream started, 4 channels %.0f Hz\n",u->fmt.mSampleRate);}return 0;}
INTERPOSE(unitStart,AudioOutputUnitStart);
static OSStatus unitStop(AudioUnit unit){Unit *u=getUnit(unit);if(!u)return AudioOutputUnitStop(unit);if(u->started){atomic_store(&u->running,false);pthread_join(u->thread,NULL);u->started=false;}return 0;}
INTERPOSE(unitStop,AudioOutputUnitStop);
static OSStatus unitDispose(AudioComponentInstance unit){Unit *u=getUnit(unit);if(u){unitStop(unit);pthread_mutex_lock(&unitLock);Unit **p=&units;while(*p&&*p!=u)p=&(*p)->next;if(*p)*p=u->next;pthread_mutex_unlock(&unitLock);free(u);}return AudioComponentInstanceDispose(unit);}
INTERPOSE(unitDispose,AudioComponentInstanceDispose);
static OSStatus unitParam(AudioUnit unit,AudioUnitParameterID p,AudioUnitScope s,AudioUnitElement e,AudioUnitParameterValue v,UInt32 o){Unit *u=getUnit(unit);if(u){if(p==kHALOutputParam_Volume)u->volume=fmaxf(0,fminf(1,v));return 0;}return AudioUnitSetParameter(unit,p,s,e,v,o);}
INTERPOSE(unitParam,AudioUnitSetParameter);
