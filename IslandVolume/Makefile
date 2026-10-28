include $(THEOS)/makefiles/common.mk
RSIV_PTRAUTH_CFLAGS := $(shell $(TARGET_CC) -x objective-c -fsyntax-only -fno-ptrauth-objc-class-ro /dev/null >/dev/null 2>&1 && echo -fno-ptrauth-objc-class-ro)
export RSIV_PTRAUTH_CFLAGS
TWEAK_NAME = RSIslandVolume
RSIslandVolume_FILES = hooks/RSIVHooksLockScreen16.x hooks/RSIVHooksLockScreen18.x hooks/RSIVHooksVolumeView.x hooks/RSIVHooksDynamicIsland.x hooks/RSIVHooksSpringBoard.x RSIVShared.m RSIVPrefs.m
RSIslandVolume_CFLAGS = -fobjc-arc $(RSIV_PTRAUTH_CFLAGS) -I$(THEOS_PROJECT_DIR)
RSIslandVolume_FRAMEWORKS = UIKit CoreGraphics
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
