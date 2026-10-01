ARCHS = armv6
TARGET = iphone:clang:3.1:3.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = YouTubeDirect
YouTubeDirect_FILES = main.m YTAppDelegate.m YTViewController.m YTYouTube.m
YouTubeDirect_FRAMEWORKS = UIKit Foundation MediaPlayer
YouTubeDirect_CFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/application.mk
