include config.mk
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhoneYOLO
PhoneYOLO_FILES = Tweak.xm Sources/PYConfig.m Sources/PYWebSocket.mm Sources/PYDetector.mm Sources/PYService.mm
PhoneYOLO_CFLAGS = -fobjc-arc -Wall -Wextra
PhoneYOLO_CCFLAGS = -std=c++17
PhoneYOLO_FRAMEWORKS = Foundation UIKit CoreGraphics CoreImage CoreVideo CoreML QuartzCore ImageIO
PhoneYOLO_PRIVATE_FRAMEWORKS = IOSurface

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += App
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	@test -f Models/yolov8n.mlmodel || (echo 'Run python scripts/export_model.py first'; exit 1)
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/PhoneYOLO"
	@cp Models/yolov8n.mlmodel Models/bus.jpg "$(THEOS_STAGING_DIR)/Library/Application Support/PhoneYOLO/"
