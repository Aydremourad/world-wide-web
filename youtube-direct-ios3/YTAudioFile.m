#import "YTAudioFile.h"
#import "YTMediaSource.h"

static OSStatus YTReadAudioBytes(void *opaque, SInt64 offset, UInt32 count,
                               void *bytes, UInt32 *actual) {
    int result = [(YTMediaSource *)opaque readAtOffset:offset into:bytes count:(int)count];
    *actual = result < 0 ? 0 : (UInt32)result;
    return result < 0 ? kAudioFileUnspecifiedError : noErr;
}
static SInt64 YTAudioFileSize(void *opaque) { return [(YTMediaSource *)opaque length]; }
OSStatus YTOpenAudioFile(YTMediaSource *source, AudioFileID *file) {
    // A forced M4A hint can reject an otherwise readable video MP4 container.
    return AudioFileOpenWithCallbacks(source, YTReadAudioBytes, NULL,
        YTAudioFileSize, NULL, 0, file);
}
