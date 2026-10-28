include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = RSIslandVolumePrefs
RSIslandVolumePrefs_FILES = RSIVSettingsController.m ../RSIVPrefs.m
RSIslandVolumePrefs_INSTALL_PATH = /Library/PreferenceBundles
RSIslandVolumePrefs_RESOURCE_DIRS = Resources
RSIslandVolumePrefs_FRAMEWORKS = UIKit CoreFoundation
RSIslandVolumePrefs_CFLAGS = -fobjc-arc $(RSIV_PTRAUTH_CFLAGS) -I$(THEOS_PROJECT_DIR)/..
RSIslandVolumePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk
