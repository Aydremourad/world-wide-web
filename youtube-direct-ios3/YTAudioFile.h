#import <AudioToolbox/AudioToolbox.h>
@class YTMediaSource;

// Audio File Services selects the AAC track from either M4A or combined MP4.
// The source must stay alive until AudioFileClose has returned.
OSStatus YTOpenAudioFile(YTMediaSource *source, AudioFileID *file);
