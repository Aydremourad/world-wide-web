#ifndef YT_PLAYER_TIMING_H
#define YT_PLAYER_TIMING_H
#include <math.h>
typedef struct { double offset, lastRaw, lastTime; int initialized; } YTAudioTimeline;
static double YTContinuousAudioTime(YTAudioTimeline *timeline, double raw) {
    if (raw < 0) return timeline->lastTime;
    if (timeline->initialized && raw < timeline->lastRaw - 0.25)
        timeline->offset = timeline->lastTime - raw;
    double value = raw + timeline->offset;
    if (timeline->initialized && value < timeline->lastTime) value = timeline->lastTime;
    timeline->lastRaw = raw; timeline->lastTime = value; timeline->initialized = 1;
    return value;
}
static int YTShouldPresentFrame(double lead, double now, double lastDisplay) {
    // Drawing a late frame costs another RGB conversion and OpenGL upload.
    // Preserve every frame near sync, but progressively cap presentation work
    // once video is behind so the ARMv6 decoder gets time to catch up.
    if (lastDisplay <= 0) return 1;
    double elapsed = now - lastDisplay;
    if (lead < -0.75) return elapsed >= 1.0/18.0 - 0.001;
    if (lead < -0.10) return elapsed >= 1.0/24.0 - 0.001;
    return 1;
}
static double YTClampSeekTime(double seconds,double duration) {
    if(!isfinite(seconds) || seconds<0) return 0;
    if(duration>0 && seconds>duration-0.1) return duration>0.1 ? duration-0.1 : 0;
    return seconds;
}
static int YTShouldDropNonRef(int currentlyDropping,double secondsBehind) {
    if (currentlyDropping) return secondsBehind > 0.15;
    return secondsBehind > 0.45;
}
static int YTPreferReferenceFrames(int width,int height,double fps) {
    // Rate alone is not evidence that decoding is too slow. The 144p source
    // keeps all pictures until measured lag activates NONREF discard.
    (void)fps;
    return width*height>38400;
}
static int YTNeedsVideoResync(double videoTime,double audioTime,double now,double lastSeek) {
    return audioTime-videoTime>3.0 && (lastSeek<=0 || now-lastSeek>=6);
}
#endif
