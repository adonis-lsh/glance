# Glance 简体中文版

基于 [jonnyoo/glance](https://github.com/jonnyoo/glance) 的中文分支，保留原项目 MIT 许可证与作者署名。

## 中文支持

- 应用自身文案默认使用简体中文，不受 macOS 首选语言影响，无需额外切换。
- 翻译首次设置、权限说明、安全提示、九方向人脸录入、密码设置、菜单栏、全部设置页、无障碍标签、应用错误提示与人脸实验室。
- 保留 Glance、Touch ID、ArcFace 等产品/模型名称，以及模型标识、存储键、系统接口名称和诊断字段。macOS 系统弹窗和系统返回的错误详情仍遵循系统语言。
- 这不是上游官方发行版。原版 Sparkle 自动更新停用，关于页面改为打开本分支的 Releases，避免原版更新覆盖中文。

## 安装

要求 macOS 15 或更高版本，支持 Intel 与 Apple Silicon。

1. 在 [本分支 Releases](https://github.com/adonis-lsh/glance/releases) 下载 `Glance-zh-CN-universal.dmg`。
2. 退出正在运行的 Glance，将磁盘映像中的 `glance.app` 拖入“应用程序”。本分支保留原应用标识，会替换同名原版；请勿同时运行两个版本。
3. 打开后按中文引导授权摄像头和辅助功能。签名变化可能需要重新授权；钥匙串访问由 macOS 决定，不会自动删除已有密码或人脸数据。

构建包使用临时签名（ad-hoc），没有 Apple Developer ID 签名或公证。若 macOS 拦截，在确认下载来源后，通过“系统设置 → 隐私与安全性”中针对该应用的“仍要打开”操作处理。不要关闭系统整体安全保护。

## 安全与隐私

Glance 的安全性不及 Apple 的 Face ID 或 Touch ID。普通摄像头没有深度传感器；活体检测不能可靠防御本人视频。应用通过在锁屏界面输入已保存的密码解锁，属于便利功能。

人脸图像仅在内存中处理，特征向量与密码在设备本地加密保存。中文改动不改变识别阈值、活体检测、凭据存储、解锁逻辑或网络隐私策略。完整原理见 [原版 README](README.md)。

## 构建与验证

应用图标使用 `glance/Assets.xcassets/AppIcon.appiconset` 中的 macOS 标准尺寸资源，来源为上游已有的 `appicon.imageset/appicon.png`；工程的应用图标名称必须与 `AppIcon` 一致。这样 macOS 15 也能读取传统 `.icns` 应用图标。修复版 `v1.2-zh-CN.2` 解决首版打包后仅显示占位图标的问题。

本机需要 Xcode 26+；仓库内 `.github/workflows/build-chinese.yml` 也支持手动触发 GitHub macOS 构建。

```sh
xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

工作流执行 Release 通用架构构建、临时签名与签名校验，检查二进制架构、默认语言、中文权限文案、上游更新禁用标记及应用图标声明和 `.icns` 资源，再生成 DMG、ZIP 和 SHA-256 校验文件。成功构建不代表摄像头识别或真实锁屏解锁已完成实机验证。
