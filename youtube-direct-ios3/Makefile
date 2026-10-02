ARCHS = armv6
SDKVERSION ?= 3.1.3
TARGET = iphone:clang:$(SDKVERSION):3.0

# Modern Xcode's linker no longer emits armv6. build.sh exports TARGET_LD
# to legacy-link.sh when an armv6-capable cctools-port ld64 is installed.

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = YouTubeDirect
YouTubeDirect_FILES = main.m YTAppDelegate.m YTViewController.m YTYouTube.m YTMediaSource.m YTVideoSurface.m YTSoftwarePlayer.m YTAudioFile.m YTAudioPump.m YTNativeProbe.m YTLoopbackServer.m YTNativePlayer.m YTVideoDecoder.c
YouTubeDirect_FRAMEWORKS = UIKit Foundation AudioToolbox OpenGLES QuartzCore MediaPlayer
YouTubeDirect_CFLAGS = -fno-objc-arc -miphoneos-version-min=3.0 -Wno-unused-function -O3 -mcpu=arm1176jzf-s -marm -fno-math-errno -fno-signed-zeros -I$(CURDIR)/.deps/FFmpeg-2.8.22
YouTubeDirect_LDFLAGS = -miphoneos-version-min=3.0 $(CURDIR)/.deps/FFmpeg-2.8.22/libavformat/libavformat.a $(CURDIR)/.deps/FFmpeg-2.8.22/libavcodec/libavcodec.a $(CURDIR)/.deps/FFmpeg-2.8.22/libswscale/libswscale.a $(CURDIR)/.deps/FFmpeg-2.8.22/libavutil/libavutil.a -lm
TARGET_CODESIGN_FLAGS = -S -Hsha1

include $(THEOS_MAKE_PATH)/application.mk
