#ifndef YT_PLAYER_TIMING_H
#define YT_PLAYER_TIMING_H
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
static int YTShouldPresentFrame(double lateness, double now, double lastDisplay) {
    // Even a slow decoder must refresh the picture instead of dropping forever.
    return lateness >= -0.20 || lastDisplay <= 0 || now - lastDisplay >= 0.25;
}
static int YTNeedsVideoCatchUp(double videoTime, double audioTime, int large, int key) {
    return large && !key && audioTime - videoTime > 1.0;
}
#endif
