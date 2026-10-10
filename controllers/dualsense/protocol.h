#pragma once
#include <stdint.h>
#define DSB_MAGIC 0x31425344u
#define DSB_LEVEL 1
#define DSB_OUTPUT 2
#define DSB_PCM 3
// report[0]: frame count (0=end, 30=10ms), report[1..3]: stream ID,
// report[4..63]: 30 signed-8-bit stereo PCM frames at 3000 Hz.
typedef struct __attribute__((packed)) {
 uint32_t magic, kind;
 uint8_t token[16];
 uint32_t pid, sequence;
 double timestamp;
 float left, right;
 uint8_t report[64];
} DSBPacket;
