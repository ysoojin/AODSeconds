ARCHS = arm64e
TARGET = iphone:clang:latest:17.0
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = AODSeconds
AODSeconds_FILES = Tweak.xm
AODSeconds_CFLAGS = -fobjc-arc
AODSeconds_FRAMEWORKS = UIKit QuartzCore Foundation
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += aodsecondsprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
