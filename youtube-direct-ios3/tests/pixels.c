#include "YTVideoDecoder.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static int clip(int value) { return value<0 ? 0 : value>255 ? 255 : value; }
static uint16_t reference(int y,int u,int v) {
    int yy=298*(y-16),uu=u-128,vv=v-128;
    int r=clip((yy+409*vv+128)>>8);
    int g=clip((yy-100*uu-208*vv+128)>>8);
    int b=clip((yy+516*uu+128)>>8);
    return ((r&0xf8)<<8)|((g&0xfc)<<3)|(b>>3);
}
int main(void) {
    const int dimensions[][2]={{256,144},{255,143},{1,1},{2,1},{1,2},{17,9}};
    YTVideoImage image={0}; AVFrame *frame=av_frame_alloc(); assert(frame);
    unsigned compared=0;
    for(unsigned d=0;d<sizeof(dimensions)/sizeof(dimensions[0]);d++) {
        int w=dimensions[d][0],h=dimensions[d][1];
        frame->format=AV_PIX_FMT_YUV420P; frame->width=w; frame->height=h;
        frame->linesize[0]=w+13; frame->linesize[1]=frame->linesize[2]=(w+1)/2+11;
        for(int p=0;p<3;p++) {
            int rows=p ? (h+1)/2 : h;
            frame->data[p]=malloc(frame->linesize[p]*rows); assert(frame->data[p]);
        }
        for(int variant=0;variant<256;variant++) {
            for(int p=0;p<3;p++) {
                int rows=p ? (h+1)/2 : h;
                for(int row=0;row<rows;row++) for(int col=0;col<frame->linesize[p];col++)
                    frame->data[p][row*frame->linesize[p]+col]=(variant+col*17+row*31+p*67)&255;
            }
            assert(YTConvertVideoFrame(&image,frame)==0);
            assert(image.width==w && image.height==h && image.pixelBytes==w*h*2);
            for(int row=0;row<h;row++) for(int col=0;col<w;col++) {
                int y=frame->data[0][row*frame->linesize[0]+col];
                int u=frame->data[1][(row/2)*frame->linesize[1]+col/2];
                int v=frame->data[2][(row/2)*frame->linesize[2]+col/2];
                assert(((uint16_t *)image.pixels)[row*w+col]==reference(y,u,v)); compared++;
            }
        }
        for(int p=0;p<3;p++) { free(frame->data[p]); frame->data[p]=NULL; }
    }
    YTFreeVideoImage(&image); av_frame_free(&frame);
    printf("RGB565 passed: %u exact reference pixels, saturated colors, odd sizes and padded planes.\n",compared);
    return 0;
}
