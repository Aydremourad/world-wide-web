/*
 * Exact 8-bit H.264 motion compensation for ARM11.
 * Copyright (c) 2026 Aydre Mourad
 * LGPL-2.1-or-later, matching the FFmpeg library into which this is included.
 * No interpolation approximation: preserve the H.264 six-tap filter and rounding.
 */
#ifndef YT_ARM11_MOTION_H
#define YT_ARM11_MOTION_H
#include <stdint.h>
#include <stddef.h>
#include "config.h"
#include "libavutil/attributes.h"
#include "libavcodec/h264qpel.h"
#include "libavcodec/h264chroma.h"

static av_always_inline uint32_t yt_pair(const uint8_t *p) {
    return p[0]|((uint32_t)p[1]<<16);
}
static av_always_inline uint32_t yt_add16(uint32_t a,uint32_t b) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    uint32_t r; __asm__("sadd16 %0, %1, %2":"=r"(r):"r"(a),"r"(b)); return r;
#else
    return ((a+b)&0xffff)|(((a>>16)+(b>>16))<<16);
#endif
}
static av_always_inline uint32_t yt_sub16(uint32_t a,uint32_t b) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    uint32_t r; __asm__("ssub16 %0, %1, %2":"=r"(r):"r"(a),"r"(b)); return r;
#else
    return ((a-b)&0xffff)|(((a>>16)-(b>>16))<<16);
#endif
}
static av_always_inline int yt_clip_shift5(int n) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    unsigned r; __asm__("usat %0, #8, %1, asr #5":"=r"(r):"r"(n)); return r;
#else
    n>>=5; return n<0 ? 0 : n>255 ? 255 : n;
#endif
}
static av_always_inline int yt_clip_shift10(int n) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    unsigned r; __asm__("usat %0, #8, %1, asr #10":"=r"(r):"r"(n)); return r;
#else
    n>>=10; return n<0 ? 0 : n>255 ? 255 : n;
#endif
}
static av_always_inline uint32_t yt_filter(uint32_t a,uint32_t b,uint32_t c,
                                          uint32_t d,uint32_t e,uint32_t f) {
    // Positive products fit each lane; lane-wise subtraction prevents borrows.
    return yt_add16(yt_sub16(yt_add16(c,d)*20,yt_add16(b,e)*5),yt_add16(a,f));
}
static av_always_inline uint32_t yt_filter_pixels(uint32_t value) {
    value=yt_add16(value,0x00100010);
    return yt_clip_shift5((int16_t)value)|((uint32_t)yt_clip_shift5((int32_t)value>>16)<<16);
}
static av_always_inline uint32_t yt_average(uint32_t a,uint32_t b) {
    return ((a+b+0x00010001)>>1)&0x00ff00ff;
}
static av_always_inline void yt_store_pair(uint8_t *dst,uint32_t value,int average) {
    if(average) value=yt_average(value,yt_pair(dst));
    dst[0]=(uint8_t)value; dst[1]=(uint8_t)(value>>16);
}
static av_always_inline void yt_horizontal(uint8_t *out,const uint8_t *src,int stride,int size,
                                            int outStride,int quarter,int average) {
    for(int y=0;y<size;y++) {
        for(int x=0;x<size;x+=2) {
            const uint8_t *p=src+x;
            uint32_t value=yt_filter_pixels(yt_filter(yt_pair(p-2),yt_pair(p-1),yt_pair(p),
                yt_pair(p+1),yt_pair(p+2),yt_pair(p+3)));
            if(quarter>=0) value=yt_average(value,yt_pair(p+quarter));
            yt_store_pair(out+x,value,average);
        }
        src+=stride; out+=outStride;
    }
}
static av_always_inline void yt_vertical(uint8_t *out,const uint8_t *src,int stride,int size,
                                          int outStride,int quarter,int average) {
    // Keep a six-row window in registers and load only the entering row.
    for(int x=0;x<size;x+=2) {
        const uint8_t *p=src+x;
        uint8_t *destination=out+x;
        uint32_t a=yt_pair(p-2*stride),b=yt_pair(p-stride),c=yt_pair(p);
        uint32_t d=yt_pair(p+stride),e=yt_pair(p+2*stride),f=yt_pair(p+3*stride);
        for(int y=0;y<size;y++) {
            uint32_t value=yt_filter_pixels(yt_filter(a,b,c,d,e,f));
            if(quarter>=0) value=yt_average(value,yt_pair(p+quarter*stride));
            yt_store_pair(destination,value,average); destination+=outStride;
            if(y+1<size) { p+=stride; a=b; b=c; c=d; d=e; e=f; f=yt_pair(p+3*stride); }
        }
    }
}
static av_always_inline void yt_diagonal(uint8_t *out,const uint8_t *src,int stride,int size,int outStride,int average) {
    int16_t tmp[21*16];
    for(int y=0;y<size+5;y++) {
        const uint8_t *row=src+(y-2)*stride;
        for(int x=0;x<size;x+=2) {
            const uint8_t *p=row+x;
            uint32_t v=yt_filter(yt_pair(p-2),yt_pair(p-1),yt_pair(p),
                yt_pair(p+1),yt_pair(p+2),yt_pair(p+3));
            tmp[y*size+x]=(int16_t)v; tmp[y*size+x+1]=(int16_t)(v>>16);
        }
    }
    for(int x=0;x<size;x++) {
        const int16_t *p=tmp+x;
        int a=p[0],b=p[size],c=p[2*size],d=p[3*size],e=p[4*size],f=p[5*size];
        for(int y=0;y<size;y++) {
            int pixel=yt_clip_shift10((c+d)*20-(b+e)*5+a+f+512);
            if(average) pixel=(pixel+out[y*outStride+x]+1)>>1;
            out[y*outStride+x]=(uint8_t)pixel;
            if(y+1<size) { p+=size; a=b; b=c; c=d; d=e; e=f; f=p[5*size]; }
        }
    }
}
static av_always_inline void yt_qpel(uint8_t *dst,const uint8_t *src,ptrdiff_t stride,
                                    int size,int x,int y,int average) {
    uint8_t h[256],v[256],j[256];
    const uint8_t *first=src,*second=NULL;
    int firstStride=(int)stride,secondStride=size;
    // Axis-only phases filter straight into the destination; do not allocate,
    // write, and reread a temporary block merely to copy it to the frame.
    if(!y && x) {
        yt_horizontal(dst,src,(int)stride,size,(int)stride,x==2 ? -1 : x==3,average); return;
    } else if(!x && y) {
        yt_vertical(dst,src,(int)stride,size,(int)stride,y==2 ? -1 : y==3,average); return;
    } else if(x==2 && y==2) {
        yt_diagonal(dst,src,(int)stride,size,(int)stride,average); return;
    } else if(x && y) {
        if((x&1) && (y&1)) {
            yt_horizontal(h,src+(y==3 ? stride : 0),(int)stride,size,size,-1,0);
            yt_vertical(v,src+(x==3),(int)stride,size,size,-1,0);
            first=h; firstStride=size; second=v;
        } else {
            yt_diagonal(j,src,(int)stride,size,size,0); first=j; firstStride=size;
            if(y&1) { yt_horizontal(h,src+(y==3 ? stride : 0),(int)stride,size,size,-1,0); second=h; }
            else if(x&1) { yt_vertical(v,src+(x==3),(int)stride,size,size,-1,0); second=v; }
        }
    }
    for(int row=0;row<size;row++) {
        for(int col=0;col<size;col+=2) {
            uint32_t p=yt_pair(first+col);
            if(second) p=yt_average(p,yt_pair(second+col));
            yt_store_pair(dst+col,p,average);
        }
        dst+=stride; first+=firstStride; if(second) second+=secondStride;
    }
}
#define YT_QPEL_ONE(S,X,Y) \
static void yt_put##S##_##X##Y(uint8_t *d,const uint8_t *s,ptrdiff_t st) { yt_qpel(d,s,st,S,X,Y,0); } \
static void yt_avg##S##_##X##Y(uint8_t *d,const uint8_t *s,ptrdiff_t st) { yt_qpel(d,s,st,S,X,Y,1); }
#define YT_QPEL_ROW(S,Y) YT_QPEL_ONE(S,0,Y) YT_QPEL_ONE(S,1,Y) YT_QPEL_ONE(S,2,Y) YT_QPEL_ONE(S,3,Y)
#define YT_QPEL_SIZE(S) YT_QPEL_ROW(S,0) YT_QPEL_ROW(S,1) YT_QPEL_ROW(S,2) YT_QPEL_ROW(S,3)
YT_QPEL_SIZE(16) YT_QPEL_SIZE(8) YT_QPEL_SIZE(4) YT_QPEL_SIZE(2)
#define YT_QPEL_SET(S,I,X,Y) c->put_h264_qpel_pixels_tab[I][4*Y+X]=yt_put##S##_##X##Y; c->avg_h264_qpel_pixels_tab[I][4*Y+X]=yt_avg##S##_##X##Y;
#define YT_QPEL_SET_ROW(S,I,Y) YT_QPEL_SET(S,I,0,Y) YT_QPEL_SET(S,I,1,Y) YT_QPEL_SET(S,I,2,Y) YT_QPEL_SET(S,I,3,Y)
#define YT_QPEL_SET_SIZE(S,I) YT_QPEL_SET(S,I,1,0) YT_QPEL_SET(S,I,2,0) YT_QPEL_SET(S,I,3,0) YT_QPEL_SET_ROW(S,I,1) YT_QPEL_SET_ROW(S,I,2) YT_QPEL_SET_ROW(S,I,3)
static void yt_h264qpel_arm11_init(H264QpelContext *c) {
    YT_QPEL_SET_SIZE(16,0) YT_QPEL_SET_SIZE(8,1) YT_QPEL_SET_SIZE(4,2) YT_QPEL_SET_SIZE(2,3)
}
static av_always_inline void yt_chroma(uint8_t *dst,const uint8_t *src,int stride,int height,int x,int y,int width,int avg) {
    const int a=(8-x)*(8-y),b=x*(8-y),c=(8-x)*y,d=x*y;
    if(d) {
        for(int row=0;row<height;row++) {
            for(int col=0;col<width;col+=2) {
                const uint8_t *p=src+col;
                uint32_t value=a*yt_pair(p)+b*yt_pair(p+1)+c*yt_pair(p+stride)+d*yt_pair(p+stride+1);
                value=((value+0x00200020)>>6)&0x00ff00ff;
                yt_store_pair(dst+col,value,avg);
            }
            dst+=stride; src+=stride;
        }
    } else if(b+c) {
        const int weight=b+c,step=c ? stride : 1;
        for(int row=0;row<height;row++) {
            for(int col=0;col<width;col+=2) {
                const uint8_t *p=src+col;
                uint32_t value=a*yt_pair(p)+weight*yt_pair(p+step);
                value=((value+0x00200020)>>6)&0x00ff00ff;
                yt_store_pair(dst+col,value,avg);
            }
            dst+=stride; src+=stride;
        }
    } else {
        for(int row=0;row<height;row++) {
            for(int col=0;col<width;col+=2) yt_store_pair(dst+col,yt_pair(src+col),avg);
            dst+=stride; src+=stride;
        }
    }
}
#define YT_CHROMA_SIZE(S) \
static void yt_put_chroma##S(uint8_t *d,uint8_t *s,int st,int h,int x,int y) { yt_chroma(d,s,st,h,x,y,S,0); } \
static void yt_avg_chroma##S(uint8_t *d,uint8_t *s,int st,int h,int x,int y) { yt_chroma(d,s,st,h,x,y,S,1); }
YT_CHROMA_SIZE(8) YT_CHROMA_SIZE(4) YT_CHROMA_SIZE(2)
static void yt_h264chroma_arm11_init(H264ChromaContext *c) {
    c->put_h264_chroma_pixels_tab[0]=yt_put_chroma8; c->avg_h264_chroma_pixels_tab[0]=yt_avg_chroma8;
    c->put_h264_chroma_pixels_tab[1]=yt_put_chroma4; c->avg_h264_chroma_pixels_tab[1]=yt_avg_chroma4;
    c->put_h264_chroma_pixels_tab[2]=yt_put_chroma2; c->avg_h264_chroma_pixels_tab[2]=yt_avg_chroma2;
}
#endif
