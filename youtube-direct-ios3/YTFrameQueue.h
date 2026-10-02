#ifndef YT_FRAME_QUEUE_H
#define YT_FRAME_QUEUE_H
#define YT_FRAME_QUEUE_CAPACITY 3
typedef struct {
    void *frames[YT_FRAME_QUEUE_CAPACITY];
    double times[YT_FRAME_QUEUE_CAPACITY];
    unsigned head, count;
} YTFrameQueue;
/* Caller owns the lock and all frame lifetimes. */
static int YTFrameQueuePush(YTFrameQueue *queue, void *frame, double time) {
    if(queue->count==YT_FRAME_QUEUE_CAPACITY) return 0;
    unsigned tail=(queue->head+queue->count)%YT_FRAME_QUEUE_CAPACITY;
    queue->frames[tail]=frame; queue->times[tail]=time; queue->count++;
    return 1;
}
static void *YTFrameQueuePop(YTFrameQueue *queue) {
    if(!queue->count) return 0;
    void *frame=queue->frames[queue->head];
    queue->head=(queue->head+1)%YT_FRAME_QUEUE_CAPACITY; queue->count--;
    return frame;
}
static int YTFrameQueueIsDue(const YTFrameQueue *queue, double time) {
    // A small tolerance absorbs AudioQueue clock jitter, not a frame interval.
    return queue->count && queue->times[queue->head]<=time+0.005;
}
#endif
