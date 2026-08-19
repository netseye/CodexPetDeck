# Security and hardware safety

CodexPetDeck 会读取本机 Codex 会话元数据，并在获得 macOS“输入监控”和“辅助功能”授权后执行桌面快捷键。项目不会上传会话内容，也不需要网络服务，但用户仍应自行审查源码和授权范围。

生产路径只使用 MK20 原厂 CDC 与 HID 接口，不会写入启动脚本或加载内核模块。`DeviceSupport/` 中的 Linux gadget 代码是已停用的协议研究材料；错误部署可能导致 USB 接口暂时消失，需要通过恢复脚本或物理重插恢复。除非清楚了解 MK20 的 Linux 启动流程，否则不要部署这些实验文件。

安全问题请通过 GitHub Security Advisory 私下报告。普通协议问题和硬件兼容性问题可以提交公开 Issue，但请先删除用户名、目录、序列号和会话内容。
