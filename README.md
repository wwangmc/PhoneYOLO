# PhoneYOLO

面向 **iOS 14+ 越狱设备**的屏幕 YOLOv8 目标检测应用。包含原生配置 App、SpringBoard 检测插件、WebSocket 服务、真实 YOLOv8n 测试模型和电脑端查看器。

## 工作方式

```text
PhoneYOLO App ──保存参数 / 导入模型──> SpringBoard 插件
                                        │
                                  WebSocket :8765
                                        │
                已认证连接 > 0 ──截屏 → Core ML → NMS → JSON 推送
                已认证连接 = 0 ──停止计时器，释放模型和截屏缓冲
```

- 检测整个显示屏，可以在切换到其他 App 后继续检测。App 自身不需要在后台保持运行。
- 多个客户端共用一次推理，默认目标 10 FPS，可调 1–30 FPS。没有目标的帧也推送 `detections: []`。
- 推理串行，不堆积截屏任务。慢客户端最多保留当前发送帧和最新一帧；写入超时 10 秒断开。
- 首次连接才编译、加载模型；编译产物缓存，最后一名客户端断开后释放内存资源。正在执行的同步 Core ML 调用会完成后丢弃结果。
- WebSocket 支持浏览器握手、Ping/Pong、连接关闭和随机 token 认证。最多 16 个连接（含未完成握手的连接）；握手超时 5 秒，超过 45 秒无客户端活动断开。
- 服务开关、端口、FPS、置信度、IoU、最大检测数和模型均可在 App 中配置。保存配置会断开连接，客户端重连后使用新配置。

包名 `com.example.phoneyolo`；App bundle ID `com.example.phoneyolo.app`。只注入 `com.apple.springboard`。

## 快速测试

1. 编译并安装对应越狱类型的 `.deb`，重新启动 SpringBoard。桌面打开 **PhoneYOLO**。
2. 保留内置模型，启用服务，点击“复制 WebSocket 地址”。默认端口 `8765`。
3. 电脑与手机在同一网络，打开 `Examples/viewer.html`，粘贴地址并连接。
4. 在手机点击“打开测试画面”，应能对测试图片中的公交车和人物输出检测框。也可切换至其他 App 测试。
5. 断开所有查看器，App 状态应恢复“等待连接”，`modelLoaded` 变为 `false`。

默认监听 IPv4 `0.0.0.0`。地址示例：

```text
ws://192.168.1.10:8765/detections?token=应用里显示的token
```

查看器直接显示检测框位置和 JSON，不传输屏幕图片。也可以使用 Python 自动重连示例：

```sh
python -m pip install websockets
python Examples/client.py 'ws://192.168.1.10:8765/detections?token=TOKEN'
```

`ws://` 没有传输加密，token 具有访问权限，适合可信局域网或 USB 转发；勿把该端口直接映射至公网。

## 推送协议

每次推送为一个 WebSocket UTF-8 JSON 文本帧：

```json
{
  "type": "detections",
  "version": 1,
  "sequence": 42,
  "timestamp": 1792998000.123,
  "latencyMs": 35.2,
  "screen": {
    "width": 1125,
    "height": 2436,
    "scale": 3,
    "orientation": 1,
    "coordinateSystem": "top-left-pixels"
  },
  "detections": [{
    "classId": 0,
    "label": "person",
    "confidence": 0.92,
    "box": {"x": 100, "y": 200, "width": 120, "height": 300},
    "normalizedBox": {"x": 0.0889, "y": 0.0821, "width": 0.1067, "height": 0.1232}
  }]
}
```

`timestamp` 是截屏后的 Unix 秒数；`latencyMs` 包括截屏、预处理和推理，首次还包含模型加载时间。`sequence` 在当前 SpringBoard 生命周期内递增。

`box` 使用按当前界面方向旋转后的屏幕像素，原点在左上；`normalizedBox` 除以同帧宽高。除以 `screen.scale` 可得到 UIKit 点。`orientation` 沿用 `UIInterfaceOrientation`：1 竖屏、2 倒置、3 横屏左、4 横屏右。横竖屏切换请始终读取同帧的屏幕宽高。

模型或截屏错误发送 `{"type":"error","message":"原因","retryInSeconds":5}`，等待 5 秒后重试。客户端不要向此端点发送业务文本或二进制数据（关闭码 1003）；配置在 App 中完成。

## 测试模型与自训练模型

已附带 `Models/yolov8n.mlmodel`（约 12.7 MB）、类别/哈希清单 `Models/yolov8n.json` 和 `Models/bus.jpg`。模型源自 [Ultralytics 官方 YOLOv8n COCO 权重](https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt)，包含 80 类常见物体。它不具备任意 UI 按钮或游戏对象识别能力，这类目标需要标注并训练自己的 YOLOv8 detect 模型。

为了兼容 iOS 14，采用 **NeuralNetwork `.mlmodel`**，而非要求 iOS 15+ 的 ML Program。见 [Apple 格式与部署版本说明](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)。

导出脚本可在 Windows/macOS 生成该格式，无需在手机运行 Python：

```sh
python -m pip install -r scripts/requirements-model.txt
python scripts/export_model.py --weights path/to/best.pt --output Models/custom.mlmodel
```

然后通过文件 App 将 `.mlmodel` 交给 PhoneYOLO 的“导入自训练模型”。也接受由同一格式编译的 `.mlmodelc` 文件夹。当前契约为：

- 单个 RGB 图像输入，批次 1，固定输入尺寸；预处理为等比缩放、居中补边 RGB 114。
- 单个 float32/float64 raw 输出 `[1, 4 + 类别数, 候选数]`，前 4 通道为输入像素坐标 `cx,cy,w,h`，后续为类别概率，无 objectness，无内嵌 NMS。
- 导出脚本写入 `phoneyolo.names` 标签元数据；应用自动读取类别数、标签和输入尺寸。
- 按类别执行 NMS，最多 3000 个高分候选参与抑制。暂不支持分割、姿态、OBB、YOLOv5 或其他输出布局；不直接加载 `.pt` / `.onnx` / ML Program `.mlpackage`。

内置模型来自 Ultralytics，使用时遵守其 [AGPL-3.0 / 商业许可](https://www.ultralytics.com/license)。

## 编译和安装

三种配置均以 iOS 14.0 为编译下限、包含 arm64 / arm64e；实际适配取决于对应系统上的越狱和注入器。rootful 的 iOS 14+ arm64e 使用新 ABI，本工程不支持 iOS 13。

| 越狱类型 | 参数 | 打包前缀 |
| --- | --- | --- |
| rootful（workflow 名 rootfull） | `TYPE=0` | 根目录 |
| rootless | `TYPE=1`，默认 | 由 Theos scheme 处理 |
| RootHide | `TYPE=2` | 由 RootHide Theos scheme 处理 |

在具备 Xcode、RootHide Theos、GNU make、ldid、xz 和补丁 iPhoneOS16.5.sdk 的 macOS 上：

```sh
export THEOS=/path/to/theos
gmake TYPE=1 clean
gmake TYPE=1 FINALPACKAGE=1 package
```

切换类型前先 clean。编译产物在 `packages/`，安装后需要 respring；安装脚本会尝试刷新应用图标。应用和插件在一个包内。

Windows 用户可把 **PhoneYOLO 目录内的内容**放在独立 GitHub 仓库根目录（包含现成模型、App、Sources 和隐藏 `.github` 目录），在 **Actions → Build Theos packages → Run workflow** 编译。工作流也在 main/master 的 push/PR 上运行。Artifacts 中的 `PhoneYOLO-rootfull/rootless/roothide` 含 `.deb` 和 SHA256，`build-log-*` 含构建日志。

工作流在打包前执行算法测试、原生 WebSocket 回环测试、Core ML 编译/推理冒烟检查。已在独立[私有仓库](https://github.com/wwangmc/PhoneYOLO)实际完成三模式编译，[成功运行记录](https://github.com/wwangmc/PhoneYOLO/actions/runs/40287739106)。

## 验证范围与限制

本地验证记录见 `VERIFICATION.md`。Windows 已实际生成模型、检查模型结构和 SHA256、运行 PyTorch 参考推理、验证 C++ 解码/NMS 与参考结果一致，并使用 iOS SDK 头文件检查 Objective-C/Objective-C++ 源码。

**三种 iOS `.deb` 已编译成功；macOS 原生检查和 iPhone X / iOS 16.1.1 / rootless 实测已通过。** 实机默认模型约 5 FPS，检出测试画面中的公交车和人物，跨 App 推送、多客户端、重连和断线释放验证通过。二进制和校验记录在 `packages/`；范围与测试期间的 MKS 点击接口崩溃见[真机记录](docs/DEVICE-TEST.md)。

全屏抓取依赖私有 `CARenderServerRenderDisplay`；系统升级、越狱环境、受保护视频或锁屏状态可能限制可捕获内容。横竖屏坐标、实际 FPS、温度、功耗及长时间稳定性必须在目标手机验证。

可变数据位于 `/var/mobile/Library/PhoneYOLO/`：`config.json`、`status.json`、导入模型和编译缓存。目录权限 0700，JSON 文件 0600。停止服务可在 App 中关闭开关；卸载插件后请 respring。
