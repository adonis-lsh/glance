# Glance 简体中文版

基于 [jonnyoo/glance](https://github.com/jonnyoo/glance) 的中文分支，保留原项目 MIT 许可证与作者署名。

## 中文支持

- 应用自身文案默认使用简体中文，不受 macOS 首选语言影响，无需额外切换。
- 翻译首次设置、权限说明、安全提示、九方向人脸录入、密码设置、菜单栏、全部设置页、无障碍标签、应用错误提示与人脸实验室。
- 保留 Glance、Touch ID、ArcFace 等产品/模型名称，以及模型标识、存储键、系统接口名称和诊断字段。macOS 系统弹窗和系统返回的错误详情仍遵循系统语言。
- 应用文件名、可执行文件名和系统显示名称统一为 `Glance`，安装包内为 `Glance.app`。
- 这不是上游官方发行版。所有更新入口统一打开 [咱们 GitHub 的最新 Release](https://github.com/adonis-lsh/glance/releases/latest)，手动下载更新；原版 Sparkle 自动更新停用，避免原版更新覆盖中文。

## 安装

要求 macOS 15 或更高版本，支持 Intel 与 Apple Silicon。

1. 在 [本分支 Releases](https://github.com/adonis-lsh/glance/releases) 下载 `Glance-zh-CN-universal.dmg`。
2. 退出正在运行的 Glance，将磁盘映像中的 `Glance.app` 拖入“应用程序”。本分支保留原应用标识，会替换同名原版；请勿同时运行两个版本。
3. 打开后按中文引导授权摄像头和辅助功能。签名变化可能需要重新授权；钥匙串访问由 macOS 决定，不会自动删除已有密码或人脸数据。

构建包使用临时签名（ad-hoc），没有 Apple Developer ID 签名或公证。若 macOS 拦截，在确认下载来源后，通过“系统设置 → 隐私与安全性”中针对该应用的“仍要打开”操作处理。不要关闭系统整体安全保护。

## 安全与隐私

### 无开发者证书的兼容版

兼容版改用 macOS 的传统登录钥匙串保存随机 AES 会话密钥及加密密码，不使用需要开发者授权的 Data Protection Keychain 访问组。钥匙串项目使用仅信任创建应用的默认 ACL，不向所有应用开放。会话解锁时，Glance 先通过 LocalAuthentication 请求 Touch ID 或系统登录密码验证，成功后才载入会话密钥；取消或失败不会解锁会话。密码与人脸数据继续使用 AES-GCM 加密。

这与原版 `.userPresence` 的保护边界不同：原版由钥匙串强制要求身份验证，兼容版由应用执行身份验证后再读取登录钥匙串。临时签名的应用更新后，系统可能再次请求钥匙串访问确认；不能将兼容版视为具有与原版相同的签名身份和防篡改保证。

兼容版使用独立的钥匙串 service、偏好设置域及 `face-identities.compat-v1.enc` 文件。首次使用需要重新录入人脸和密码，不读取、覆盖或删除官方原版的凭据和人脸文件。退出应用或锁定会话后，必须重新通过系统身份验证；处于已授权会话时，锁屏解锁仍须通过真实锁屏状态、人脸匹配、活体检测和辅助功能检查。

### 开盖失败诊断

扫描动画不代表摄像头已经输出图像。新版会等待首帧并区分摄像头启动/出帧失败、未检测到人脸、不匹配、活体检测未通过及密码输入后未确认解锁。设置中的识别页显示最近一次结果，诊断日志仅记录阶段、结果和计数，不记录密码、图片、人脸特征向量或姓名。不会为提高成功率而自动降低匹配阈值或关闭活体检测。

摄像头预览与人脸实验室会在睡眠或锁屏时停止预览，减少与锁屏扫描争用摄像头。发送密码后最多等待两秒确认退出锁屏；未确认时显示失败，且不自动再次提交密码。

Glance 的安全性不及 Apple 的 Face ID 或 Touch ID。普通摄像头没有深度传感器；活体检测不能可靠防御本人视频。应用通过在锁屏界面输入已保存的密码解锁，属于便利功能。

人脸图像仅在内存中处理，特征向量与密码在设备本地加密保存。兼容版的凭据存储变化见上文；匹配阈值和活体检测要求保持不变。完整原版原理见 [原版 README](README.md)。

## 构建与验证

应用图标使用 `glance/Assets.xcassets/AppIcon.appiconset` 中的 macOS 标准尺寸资源，来源为上游已有的 `appicon.imageset/appicon.png`；工程的应用图标名称必须与 `AppIcon` 一致。这样 macOS 15 也能读取传统 `.icns` 应用图标。修复版 `v1.2-zh-CN.2` 解决首版打包后仅显示占位图标的问题。

本机需要 Xcode 26+；仓库内 `.github/workflows/build-chinese.yml` 也支持手动触发 GitHub macOS 构建。

```sh
xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

工作流执行 Release 通用架构构建、临时签名与签名校验，检查 `Glance` 名称和更新地址、二进制架构、默认语言、中文权限文案、上游更新禁用标记及应用图标声明和 `.icns` 资源，再生成 DMG、ZIP 和 SHA-256 校验文件。成功构建不代表摄像头识别或真实锁屏解锁已完成实机验证。

`tools/credential_selftest.swift` 使用实际登录钥匙串代码、随机测试 service 和公开测试数据，覆盖加密读写、认证取消、并发、锁定及删除；系统认证在该自测中使用替身，不会绕过真实应用的认证。`tools/unlock_injection_selftest.swift` 使用真实控制器和系统状态/按键替身，验证锁屏门禁与成功确认，不发送真实按键。这些自测不能替代真实系统身份验证、人脸录入和开盖解锁测试。

### v1.2-zh-CN.4 实机验证

2026-10-22，在本机 Intel Mac、macOS 15.7.7 上安装构建 7 后，用户完成真实系统身份验证、人脸及密码设置。已确认兼容版钥匙串条目和人脸加密文件保存成功；用户分别确认普通锁屏、合盖再开盖后均由 Glance 自动解锁。对应两次应用日志均记录人脸匹配、活体检测通过，并确认锁屏退出。

上述结果覆盖本机本次各一次测试，尚不代表长时间睡眠、重启后或所有机型均已验证。临时签名及兼容版身份验证的保护边界仍见上文。
