#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "libavutil/cpu.h"
#include "decoder-arm11-idct.h"

static uint32_t seed=0x51415453;
static unsigned random_byte(void) {
    seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; return seed&255;
}
static void same(const uint8_t *a,const uint8_t *b,size_t n,const char *kind,int size,int phase,int avg,int iteration) {
    for(size_t i=0;i<n;i++) if(a[i]!=b[i]) {
        fprintf(stderr,"%s mismatch: size %d phase %d avg %d iteration %d byte %lu: %u != %u\n",
            kind,size,phase,avg,iteration,(unsigned long)i,a[i],b[i]); exit(1);
    }
}
int main(void) {
    H264QpelContext reference={0},optimized={0};
    H264ChromaContext chromaReference={0},chromaOptimized={0};
    av_force_cpu_flags(0);
    ff_h264qpel_init(&reference,8); ff_h264chroma_init(&chromaReference,8);
    yt_h264qpel_arm11_init(&optimized); yt_h264chroma_arm11_init(&chromaOptimized);
    uint8_t source[48*48],a[48*48],b[48*48];
    unsigned comparisons=0;
    for(int iteration=0;iteration<256;iteration++) {
        int stride=40+(iteration&7),offset=5*stride+5+(iteration&1);
        for(size_t i=0;i<sizeof(source);i++) {
            switch(iteration&15) {
                case 0: source[i]=0; break;
                case 1: source[i]=255; break;
                case 2: source[i]=(i&1) ? 255 : 0; break;
                case 3: source[i]=((i/stride)&1) ? 255 : 0; break;
                case 4: source[i]=(i%stride)*7; break;
                case 5: source[i]=(i/stride)*7; break;
                default: source[i]=random_byte(); break;
            }
        }
        for(int size=0;size<4;size++) for(int phase=0;phase<16;phase++) for(int avg=0;avg<2;avg++) {
            qpel_mc_func ref=avg ? reference.avg_h264_qpel_pixels_tab[size][phase] : reference.put_h264_qpel_pixels_tab[size][phase];
            qpel_mc_func fast=avg ? optimized.avg_h264_qpel_pixels_tab[size][phase] : optimized.put_h264_qpel_pixels_tab[size][phase];
            if(!ref) continue;
            for(size_t i=0;i<sizeof(a);i++) a[i]=b[i]=random_byte();
            ref(a+offset,source+offset,stride); fast(b+offset,source+offset,stride);
            same(a,b,sizeof(a),"luma",16>>size,phase,avg,iteration); comparisons++;
        }
        for(int size=0;size<3;size++) for(int y=0;y<8;y++) for(int x=0;x<8;x++) for(int avg=0;avg<2;avg++) {
            int height=2+2*(iteration&7);
            for(size_t i=0;i<sizeof(a);i++) a[i]=b[i]=random_byte();
            if(avg) {
                chromaReference.avg_h264_chroma_pixels_tab[size](a+offset,source+offset,stride,height,x,y);
                chromaOptimized.avg_h264_chroma_pixels_tab[size](b+offset,source+offset,stride,height,x,y);
            } else {
                chromaReference.put_h264_chroma_pixels_tab[size](a+offset,source+offset,stride,height,x,y);
                chromaOptimized.put_h264_chroma_pixels_tab[size](b+offset,source+offset,stride,height,x,y);
            }
            same(a,b,sizeof(a),"chroma",8>>size,y*8+x,avg,iteration); comparisons++;
        }
    }
    printf("ARM11 motion: %u exact luma/chroma block comparisons, including untouched padding.\n",comparisons);
    H264DSPContext dspReference={0},dspOptimized={0};
    ff_h264dsp_init(&dspReference,8,1); yt_h264idct_arm11_init(&dspOptimized,1);
    int16_t coefficients[48*16],coefficientsCopy[48*16];
    int offsets[48]; uint8_t nonzero[120];
    for(int i=0;i<48;i++) offsets[i]=(i%6)*4+(i/6)*4*48;
    for(int iteration=0;iteration<4096;iteration++) {
        int stride=40+(iteration&7),offset=2*stride+2+(iteration&1);
        for(int operation=0;operation<5;operation++) {
            for(size_t i=0;i<sizeof(a);i++) a[i]=b[i]=random_byte();
            for(int i=0;i<48*16;i++) {
                int value=random_byte()|random_byte()<<8;
                if(iteration&1) value=(value%2049)-1024;
                coefficients[i]=coefficientsCopy[i]=(int16_t)value;
            }
            for(int i=0;i<120;i++) nonzero[i]=random_byte()%3;
            switch(operation) {
                case 0:
                    dspReference.h264_idct_add(a+offset,coefficients,stride);
                    dspOptimized.h264_idct_add(b+offset,coefficientsCopy,stride); break;
                case 1:
                    dspReference.h264_idct_dc_add(a+offset,coefficients,stride);
                    dspOptimized.h264_idct_dc_add(b+offset,coefficientsCopy,stride); break;
                case 2:
                    dspReference.h264_idct_add16(a,offsets,coefficients,48,nonzero);
                    dspOptimized.h264_idct_add16(b,offsets,coefficientsCopy,48,nonzero); break;
                case 3:
                    dspReference.h264_idct_add16intra(a,offsets,coefficients,48,nonzero);
                    dspOptimized.h264_idct_add16intra(b,offsets,coefficientsCopy,48,nonzero); break;
                case 4: {
                    uint8_t *destA[2]={a,a},*destB[2]={b,b};
                    dspReference.h264_idct_add8(destA,offsets,coefficients,48,nonzero);
                    dspOptimized.h264_idct_add8(destB,offsets,coefficientsCopy,48,nonzero); break;
                }
            }
            same(a,b,sizeof(a),"IDCT",4,operation,0,iteration);
            same((uint8_t *)coefficients,(uint8_t *)coefficientsCopy,sizeof(coefficients),"IDCT clearing",4,operation,0,iteration);
        }
    }
    puts("ARM11 IDCT: 20480 exact transform/dispatch comparisons, including coefficient clearing and signed overflow.");
    if(getenv("YT_MOTION_BENCH")) {
        for(int mode=0;mode<2;mode++) {
            H264QpelContext *q=mode ? &optimized : &reference;
            H264ChromaContext *c=mode ? &chromaOptimized : &chromaReference;
            clock_t start=clock();
            for(int i=0;i<300000;i++) {
                int phase=i&15,size=(i>>4)&1;
                q->put_h264_qpel_pixels_tab[size][phase](a+5*48+5,source+5*48+5,48);
                c->put_h264_chroma_pixels_tab[size](a+5*48+5,source+5*48+5,48,8,i&7,(i>>3)&7);
            }
            printf("Motion benchmark (%s): %.3f CPU seconds, checksum %u.\n",mode ? "ARM11" : "generic",
                (double)(clock()-start)/CLOCKS_PER_SEC,a[5*48+5]);
            start=clock();
            for(int i=0;i<300000;i++) {
                coefficients[0]=1024; coefficients[1]=-120; coefficients[3]=230;
                (mode ? dspOptimized.h264_idct_add : dspReference.h264_idct_add)(a+5*48+5,coefficients,48);
            }
            printf("IDCT benchmark (%s): %.3f CPU seconds.\n",mode ? "ARM11" : "generic",(double)(clock()-start)/CLOCKS_PER_SEC);
        }
    }
    return 0;
}
