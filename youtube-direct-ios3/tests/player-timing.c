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
    for (int i=1;i<=200;i++) {
        double now=i*0.05;
        if (YTShouldPresentFrame(-2,now,last)) { presented++; last=now; }
    }
    assert(presented>=30 && presented<=41);
    assert(YTNeedsVideoCatchUp(1,4,1,0));
    assert(!YTNeedsVideoCatchUp(1,4,1,1));
    assert(!YTNeedsVideoCatchUp(1,4,0,0));
    puts("Player timing passed: late frames keep updating, keyframe catch-up and restart clock continuity.");
    return 0;
}
