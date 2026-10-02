/* Differential test against FFmpeg 2.8's LGPL-2.1-or-later C CABAC decoder. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "libavcodec/cabac_functions.h"
#if !HAVE_ARMV6_INLINE
#error This regression must execute the ARMv6 assembly path.
#endif
static uint32_t randomState=0x19642007;
static uint32_t nextRandom(void) {
    randomState^=randomState<<13; randomState^=randomState>>17;
    return randomState^=randomState<<5;
}
static int reference(CABACContext *c,uint8_t *state) {
    int s=*state;
    int lps=ff_h264_lps_range[2*(c->range&0xc0)+s];
    c->range-=lps;
    int mask=((c->range<<17)-c->low)>>31;
    c->low-=(c->range<<17)&mask;
    c->range+=(lps-c->range)&mask;
    s^=mask; *state=(ff_h264_mlps_state+128)[s];
    int shift=ff_h264_norm_shift[c->range];
    c->range<<=shift; c->low<<=shift;
    if(!(c->low&0xffff)) {
        unsigned x=c->low^(c->low-1);
        int n=7-ff_h264_norm_shift[x>>15];
        x=(unsigned)-65535+(c->bytestream[0]<<9)+(c->bytestream[1]<<1);
        c->low+=x<<n;
#if !UNCHECKED_BITSTREAM_READER
        if(c->bytestream<c->bytestream_end)
#endif
            c->bytestream+=2;
    }
    return s&1;
}
int main(void) {
    ff_init_cabac_states();
    assert(ff_h264_lps_range[0]>0 && ff_h264_norm_shift[2]>0);
    uint8_t bytes[32];
    for(int i=0;i<32;i++) bytes[i]=(uint8_t)nextRandom();
    for(int i=0;i<1000000;i++) {
        CABACContext a={0};
        a.range=256+(nextRandom()&255);
        a.low=(nextRandom()%((unsigned)a.range<<17))|1;
        // Exercise valid refill sentinels and odd/even byte pointers.
        if(i%4==0) a.low=((nextRandom()%(2*a.range))|1)<<16;
        a.bytestream=bytes+(i&1); a.bytestream_end=bytes+16;
        if(i%7==0) a.bytestream_end=a.bytestream;
        CABACContext b=a;
        uint8_t sa=nextRandom()&127,sb=sa;
        int expected=reference(&a,&sa),actual=get_cabac_inline(&b,&sb);
        if(expected!=actual || sa!=sb || a.low!=b.low || a.range!=b.range || a.bytestream!=b.bytestream) {
            fprintf(stderr,"CABAC mismatch at %d: bit %d/%d state %u/%u low %d/%d range %d/%d\n",
                i,expected,actual,sa,sb,a.low,b.low,a.range,b.range); return 1;
        }
    }
    puts("ARM11 CABAC passed: 1,000,000 bit/state/range/refill comparisons against the C decoder.");
    return 0;
}
