#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static unsigned calls;
static OSStatus render(void *ctx,AudioUnitRenderActionFlags *f,const AudioTimeStamp *t,UInt32 bus,UInt32 n,AudioBufferList *list){
 assert(list->mNumberBuffers==1);float *samples=list->mBuffers[0].mData;
 for(unsigned i=0;i<n;i++){samples[i*4]=1;samples[i*4+1]=1;samples[i*4+2]=.125;samples[i*4+3]=.5;}
 calls++;return 0;
}
int main(void){
 AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 n=0;
 assert(!AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&n));AudioObjectID *ids=calloc(1,n);assert(!AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&n,ids));
 bool found=false;for(unsigned i=0;i<n/4;i++)if(ids[i]==0x44533542)found=true;free(ids);assert(found);
 AudioComponentDescription d={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};AudioComponent comp=AudioComponentFindNext(NULL,&d);assert(comp);AudioComponentInstance unit;assert(!AudioComponentInstanceNew(comp,&unit));
 UInt32 dev=0x44533542;assert(!AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&dev,4));
 AudioStreamBasicDescription fmt={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,16,1,16,4,32,0};assert(!AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&fmt,sizeof(fmt)));
 AURenderCallbackStruct cb={render,NULL};assert(!AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb)));
 assert(!AudioUnitInitialize(unit));assert(!AudioOutputUnitStart(unit));usleep(150000);assert(!AudioOutputUnitStop(unit));assert(calls>=5);
 assert(!AudioUnitUninitialize(unit));assert(!AudioComponentInstanceDispose(unit));printf("PASS callbacks=%u\n",calls);
}
