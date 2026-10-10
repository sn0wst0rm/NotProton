#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

// State is retained for comparison, but valid bits are transactions. Replaying
// a stale LED/player color alongside every trigger update fights Steam/macOS.
static inline bool DSBControlDelta(const uint8_t state[47],const uint8_t previous[47],bool known,uint8_t out[47]) {
 memset(out,0,47);
 const unsigned flags[]={0,0,1,1,1},bits[]={4,8,4,16,1};
 const unsigned offsets[]={10,21,44,43,8},lengths[]={11,11,3,1,1};
 bool changed=false;
 for(unsigned i=0;i<5;i++){
  unsigned f=flags[i],bit=bits[i],off=offsets[i],len=lengths[i];
  if((state[f]&bit)&&(!known||!(previous[f]&bit)||memcmp(state+off,previous+off,len))){
   out[f]|=bit;memcpy(out+off,state+off,len);changed=true;
  }
 }
 return changed;
}
