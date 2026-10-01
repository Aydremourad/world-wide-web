ARCHS = armv6
SDKVERSION ?= 3.1.3
TARGET = iphone:clang:$(SDKVERSION):3.0

# Modern Xcode's linker no longer emits armv6. build.sh exports TARGET_LD
# to legacy-link.sh when an armv6-capable cctools-port ld64 is installed.

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = YouTubeDirect
YouTubeDirect_FILES = main.m YTAppDelegate.m YTViewController.m YTYouTube.m
YouTubeDirect_FRAMEWORKS = UIKit Foundation MediaPlayer
YouTubeDirect_CFLAGS = -fno-objc-arc -miphoneos-version-min=3.0
YouTubeDirect_LDFLAGS = -miphoneos-version-min=3.0
TARGET_CODESIGN_FLAGS = -S -Hsha1

include $(THEOS_MAKE_PATH)/application.mk
