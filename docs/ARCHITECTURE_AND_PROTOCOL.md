# 架构与 MK20 协议记录

本文整理 CodexPetDeck 在真机调试中确认的边界和实现决策。协议为非官方逆向结果，不能替代厂商文档。

## 1. 稳定 USB 架构

MK20 内部 USB Hub 暴露两个独立设备：

| 通道 | 已观察 VID:PID | 用途 |
|---|---|---|
| Allwinner CDC | `1D6B:0104` | V2 控制帧、主题上传、副屏系统数据 |
| SYK HID | `4250:426F` | 20 个物理键和两枚三向旋钮 |

CodexPetDeck 的生产路径同时使用这两个原厂接口。连接、启动和主题部署均不会修改设备启动脚本或 USB gadget。

`303A:8360` Codex Micro gadget、PTY bridge 和自定义 `usb_f_codexhid` 模块曾用于验证能否让 MK20 模拟 Codex Micro。该方案需要改写设备 USB 枚举并受 T113 UDC 端点、Linux 5.4.61 ABI 和启动时序约束，故已退出生产路径。相关源码仅保留在 `DeviceSupport/` 供研究和恢复分析。

## 2. V2 连接流程

1. 打开匹配的 `/dev/cu.usbmodem*`，参数为 115200、8-N-1。
2. 写入 64 个 ASCII `0`，唤醒设备解析器。
3. 发送空载荷 `FIND_DEVICE`（`cmd=0`）。
4. 发送 JSON `{"connect":true,"deviceProtocolVersion":"V2"}`（`cmd=15`）。
5. 收到身份数据后记录型号、固件版本和画布尺寸；收到 `deviceRequestSystemData` 后推送主题声明的数据键。

`FIND_DEVICE` 只证明串口链路可用；`connect` 才让设备进入在线状态并开始请求动态数据。

## 3. 主题上传时序

已确认的安全顺序：

1. `GET_THEME`（`cmd=3`）后发送 Abort 控制消息。
2. `FILE_START`（`cmd=6`，`{path:size}`），等待 ACK。
3. 逐块写入裸文件数据；当前实现块大小为 4096 字节，不再套 V2 帧。
4. `FILE_END`（`cmd=7`，`{path:crc32}`）后立即发送 Abort。
5. 等待 `FILE_END` ACK。
6. 发送 `RELOAD`（`cmd=2`）激活主题。

两个已复现的死锁条件：

- 未收到 `FILE_START` ACK 就写裸数据，设备会丢掉早期字节，文件计数永远达不到声明大小。
- 等 `FILE_END` ACK 后才发送 Abort，会形成双方互相等待。

发生这类卡死后，设备身份查询有时仍能响应，但文件通道需要物理重插恢复。主题写入期间必须串行化所有主题刷新，不能让状态动画与手动部署交错。

## 4. 主题与副屏

- 总画布为 640×656。
- 副屏可见区域为 428×142，位于画布 `(106, 0)`。
- 主键区为 640×512，从 `y=144` 开始，按 4 行×5 列划分为 128×128 单元格。
- 键项目使用零起始 `row`/`col`，物理 K18 对应 `(3,2)`。
- 副屏文本、进度条通过主题的 `system_data_name` 声明，再由主机使用 `cmd=1` 推送 `QMap<QString,QString>`。

## 5. 输入通道

原厂主题中的 `keyboard` 动作由设备直接发出 USB HID，因此通常不会在串口 `cmd=13` 中出现。需要主机观察的非键盘动作可以通过 `DEVICE_ProactiveEscalationCMD` 返回：第一张 map 是 `{row,col,pressed}`，第二张 map 是主题动作描述。

当前 CodexPetDeck 主要监听原厂 HID：

- 20 个屏幕键使用不同 HID 编码；
- 两枚旋钮的左转、按压、右转使用六个独立组合键；
- 主机按通道和时间窗口去除旋钮重复脉冲；
- 硬件自检只记录输入，拦截所有桌面动作。

## 6. Codex Desktop 控制

- 会话键使用 `codex://threads/<id>` 深链打开现有任务。
- 快速、接受、拒绝、语音、滚动、停止等动作通过 macOS 键盘事件或辅助功能树执行。
- 应用不注入、不修改、不重签 Codex Desktop。
- 输入监控检测必须以真实事件 tap 创建结果为准；macOS 不允许第三方应用静默授予 TCC 权限，只能打开系统设置引导用户操作。

## 7. 签名与权限

要避免每次更新重新授权，应保持：

- Bundle ID：`com.screenkey.codexpetdeck.direct`
- 同一 Apple Development Team 和证书链
- 稳定的应用安装路径

临时 ad-hoc 签名、Bundle ID 变化或从不同构建目录反复启动，都会被 TCC 视为不同应用身份。

## 8. 外部交叉验证

[MK20Control](https://github.com/alexmuraru27/MK20Control) 同样把 MK20 建模为 4×5 网格，并直接使用设备回传的 `row`/`col`。其 V2.32 协议记录和完整 20 键主题测试为本项目提供了独立交叉验证，但该仓库也是主机端实现，不包含 MK20 按键扫描固件。
