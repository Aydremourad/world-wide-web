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
    const int dimensions[][2]={{256,144},{255,143},{1,1},{2,1},{1,2},{17,9},
        {640,360},{639,359},{320,240},{144,256}};
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
        int scaled=w>256 || h>144;
        double scale=1;
        if(w>256) scale=256.0/w;
        if(h*scale>144) scale=144.0/h;
        int outputW=(int)(w*scale),outputH=(int)(h*scale);
        for(int variant=0;variant<(scaled ? 16 : 256);variant++) {
            for(int p=0;p<3;p++) {
                int rows=p ? (h+1)/2 : h;
                for(int row=0;row<rows;row++) for(int col=0;col<frame->linesize[p];col++)
                    frame->data[p][row*frame->linesize[p]+col]=(variant+col*17+row*31+p*67)&255;
            }
            assert(YTConvertVideoFrame(&image,frame)==0);
            assert(image.width==outputW && image.height==outputH && image.pixelBytes==outputW*outputH*2);
            if(scaled) assert(!image.scaler); // No intermediate swscale planes.
            for(int row=0;row<outputH;row++) for(int col=0;col<outputW;col++) {
                int sourceY=row*h/outputH,sourceX=col*w/outputW;
                int y=frame->data[0][sourceY*frame->linesize[0]+sourceX];
                if(scaled && w>=2*outputW && h>=2*outputH) {
                    int sum=0;
                    for(int dy=0;dy<2;dy++) for(int dx=0;dx<2;dx++)
                        sum+=frame->data[0][(sourceY+dy)*frame->linesize[0]+sourceX+dx];
                    y=(sum+2)/4;
                }
                int u=frame->data[1][(sourceY/2)*frame->linesize[1]+sourceX/2];
                int v=frame->data[2][(sourceY/2)*frame->linesize[2]+sourceX/2];
                assert(((uint16_t *)image.pixels)[row*outputW+col]==reference(y,u,v)); compared++;
            }
        }
        for(int p=0;p<3;p++) { free(frame->data[p]); frame->data[p]=NULL; }
    }
    YTFreeVideoImage(&image); av_frame_free(&frame);
    printf("RGB565 passed: %u exact reference pixels, saturated colors, odd sizes and padded planes.\n",compared);
    return 0;
}
