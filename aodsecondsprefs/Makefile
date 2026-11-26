ARCHS = arm64e
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = AODSecondsPrefs
AODSecondsPrefs_FILES = RootListController.m
AODSecondsPrefs_FRAMEWORKS = UIKit
AODSecondsPrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup
AODSecondsPrefs_INSTALL_PATH = /Library/PreferenceBundles
AODSecondsPrefs_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/bundle.mk
