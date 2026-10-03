#include "../YTPlayerTiming.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    YTAudioTimeline clock={0};
    assert(YTContinuousAudioTime(&clock,0)==0);
    assert(YTContinuousAudioTime(&clock,5)==5);
    assert(YTContinuousAudioTime(&clock,5)==5); // buffering freezes time
    assert(YTContinuousAudioTime(&clock,0)==5); // old queue restarts its timeline
    assert(YTContinuousAudioTime(&clock,1)==6);
    assert(YTContinuousAudioTime(&clock,0.99)==6); // small clock jitter
    double last=0; int presented=0;
    for (int i=1;i<=1000;i++) {
        double now=i*0.01;
        if (YTShouldPresentFrame(-2,now,last)) { presented++; last=now; }
    }
    assert(presented>=165 && presented<=185);
    last=0; presented=0;
    for (int i=1;i<=200;i++) {
        double now=i*0.025;
        if (YTShouldPresentFrame(-0.20,now,last)) { presented++; last=now; }
    }
    assert(presented>=90 && presented<=110);
    last=0; presented=0;
    for (int i=1;i<=200;i++) {
        double now=i*0.025;
        if (YTShouldPresentFrame(-0.03,now,last)) { presented++; last=now; }
    }
    assert(presented==200);
    assert(YTClampSeekTime(-5,40)==0);
    assert(YTClampSeekTime(10,40)==10);
    assert(YTClampSeekTime(100,40)==39.9);
    assert(YTClampSeekTime(NAN,40)==0);
    assert(!YTShouldDropNonRef(0,0.4));
    assert(YTShouldDropNonRef(0,0.5));
    assert(YTShouldDropNonRef(1,0.5));
    assert(!YTShouldDropNonRef(1,0.1));
    assert(!YTPreferReferenceFrames(256,144,15));
    assert(!YTPreferReferenceFrames(256,144,30));
    assert(YTPreferReferenceFrames(426,240,15));
    assert(!YTNeedsVideoResync(10,12,100,0));
    assert(YTNeedsVideoResync(10,13.1,100,0));
    assert(!YTNeedsVideoResync(10,13.1,105,100));
    assert(YTNeedsVideoResync(10,13.1,106,100));
    puts("Player timing passed: 144p keeps all pictures, adaptive catch-up, pacing and clock continuity.");
    return 0;
}
