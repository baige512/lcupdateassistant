# LiveContainer 插件：软件源安装辅助
# 编译环境：macOS + Theos（https://theos.dev/docs/installation）

TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCUpdateAssistant

LCUpdateAssistant_FILES = Tweak.xm
LCUpdateAssistant_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LCUpdateAssistant_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
