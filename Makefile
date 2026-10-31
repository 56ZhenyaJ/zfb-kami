# 卡密验证Tweak Makefile - 适配WSL2 Ubuntu22.04 + Theos
# 使用前请确保已正确安装Theos环境，THEOS路径指向你的Theos目录
THEOS ?= $(HOME)/theos
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0  # 最低支持iOS14
ADDITIONAL_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable

# ！！！重要：请修改这里为你要注入的APP的进程名！！！
# 示例：微信填WeChat，抖音填Aweme，小红书填Xiaohongshu，自己的APP填对应进程名
INSTALL_TARGET_PROCESSES = Runner

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = kamiCheck
kamiCheck_FILES = Tweak.xm
kamiCheck_FRAMEWORKS = UIKit Foundation Security

include $(THEOS_MAKE_PATH)/tweak.mk

# 编译完成提示
all::
	@echo "✅ 编译成功！dylib文件路径：.theos/obj/debug/kamiCheck.dylib"
	@echo "ℹ️  请将dylib通过Opener/Substitute等工具注入到目标APP即可使用"

