include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = RecordingSharinganPrefs
RecordingSharinganPrefs_FILES = RSRootController.m RSAdjustCell.m
RecordingSharinganPrefs_INSTALL_PATH = /Library/PreferenceBundles
RecordingSharinganPrefs_RESOURCE_DIRS = Resources
RecordingSharinganPrefs_PRIVATE_FRAMEWORKS = 
RecordingSharinganPrefs_FRAMEWORKS = UIKit CoreFoundation
# The cloud SDK lacks the private Preferences.framework binary.
# PreferenceLoader loads Preferences.framework in the Settings process.
# Resolve PSListController/PSTableCell/PSSpecifier symbols at runtime.
# Explicitly link Preferences.framework rather than hiding missing symbols.
# Cloud builder must supply an SDK containing the private framework stub.
RecordingSharinganPrefs_CFLAGS = -fobjc-arc
RecordingSharinganPrefs_FRAMEWORKS += UniformTypeIdentifiers ImageIO
include $(THEOS_MAKE_PATH)/bundle.mk

# Settings loads Preferences.framework at runtime; no SDK link stub available.
ADDITIONAL_LDFLAGS += -Wl,-undefined,dynamic_lookup
