#include "../YTFrameQueue.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    YTFrameQueue queue={0};
    int frames[1200];
    for(int repeat=0;repeat<400;repeat++) {
        // FIFO wraparound and strict backpressure: never discard a future frame.
        for(int i=0;i<3;i++) assert(YTFrameQueuePush(&queue,&frames[repeat*3+i],repeat+i/15.0));
        assert(!YTFrameQueuePush(&queue,frames,100));
        assert(!YTFrameQueueIsDue(&queue,repeat-0.01));
        for(int i=0;i<3;i++) {
            assert(YTFrameQueueIsDue(&queue,repeat+i/15.0));
            assert(YTFrameQueuePop(&queue)==&frames[repeat*3+i]);
        }
        assert(!queue.count && !YTFrameQueuePop(&queue));
    }
    // A stalled UI consumes the most recent *due* picture and keeps future PTS.
    assert(YTFrameQueuePush(&queue,&frames[0],10.00));
    assert(YTFrameQueuePush(&queue,&frames[1],10.07));
    assert(YTFrameQueuePush(&queue,&frames[2],10.14));
    void *shown=0;
    while(YTFrameQueueIsDue(&queue,10.09)) shown=YTFrameQueuePop(&queue);
    assert(shown==&frames[1] && queue.count==1);
    assert(!YTFrameQueueIsDue(&queue,10.12));
    assert(YTFrameQueueIsDue(&queue,10.14));
    assert(YTFrameQueuePop(&queue)==&frames[2]);
    puts("Presentation queue passed: bounded decode-ahead, FIFO wraparound and latest-due selection.");
    return 0;
}
