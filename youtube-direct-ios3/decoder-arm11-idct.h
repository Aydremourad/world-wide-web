/* Exact ARM11 H.264 4x4 inverse transform. LGPL-2.1-or-later.
 * Transform and block dispatch follow FFmpeg's h264idct_template.c,
 * Copyright (c) 2004-2011 Michael Niedermayer. ARM11 helpers (c) 2026 Aydre Mourad.
 */
#ifndef YT_ARM11_IDCT_H
#define YT_ARM11_IDCT_H
#include <string.h>
#include "decoder-arm11-motion.h"
#include "libavcodec/h264dsp.h"
static av_always_inline uint32_t yt_half16(uint32_t a) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    uint32_t r; __asm__("shadd16 %0, %1, %2":"=r"(r):"r"(a),"r"(0)); return r;
#else
    return (uint16_t)((int16_t)a>>1)|((uint32_t)(uint16_t)((int32_t)a>>17)<<16);
#endif
}
static av_always_inline uint32_t yt_coeff_pair(const int16_t *p) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    // FFmpeg aligns transform blocks to 16 bytes; each pair is word aligned.
    uint32_t r; __asm__("ldr %0, [%1]":"=r"(r):"r"(p):"memory"); return r;
#else
    return (uint16_t)p[0]|((uint32_t)(uint16_t)p[1]<<16);
#endif
}
static av_always_inline void yt_store_coeffs(int16_t *p,uint32_t v) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    __asm__("str %0, [%1]"::"r"(v),"r"(p):"memory");
#else
    p[0]=(int16_t)v; p[1]=(int16_t)(v>>16);
#endif
}
static av_always_inline int yt_clip_shift6(int n) {
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
    unsigned r; __asm__("usat %0, #8, %1, asr #6":"=r"(r):"r"(n)); return r;
#else
    n>>=6; return n<0 ? 0 : n>255 ? 255 : n;
#endif
}
static void yt_idct4_add(uint8_t *dst,int16_t *block,int stride) {
    block[0]+=32;
    for(int i=0;i<4;i+=2) {
        uint32_t a=yt_coeff_pair(block+i),b=yt_coeff_pair(block+i+4);
        uint32_t c=yt_coeff_pair(block+i+8),d=yt_coeff_pair(block+i+12);
        uint32_t z0=yt_add16(a,c),z1=yt_sub16(a,c);
        uint32_t z2=yt_sub16(yt_half16(b),d),z3=yt_add16(b,yt_half16(d));
        yt_store_coeffs(block+i,yt_add16(z0,z3)); yt_store_coeffs(block+i+4,yt_add16(z1,z2));
        yt_store_coeffs(block+i+8,yt_sub16(z1,z2)); yt_store_coeffs(block+i+12,yt_sub16(z0,z3));
    }
    // The final pass needs 32-bit intermediates before clipping, even when
    // corrupted coefficients overflow the signed 16-bit first pass.
    for(int i=0;i<4;i++) {
        const int16_t *p=block+4*i;
        int z0=p[0]+p[2],z1=p[0]-p[2],z2=(p[1]>>1)-p[3],z3=p[1]+(p[3]>>1);
        dst[i]=yt_clip_shift6((dst[i]<<6)+z0+z3);
        dst[i+stride]=yt_clip_shift6((dst[i+stride]<<6)+z1+z2);
        dst[i+2*stride]=yt_clip_shift6((dst[i+2*stride]<<6)+z1-z2);
        dst[i+3*stride]=yt_clip_shift6((dst[i+3*stride]<<6)+z0-z3);
    }
    memset(block,0,32);
}
static void yt_idct4_dc_add(uint8_t *dst,int16_t *block,int stride) {
    int dc=(block[0]+32)>>6; block[0]=0;
    uint32_t pair=(uint16_t)dc|((uint32_t)(uint16_t)dc<<16);
    for(int y=0;y<4;y++) {
        for(int x=0;x<4;x+=2) {
            uint32_t value=yt_add16(yt_pair(dst+x),pair);
#if HAVE_ARMV6_INLINE && !defined(__thumb__)
            __asm__("usat16 %0, #8, %1":"=r"(value):"r"(value));
#else
            int a=(int16_t)value,b=(int32_t)value>>16;
            value=(a<0 ? 0 : a>255 ? 255 : a)|((uint32_t)(b<0 ? 0 : b>255 ? 255 : b)<<16);
#endif
            yt_store_pair(dst+x,value,0);
        }
        dst+=stride;
    }
}
// FFmpeg's nonzero-count positions for 4:2:0, including the gap between U/V.
static const uint8_t yt_idct_scan[36]={12,13,20,21,14,15,22,23,28,29,36,37,30,31,38,39,
    52,53,60,61,54,55,62,63,68,69,76,77,70,71,78,79,92,93,100,101};
static void yt_idct_add16(uint8_t *dst,const int *offset,int16_t *block,int stride,const uint8_t *nnzc) {
    for(int i=0;i<16;i++) {
        int nnz=nnzc[yt_idct_scan[i]];
        if(nnz) {
            if(nnz==1 && block[i*16]) yt_idct4_dc_add(dst+offset[i],block+i*16,stride);
            else yt_idct4_add(dst+offset[i],block+i*16,stride);
        }
    }
}
static void yt_idct_add16intra(uint8_t *dst,const int *offset,int16_t *block,int stride,const uint8_t *nnzc) {
    for(int i=0;i<16;i++) {
        if(nnzc[yt_idct_scan[i]]) yt_idct4_add(dst+offset[i],block+i*16,stride);
        else if(block[i*16]) yt_idct4_dc_add(dst+offset[i],block+i*16,stride);
    }
}
static void yt_idct_add8(uint8_t **dst,const int *offset,int16_t *block,int stride,const uint8_t *nnzc) {
    for(int j=1;j<3;j++) for(int i=j*16;i<j*16+4;i++) {
        if(nnzc[yt_idct_scan[i]]) yt_idct4_add(dst[j-1]+offset[i],block+i*16,stride);
        else if(block[i*16]) yt_idct4_dc_add(dst[j-1]+offset[i],block+i*16,stride);
    }
}
static void yt_h264idct_arm11_init(H264DSPContext *c,int chroma) {
    c->h264_idct_add=yt_idct4_add; c->h264_idct_dc_add=yt_idct4_dc_add;
    c->h264_idct_add16=yt_idct_add16; c->h264_idct_add16intra=yt_idct_add16intra;
    if(chroma==1) c->h264_idct_add8=yt_idct_add8;
}
#endif
