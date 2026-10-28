ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.5
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk
SUBPROJECTS += RecordingSharinganPrefs

TWEAK_NAME = RecordingSharingan
RecordingSharingan_FILES = Tweak.xm
RecordingSharingan_CFLAGS = -fobjc-arc
RecordingSharingan_FRAMEWORKS = UIKit QuartzCore CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

include $(THEOS_MAKE_PATH)/aggregate.mk
