# kamiCheck

iOS 卡密验证动态库插件，基于 Theos 开发。

## 功能

- 启动时卡密验证弹窗
- 缓存有效卡密，自动静默验证
- 心跳保活，定时校验卡密有效性
- 卡密失效自动退出
- 设备绑定（UDID/IDFV）

## 编译

```bash
# 安装 Theos
git clone --recursive https://github.com/theos/theos.git ~/theos

# 编译
make
```

编译产物：`.theos/obj/debug/kamiCheck.dylib`

## 使用

将 dylib 通过 Opener / Substitute 等工具注入到目标 APP。

## 配置

修改 `Makefile` 中的 `INSTALL_TARGET_PROCESSES` 为目标 APP 进程名。