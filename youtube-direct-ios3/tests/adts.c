#include "../YTADTS.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void header(uint8_t *b,unsigned frequency,unsigned channels,unsigned size,int crc) {
    memset(b,0,size); b[0]=0xff; b[1]=crc ? 0xf0 : 0xf1;
    b[2]=(uint8_t)(0x40|(frequency<<2)|(channels>>2));
    b[3]=(uint8_t)((channels<<6)|(size>>11)); b[4]=(uint8_t)(size>>3);
    b[5]=(uint8_t)((size<<5)|0x1f); b[6]=0xfc;
}
int main(void) {
    uint8_t bytes[64]; YTADTSFrame f;
    header(bytes,4,2,32,0);
    for(unsigned i=0;i<32;i++) assert(YTReadADTSHeader(bytes,i,&f)==0);
    assert(YTReadADTSHeader(bytes,32,&f)==1);
    assert(f.rate==44100 && f.channels==2 && f.headerBytes==7 && f.frameBytes==32);
    assert(f.cookie[0]==0x12 && f.cookie[1]==0x10);
    uint8_t cookie[YT_AAC_MAGIC_COOKIE_BYTES]; YTMakeAACMagicCookie(cookie,f.cookie);
    assert(cookie[0]==3 && cookie[4]==28 && cookie[8]==4 && cookie[12]==20);
    assert(cookie[13]==0x40 && cookie[14]==0x15 && cookie[26]==5 && cookie[30]==2);
    assert(cookie[31]==0x12 && cookie[32]==0x10);
    header(bytes,3,1,33,1);
    assert(YTReadADTSHeader(bytes,33,&f)==1 && f.rate==48000 && f.channels==1 && f.headerBytes==9);
    assert(f.cookie[0]==0x11 && f.cookie[1]==0x88);
    bytes[6]|=1; assert(YTReadADTSHeader(bytes,33,&f)==-1);
    header(bytes,15,2,32,0); assert(YTReadADTSHeader(bytes,32,&f)==-1);
    header(bytes,4,0,32,0); assert(YTReadADTSHeader(bytes,32,&f)==-1);
    header(bytes,4,2,32,0); bytes[2]|=0x80; assert(YTReadADTSHeader(bytes,32,&f)==-1);
    header(bytes,4,2,32,0); bytes[0]=0; assert(YTReadADTSHeader(bytes,32,&f)==-1);
    puts("ADTS passed: AAC-LC cookies, mono/stereo rates, CRC, truncation and invalid formats.");
    return 0;
}
