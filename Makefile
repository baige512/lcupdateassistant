# LiveContainer 插件：软件源安装辅助
# 编译环境：macOS + Theos（https://theos.dev/docs/installation）

TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCUpdateAssistant

# 用纯 Objective-C++（Tweak.mm）+ 原生 runtime hook，
# 不经过 Logos 预处理器、不依赖 CydiaSubstrate.framework ——
# LiveContainer 里没有 CydiaSubstrate，默认 tweak 会报 "Library not loaded"。
LCUpdateAssistant_FILES = Tweak.mm
LCUpdateAssistant_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LCUpdateAssistant_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
