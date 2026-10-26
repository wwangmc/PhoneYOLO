include ../config.mk
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = PhoneYOLOApp
PhoneYOLOApp_FILES = main.m PYAppDelegate.m ../Sources/PYConfig.m
PhoneYOLOApp_CFLAGS = -fobjc-arc -Wall -Wextra
PhoneYOLOApp_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
PhoneYOLOApp_CODESIGN_FLAGS = -Sentitlements.plist
PhoneYOLOApp_RESOURCE_DIRS = Resources
include $(THEOS_MAKE_PATH)/application.mk
