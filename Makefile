# LiveContainer 插件：软件源安装辅助
# 编译环境：macOS + Theos（https://theos.dev/docs/installation）

TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCUpdateAssistant

LCUpdateAssistant_FILES = Tweak.xm
LCUpdateAssistant_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LCUpdateAssistant_FRAMEWORKS = UIKit Foundation

# 关键：用 Logos 的 Internal 生成器（method_exchangeImplementations），
# 不依赖 CydiaSubstrate.framework —— LiveContainer 里没有这个库，
# 默认 MobileSubstrate 生成器编出来的 dylib 会报 "Library not loaded: CydiaSubstrate"。
LOGOS_DEFAULT_GENERATOR = Internal

include $(THEOS_MAKE_PATH)/tweak.mk
