TARGET := iphone:clang:3.0
ARCHS = armv6
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TubeRepairIOS3Bridge
TubeRepairIOS3Bridge_FILES = Tweak.x
TubeRepairIOS3Bridge_FRAMEWORKS = Foundation UIKit MediaPlayer
TubeRepairIOS3Bridge_CFLAGS = -Wno-deprecated-declarations -Wno-format

include $(THEOS_MAKE_PATH)/tweak.mk
