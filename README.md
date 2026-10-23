# Voice Notes（录音转文字）

iOS 原生录音转文字 App：SwiftUI + 苹果 Speech 框架，优先设备端识别、录音不上传；
支持实时转写、录完精转、导入音频文件转写。付费下载 $1.99，美区 App Store。

工程由 **XcodeGen** 从 `project.yml` 生成，仓库不提交 `.xcodeproj`。
Bundle ID 占位：`com.dongzhou.voicenotes`（在 App Store Connect 注册后如需改，改 `project.yml` 一处）。

## 目录

```
project.yml                  XcodeGen 工程定义
ExportOptions.plist          归档导出配置（teamID 由 CI 注入）
.github/workflows/build.yml  CI：编译检查 + TestFlight 上传
VoiceNotes/
  VoiceNotesApp.swift        App 入口
  ContentView.swift          TabView（录音 / 历史 / 设置）
  Models/                    RecordingItem、RecordingStore（Codable + FileManager）
  Audio/                     AudioRecorder（AVAudioEngine 录音落盘+电平）、
                             Transcriber（Speech 实时/文件转写、长音频分段）、
                             AudioPlayer（详情页回放）
  Views/                     RecordView、HistoryView、RecordingDetailView、SettingsView
  Support/                   SettingsStore、L10n、Formatting
  Info.plist                 权限文案（麦克风 / 语音识别）等
  en.lproj / zh-Hans.lproj   Localizable.strings + InfoPlist.strings（中英双语）
```

## 本地构建（需要一台 Mac）

前置：Xcode 15+、XcodeGen（`brew install xcodegen`）。

```bash
xcodegen generate
open VoiceNotes.xcodeproj
```

在 Xcode 里选中自己的开发者团队（Signing & Capabilities → Team），
连真机运行即可。模拟器可以编译，但**麦克风录音与语音识别必须真机验证**。

命令行无签名编译检查（与 CI 第一个作业一致）：

```bash
xcodegen generate
xcodebuild -project VoiceNotes.xcodeproj -scheme VoiceNotes \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## CI 构建

GitHub Actions（`.github/workflows/build.yml`）两个作业：

1. **build-check**：push / PR 自动跑，无签名编译，不需要任何 Secrets；
2. **testflight**：仅手动触发（Actions 页 Run workflow），归档 → 导出 IPA → 上传 TestFlight。

### 需要用户（账号持有人）提供的 Secrets

在仓库 Settings → Secrets and variables → Actions 里配置，**密钥不进代码仓库**：

| Secret 名 | 内容 | 从哪来 |
|---|---|---|
| `APPLE_TEAM_ID` | 开发者团队 ID | App Store Connect 会员资格页 |
| `ASC_KEY_ID` | API Key ID | ASC「用户和访问 → 集成 → App Store Connect API」生成密钥时显示 |
| `ASC_ISSUER_ID` | API Issuer ID | 同上页面顶部 |
| `ASC_KEY_P8_BASE64` | `.p8` 密钥文件内容的 base64 | 生成密钥后下载 `.p8`（**只能下载一次**），本地执行 `base64 -i AuthKey_XXXXXX.p8` 后把输出整段填入 |

## 上架检查清单（App Store Connect）

- [ ] Paid Apps Agreement 已签署且状态 Active（付费 App 硬前置）
- [ ] 税表 W-8BEN 已提交；Banking 已填万里汇美国账户的美元收款信息
- [ ] App ID / Bundle ID 已注册，与 `project.yml` 一致
- [ ] App 图标 1024×1024 已补进 `Assets.xcassets/AppIcon.appiconset`（当前为空占位）
- [ ] 隐私政策页 URL 已上线（GitHub Pages 静态页即可）并填入 ASC
- [ ] App 隐私标签申报与实际行为一致（设备端识别优先；设备端不可用时走苹果服务器识别）
- [ ] 商店截图（录音页 / 历史页 / 详情页）、名称、副标题、描述、关键词就绪
- [ ] TestFlight 真机试用通过：录音暂停/继续、实时出字、5 分钟以上长录音精转、导入外部音频转写
- [ ] 定价设为 $1.99（Tier 2），销售范围选美国

## 已知实现说明

- 录音用 `AVAudioEngine` 而非 `AVAudioRecorder`：后者拿不到原始音频流，无法同时做实时转写。
  引擎同一路音频一份写 AAC/m4a 落盘、一份喂 Speech 框架。
- Speech 识别请求有单次时长上限：文件转写按 50 秒切片（AVAssetExportSession 导出时间片逐段转），
  实时识别每约 50 秒滚动重启请求并固化已确认段落。
- 设备端识别（`requiresOnDeviceRecognition`）仅在 `supportsOnDeviceRecognition` 为真时启用；
  不支持的机型/语言会回退苹果服务器识别，设置页有如实提示。
- 来电等系统打断时录音自动暂停，已录部分保留，恢复需手动点继续。
- 数据层用 Codable + JSON 索引文件 + 沙盒音频文件，无数据库迁移风险（见 RecordingStore 注释）。

> ⚠️ 本脚手架在无 Xcode 的环境中编写，**未经真实编译验证**。
> 第一个里程碑就是让 CI 的 build-check 跑通，按报错逐个修。
