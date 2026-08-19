# Contributing

欢迎提交 Issue、协议抓包、不同固件版本的测试结果和代码改进。

## 开发要求

- macOS 14 或更高版本
- Xcode 16 或更高版本
- XcodeGen（仅在修改 `project.yml` 或新增源码时需要）
- ScreenKey MK20（硬件集成测试需要）

提交前请运行：

```sh
xcodebuild \
  -project CodexPetDeck.xcodeproj \
  -scheme CodexPetDeck \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CodexPetDeckDerived \
  test CODE_SIGNING_ALLOWED=NO
```

## 硬件相关变更

涉及主题、串口协议或按键映射的提交，请注明：

- MK20 固件版本；
- 使用的 USB 接口与 VID:PID；
- 可复现步骤和脱敏日志；
- 是否经过拔插、冷启动和 20 键硬件自检。

不要提交设备备份、用户 Codex 会话、签名证书、构建产物或编译后的内核模块。
