# iPhone 真机验证

2026-10-26，经 USBMux 在 iPhone X（iPhone10,3）/ iOS 16.1.1 / rootless 上测试 PhoneYOLO 0.1.0。手机安装包由用户安装；实测客户端未暴露或保存 token。

| 项目 | 实测结果 |
| --- | --- |
| 安装和启动 | 原生 App、SpringBoard 检测服务均启动 |
| 无客户端 | `clients=0`、`modelLoaded=false`、`detecting=false` |
| 内置图片识别 | 1 辆公交车、4 个人；单帧公交车置信度约 0.875 |
| 默认配置 | 640×640 YOLOv8n，目标 10 FPS，置信度 0.25，IoU 0.45 |
| 实际处理速度 | 约 5 FPS，处理耗时中位数约 196–204 ms |
| 原始屏幕坐标 | 1125×2436，scale=3，竖屏；检测框在测试画面上对齐 |
| 多客户端 | 两个客户端同时接收；一个断开后另一个继续接收 |
| token | 错误 token 被拒绝 |
| 最后断线 | 自动停止推理并释放模型，恢复上述 idle 状态 |
| 重连 | 连续两次重新连接、接收、断开通过 |
| 切换其他 App | 保持 WebSocket 连接，切换系统设置后仍持续推送；返回测试 App 后重新检出公交车和人物 |
| 连续运行 | 约 39 秒跨应用短测，采集统计阶段合计 165 帧，另含过渡帧；序号持续递增 |

分阶段统计：测试图片 20 帧 / 4.98 FPS / 中位 204.5 ms；系统设置 20 帧 / 4.97 FPS / 中位 199.9 ms；返回测试图片 125 帧 / 4.98 FPS / 中位 200.7 ms。

电脑端根据实际推送的 JSON，在同一静态测试画面上绘制检测框；这张图不表示手机界面自带框显示。证据在本地 `packages/DEVICE-TEST-detections.png`、`DEVICE-TEST-results.json` 和 `DEVICE-TEST-crossapp.json`。

## 测试中发生的安全模式

首次尝试通过既有 MKS `/touch` 的 `tap` 动作进入测试画面时，SpringBoard 出现 SIGABRT，进入安全模式。通过 USB 拉取对应崩溃报告，并从手机只读取得 UUID 匹配的 `pccontrol.dylib`，将栈地址解析到 `STHIDEventGenerator` 的 `_sendTaps:location:numberOfTouches:delayBetweenTaps:` 和 `tap:`。

现有 MKS 源码中，`tap:` 传入 `delayBetweenTaps:0`，而 `_sendTaps` 断言 `delay > 0.0`，这条测试调用会触发断言。用户退出安全模式后，改用独立 `down` / `up` 动作进入测试画面，完成了上述复测。这次没有修改或重装既有 MKS 插件；它的 `tap` 接口问题仍然存在。PhoneYOLO 自身的检测服务不调用这个触摸接口。

## 验证边界

这证明当前设备上的全屏抓取、Core ML 推理、坐标还原、跨 App 持续推送、认证、多客户端、重连和断线释放可以工作。尚未验证其他机型/iOS、实际横屏旋转、锁屏/受保护视频、自训练模型导入，以及长时间功耗、温度和稳定性。目标 10 FPS 是限速上限，不代表这台 iPhone X 可以达到 10 FPS。

测试结束后所有测试 WebSocket 均已关闭，服务保持启用、无连接、模型未加载。
