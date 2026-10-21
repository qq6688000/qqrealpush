TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQRealPush

QQRealPush_FILES = Tweak.x
QQRealPush_FRAMEWORKS = UserNotifications UIKit
QQRealPush_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
