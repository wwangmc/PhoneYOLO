# 本地验证记录

日期：2026-10-26。环境：Windows、Python 3.9.10、MSVC 19.42、Clang 18.1.8 解析器、iPhoneOS16.5.sdk 头文件。

## 已实际执行并通过

- 使用官方 YOLOv8n 权重生成 `Models/yolov8n.mlmodel`，NeuralNetwork，Core ML specification 4，RGB 640×640，输出 `[1,84,8400]` float32，80 类。模型大小 12,725,073 字节。
- SHA256：`94a270a62938ba1edb81aba641e12be2c08aab8286476808cb892610036693ee`，与 `Models/yolov8n.json` 相符。
- PyTorch 2.8.0 CPU / Ultralytics 8.3.211 对附带 `bus.jpg` 运行参考推理，获得 5 个检测结果（4 人、1 辆公交车）。这一步不是 Core ML 原生推理。
- MSVC 实际编译并运行 `Tests/algorithms_test.cpp`。C++ raw 解码/NMS 与 Ultralytics 参考结果逐项比较通过；还覆盖竖横屏 letterbox 逆变换、补边裁剪、不同类别不互相抑制、无效浮点数和最大检测数。
- 同一 C++ 测试覆盖客户端帧掩码、分段接收、125/126/65535/65536 长度边界、Ping、畸形控制帧和超长帧。
- 使用 Clang 18.1.8 解析器配合真实 iOS SDK / Theos / LLVM 头文件，以 `arm64-apple-ios14.0`、ARC、blocks、C++17、`-Wall -Wextra -Werror` 检查全部 6 个实现文件，通过。系统弃用 API 警告单独关闭；Logos 钩子没有通过 iOS 链接器编译。
- `Tests/websocket_harness.mm` 也通过同样的 iOS 头文件语法检查。
- 检查 3 个 plist、模型哈希、源码 UTF-8/LF、workflow YAML 和三种编译矩阵，通过。
- Python 脚本语法检查；浏览器查看器 JavaScript 语法检查，通过。

## 已在 macOS 云端执行并通过

- `Tests/websocket_integration.py`：真实 Objective-C++ 服务的回环握手、token、多个客户端、Ping/Pong、关闭、拒绝未掩码数据和同端口重启，共 5 项测试通过。
- `Tests/model_smoke.swift`：编译实际 Core ML 模型并运行原生推理，输出 `[1,84,8400]`，有限数值检查通过。
- rootfull/rootless/RootHide 三种实际 `.deb` 编译、签名和打包全部成功，App 和插件均包含 arm64 / arm64e。
- 成功运行：https://github.com/wwangmc/PhoneYOLO/actions/runs/40287739106；二进制对应源码 `8928fed7fd1941bbc32754188481f5cc57f09e76`。
- 实际编译过程中修复了已弃用的方向 API 和 Objective-C/C++ 共享函数链接声明。

## 尚需目标 iPhone 验证

- App 图标注册、越狱注入、系统私有全屏抓取接口、手机上的 Core ML 编译/推理。
- 切换至其他 App 后的检测、竖屏/两个横屏方向的画面和像素坐标、连接/断线/重连与多个客户端。
- 最后一名客户端断开后的资源释放、实际 FPS、长时间功耗/内存和温度。

当前交付包含实际编译的安装包；安装和系统截图/检测链路仍需在手机验证。已通过 USB 只读查询确认当前设备为 iPhone X（iPhone10,3）/ iOS 16.1.1，包架构为 `iphoneos-arm64`，对应 rootless。
