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
    if (lead < -0.60) return elapsed >= 1.0/15.0;
    if (lead < -0.08) return elapsed >= 1.0/20.0;
    return 1;
}
static double YTClampSeekTime(double seconds,double duration) {
    if(!isfinite(seconds) || seconds<0) return 0;
    if(duration>0 && seconds>duration-0.1) return duration>0.1 ? duration-0.1 : 0;
    return seconds;
}
static int YTNeedsVideoResync(double videoTime,double audioTime,double now,double lastSeek) {
    return audioTime-videoTime>3 && (lastSeek<=0 || now-lastSeek>=5);
}
#endif
