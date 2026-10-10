#include "Controls.h"
#include <assert.h>
#include <stdio.h>
int main(void){
 uint8_t state[47]={0},previous[47]={0},out[47];
 state[1]=4|16;state[44]=217;state[45]=255;state[43]=4;
 assert(DSBControlDelta(state,previous,false,out));assert(out[1]==20);
 memcpy(previous,state,47);
 state[0]=4;state[10]=0x21;state[11]=0xfe;
 assert(DSBControlDelta(state,previous,true,out));assert(out[0]==4&&out[1]==0);
 assert(out[43]==0&&out[44]==0&&out[45]==0);
 memcpy(previous,state,47);assert(!DSBControlDelta(state,previous,true,out));
 state[10]=5;state[11]=0;
 assert(DSBControlDelta(state,previous,true,out));assert(out[0]==4&&out[10]==5&&out[1]==0);
 memcpy(previous,state,47);state[44]=0;state[45]=0;
 assert(DSBControlDelta(state,previous,true,out));assert(out[0]==0&&out[1]==4);
 memcpy(previous,state,47);state[43]=2;
 assert(DSBControlDelta(state,previous,true,out));assert(out[0]==0&&out[1]==16&&out[43]==2);
 puts("PASS: changing triggers/rumble never replays old RGB/player state; actual color/release changes preserved");
}
