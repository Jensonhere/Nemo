# LOOI Nemo Work 项目文档

LOOI Nemo Work 是一个面向桌面/陪伴机器人的 Flutter 应用。项目把语音唤醒、连续对话、云端 ASR、腾讯云 TTS、LLM 路由、视觉理解、蓝牙运动控制、环境监测、主人声纹和表情动画整合到同一个交互系统中。

当前代码以 Android 真机运行为主要目标；其他 Flutter 平台目录存在，但语音、蓝牙、相机和本地模型链路主要围绕 Android 设备调试。

## 当前能力总览

- 离线唤醒词：使用 Sherpa-ONNX KWS，默认唤醒词为“你好小航”。
- 连续语音对话：唤醒后进入连续对话模式，播报“你好，请说”，随后启动语音识别。
- 云端 ASR：优先使用 Qwen 云端 ASR HTTP 分块接口，支持中英混合识别。
- ASR 回退：Qwen `/healthz` 不可达时回退到本地 VOSK 中文识别。
- 腾讯云 TTS：声线切换本质是切换腾讯云 `VoiceType`，当前没有本地离线 TTS。
- 边播边听与打断：TTS 播放期间可通过同麦 VAD 或 Sherpa VAD 触发打断。
- 主人声纹：支持 1-3 条主人声纹录入、试听、删除、选择；主人模式和声纹打断模式可基于 embedding 比对过滤非主人语音。
- LLM 路由：先由 Router 判断 Dialogue、Companion、BluetoothMotion、VisionVlm、Agent 等场景，再分发给对应模块。
- 文本问答：走 OpenAI 兼容接口，支持普通对话、情绪陪伴、英语教学、设备上下文注入。
- 视觉/VLM：调用摄像头拍照并发送到视觉 API，支持“看看周围”“识别画面”等请求。
- 多步任务 Planner：复杂现实任务可拆成蓝牙动作、视觉/VLM、TTS 播报等步骤顺序执行。
- 蓝牙运动控制：连接 XHRobot 类 BLE 设备，发送运动、转向、头部动作等指令，并处理传感器回包。
- 环境监测：空闲时可自动启动环境监测，结合定位、天气、摄像头、用户检测和机器人动作。
- 手势服务：保留手势识别服务入口。
- 本地设置：支持声线选择、账号/私人智能体、历史记录、调试日志等页面。

## 主要目录

```text
lib/
  app/                         路由、Provider、API 地址和常量
  core/
    api/                       OpenAI 兼容 API 封装
    config/                    运行期开关
    debug/                     对话流程追踪
    llm/                       Router、Planner、Prompt、结构化回复
    models/                    数据模型
    modules/                   对话、视觉、动作、环境监测、动画等业务模块
    motion/                    蓝牙动作规范化
    notifiers/                 Provider 状态中枢
    services/                  ASR、TTS、蓝牙、相机、声纹、VA、定位等服务
    storage/                   SQLite 和 SharedPreferences
    utils/                     分词、语言门控、调试工具
  presentation/                页面与组件

assets/
  sherpa_kws/                  Sherpa 唤醒词模型与关键词
  sherpa_speaker/              主人声纹 embedding 模型
  cn/                          VOSK 中文模型
  models/                      本地视觉/检测 TFLite 模型
  emotion/                     表情动画 Lottie 资源
  music/                       内置音乐资源

packages/                      本地 Flutter/Dart 包
plugins/                       本地原生插件，例如腾讯 TTS plugin
```

## 启动与主流程

应用启动后，`HomeView` 会初始化全屏模式、手势服务和 `SpeechNotifierSimplified`。核心初始化顺序如下：

1. 初始化 Sherpa-ONNX 唤醒词服务。
2. 初始化 UI 动画模块。
3. 初始化 `ConversationController`。
4. 加载本地主人声纹库。
5. 启动唤醒词健康检查。
6. 若唤醒词正常，启动空闲环境监测计时器。

唤醒后的连续对话流程：

```text
用户说“你好小航”
  -> Sherpa KWS 命中
  -> 进入连续对话模式
  -> 腾讯云 TTS 播放“你好，请说”
  -> 启动 Qwen ASR
  -> ASR 定稿文本
  -> Router 判定场景
  -> 文本问答 / 视觉 / 蓝牙动作 / Planner
  -> TTS 播报结果
  -> 回到聆听态
```

## 语音识别

### Sherpa-ONNX 唤醒词

实现文件：

- `lib/core/services/sherpa_kws_wake_service.dart`
- `lib/core/notifiers/speech_notifier_simplified.dart`

默认资源目录：

```text
assets/sherpa_kws/
```

主要需要：

```text
encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx
decoder-epoch-13-avg-2-chunk-16-left-64.onnx
joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx
tokens.txt
keywords.txt
```

`keywords.txt` 中配置唤醒词，当前主逻辑以“你好小航”为待机唤醒短语。

### Qwen 云端 ASR

实现文件：

- `lib/core/services/qwen_asr_config.dart`
- `lib/core/services/qwen_cloud_asr_client.dart`
- `lib/core/services/qwen_streaming_asr_recorder.dart`

默认地址：

```text
https://a40954.xhang.buaa.edu.cn:52811
```

接口：

```text
GET  /healthz
POST /api/start
POST /api/chunk?session_id=...
POST /api/finish?session_id=...
```

可通过 dart define 覆盖：

```bash
flutter run --dart-define=QWEN_ASR_BASE_URL=https://your-host:port
```

如果 `/healthz` 不可达，系统会回退到本地 VOSK。

### VOSK 回退

本地 VOSK 中文模型位于：

```text
assets/cn/vosk-model-small-cn-0.22/
```

它主要作为 Qwen ASR 不可达时的备选路径。由于 `assets/cn/` 被 `.gitignore` 忽略，新环境需要单独准备。

## TTS 与声线

TTS 工厂：

- `lib/core/services/voice_tts_factory.dart`
- `lib/core/services/tencent_tts_service.dart`
- `lib/core/services/tencent_streaming_text_tts_service.dart`
- `lib/core/models/tts_voice_option.dart`

当前实现只使用腾讯云 TTS：

- 有 `TENCENT_TTS_APP_ID`、SecretId、SecretKey 时，使用腾讯云流式 WebSocket TTS。
- 没有 AppId 时，使用 `tts_plugin` 封装的腾讯云合成。

本地 Kokoro / Sherpa 离线 TTS 已移除。

可选声线：

```text
101028 默认声线
101002 智聆
101003 智美
101005 智莉
101004 智云
101006 智言
```

设置页的“语音声线”会保存 `tts_voice_type` 到 SharedPreferences，并调用 `ConversationController.updateTtsVoiceType()` 释放旧 TTS 服务、创建新服务。

API 密钥通过 `--dart-define` 在构建时传入，不要写入源码。以下为 PowerShell 示例：

```powershell
flutter run `
  --dart-define=OPENAI_API_KEY=your_api_key `
  --dart-define=OPENAI_API_KEY_2=your_second_api_key `
  --dart-define=AMAP_WEB_SERVICE_KEY=your_amap_key `
  --dart-define=TENCENT_TTS_APP_ID=your_app_id `
  --dart-define=TENCENT_TTS_SECRET_ID=your_secret_id `
  --dart-define=TENCENT_TTS_SECRET_KEY=your_secret_key
```

## 主人声纹

相关文件：

- `lib/core/services/sherpa_speaker_embedding_service.dart`
- `lib/core/services/speaker_enrollment_recorder.dart`
- `lib/core/services/speaker_enrollment_store.dart`
- `lib/core/services/owner_voiceprint_verifier.dart`
- `lib/presentation/widgets/owner_voiceprint_library_panel.dart`

入口：

```text
主界面右上角麦克风图标 -> 声纹库面板 -> “+” 新录音
```

引导语：

```text
请你念出：你好小航，请开始陪伴模式
```

模型文件：

```text
assets/sherpa_speaker/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
```

该模型用于 speaker embedding，不是 TTS 模型。没有它时会提示：

```text
声纹模型未就绪，请将模型放入 assets/sherpa_speaker/
```

声纹库最多保存 3 条样本。样本包含 embedding 和本地 WAV 试听文件，保存在应用文档目录下。

声纹相关模式：

- 主人模式：聆听定稿输入和 TTS 打断都需要通过主人声纹比对。
- 主人声纹打断播报：仅 TTS 播放期间，检测到人声后先比对声纹，通过后才允许打断。

## LLM 路由与对话能力

相关文件：

- `lib/core/llm/llm_router.dart`
- `lib/core/llm/llm_planner.dart`
- `lib/core/modules/conversation_controller.dart`
- `lib/core/modules/text_qa_module.dart`
- `lib/core/api/openai.api.dart`

文本和视觉 API 地址：

```text
https://xhang.buaa.edu.cn/openai/v1/chat/completions
```

Router 会先把用户输入分到以下场景：

- `Dialogue`：普通语言对话、知识问答、天气/位置缓存回答等。
- `Companion`：情绪陪伴、安慰、倾诉。
- `BluetoothMotion`：单步蓝牙机身动作。
- `VisionVlm`：单次相机/视觉理解。
- `Agent`：多步骤现实任务或多段动作。
- `WeatherAmbient` / `ToolUse`：兼容标签。

复杂度：

- A：纯文本或直接回复。
- B：单步工具或能力调用。
- C：多步骤任务，走 Planner。

处理策略：

```text
need_tools=false
  -> Router 可直接给 dialogue_reply
  -> 或进入 TextQA 模块

VisionVlm+B
  -> 拍照
  -> 视觉 API
  -> TTS 播报结果

BluetoothMotion+B
  -> 解析 motion_step
  -> 蓝牙执行
  -> 必要时短播报

Agent+C
  -> Planner 拆步骤
  -> PlanExecutor 顺序执行蓝牙、视觉、TTS 步
```

命令场景中如果 LLM 返回结构化蓝牙动作，只在 `IntentType.command` 下执行，避免普通对话误触发机器人移动。

## 视觉与情绪能力

相关文件：

- `lib/core/services/camera_resource_manager.dart`
- `lib/core/services/camera_service.dart`
- `lib/core/modules/image_analysis_module.dart`
- `lib/core/modules/emotion_recognition_module.dart`
- `lib/core/services/va_session_manager.dart`
- `lib/core/services/va_session_client.dart`
- `lib/core/services/va_pcm_recorder.dart`

视觉 API 使用 OpenAI 兼容 chat completions 接口，发送压缩后的图片和用户意图。

VA 情绪服务默认地址：

```text
https://226bee.xhang.buaa.edu.cn:52811
```

可通过 dart define 覆盖：

```bash
flutter run --dart-define=VA_BASE_URL=https://your-va-host
flutter run --dart-define=VA_API_KEY=your_key
```

Companion 场景可补跑 VA，将音频片段、缓存图像或视觉信息合入陪伴回答上下文。

## 蓝牙与机器人控制

相关文件：

- `lib/core/services/bluetooth_service.dart`
- `lib/core/modules/action_command_module.dart`
- `lib/core/motion/motion_step_bluetooth.dart`

目标设备名通常包含：

```text
XHRobot
```

BLE UUID：

```text
Service: 6e400001-b5a3-f393-e0a9-e50e24dcca9e
RX:      6e400002-b5a3-f393-e0a9-e50e24dcca9e
TX:      6e400003-b5a3-f393-e0a9-e50e24dcca9e
```

支持能力包括：

- 前进、后退、左转、右转。
- 头部动作、点头、抬头、低头等。
- 读取运动开始、完成、中断、传感器状态。
- 障碍物和悬崖中断处理。
- 安全回退与自动重连。

LLM Router 的 `motion_step` 格式：

```text
前进,250
后退,100
左转,45
右转,180
```

直线单位为毫米，转向单位为角度。

## 环境监测

相关文件：

- `lib/core/modules/environ_monitor_module.dart`
- `lib/core/services/device_context_service.dart`
- `lib/core/services/ambient_context_cache.dart`

环境监测由 `DebugRuntimeFlags.enableEnvironmentMonitoring` 控制，当前为 `true`。

主要能力：

- 空闲计时后启动环境监测。
- IP 定位、高德天气、逆地理缓存。
- 摄像头识别用户。
- 必要时配合蓝牙运动寻找用户。
- 对话中自动跳过或暂停，避免与连续对话抢麦克风/摄像头。

高德 Key 位于：

```text
lib/app/constants/app.keys.dart
```

## UI 与表情动画

相关文件：

- `lib/presentation/screens/homeView/home.view.dart`
- `lib/core/modules/ui_animation_module.dart`
- `lib/core/llm/planner_expression_catalog.dart`

主界面以 Lottie 表情为中心显示。连续对话模式中，表情主要由 `UIAnimationModule` 统一管理。TTS 相关表情尽量在播放器进入 `PlayerState.playing` 时切换，以贴近首帧出声。

常见状态：

- 待机：眨眼。
- 唤醒欢迎 / TTS：说话。
- 聆听：可爱。
- 等模型：思考。
- 视觉：观察。
- 情绪陪伴：倾听、委屈、失落、孤独等。
- 风险/中断：愤怒、惊讶等。

## 设置、账号和历史

相关文件：

- `lib/presentation/screens/settingsView/settings.view.dart`
- `lib/core/storage/preference_manager.dart`
- `lib/core/storage/app_database.dart`
- `lib/core/notifiers/user.notifier.dart`

设置页包含：

- 语音声线。
- 功能/机器人相关设置。
- 私人智能体入口。
- 历史记录。
- 登录/注册相关入口。

SharedPreferences 保存轻量设置，SQLite 保存账号、私人智能体、对话历史等结构化数据。

## 本地资源与模型

由于 `.gitignore` 中包含：

```text
*.onnx
*.tflite
*.bin
assets/cn/
assets/models/
```

不少模型和大资源不会随 Git 正常提交或拉取。新环境需要检查以下资源：

### 必需或常用

```text
assets/sherpa_kws/*.onnx                 离线唤醒词
assets/sherpa_speaker/*.onnx             主人声纹 embedding
assets/cn/vosk-model-small-cn-0.22/      VOSK 回退识别
assets/models/*.tflite                   本地检测/手势/视觉辅助模型
assets/emotion/**                        表情动画
assets/music/*.mp3                       内置音乐
```

声纹模型下载后应放置为：

```text
assets/sherpa_speaker/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
```

放入模型后需要完整重新构建或重新安装应用，不要只 hot reload。

## 运行方式

常规 Android 调试：

```bash
flutter pub get
flutter run
```

如果刚新增或替换了资源模型，建议：

```bash
flutter clean
flutter pub get
flutter run
```

常用 dart define：

```bash
flutter run ^
  --dart-define=QWEN_ASR_BASE_URL=https://your-qwen-asr ^
  --dart-define=VA_BASE_URL=https://your-va ^
  --dart-define=VA_API_KEY=your-va-key ^
  --dart-define=OPENAI_API_KEY=your-api-key ^
  --dart-define=OPENAI_API_KEY_2=your-second-api-key ^
  --dart-define=AMAP_WEB_SERVICE_KEY=your-amap-key ^
  --dart-define=TENCENT_TTS_APP_ID=your-app-id ^
  --dart-define=TENCENT_TTS_SECRET_ID=your-secret-id ^
  --dart-define=TENCENT_TTS_SECRET_KEY=your-secret-key
```

## 调试建议

- 主界面右上角“日志”可查看应用内日志。
- Qwen ASR 是否可用，看日志中的 `[QWEN /healthz] OK` 和 `当前语音识别引擎: Qwen 云端 ASR`。
- 声纹不可用时，先检查 `assets/sherpa_speaker/` 下是否有指定 ONNX 模型。
- TTS 声线不对时，检查设置页保存的 `tts_voice_type` 和日志中的 `TTS 声线`。
- 蓝牙不可用时，检查设备名、权限、UUID 和是否已连接 `XHRobot`。
- 环境监测干扰调试时，可临时把 `DebugRuntimeFlags.enableEnvironmentMonitoring` 改为 `false`。

## 常见问题

### Qwen ASR 是可用还是不可用？

看日志：

```text
[QWEN /healthz] OK
当前语音识别引擎: Qwen 云端 ASR
```

出现这两行说明 Qwen ASR 可用。如果不可达，会回退到 VOSK。

### “不可使用：请先在右上角录入主人声音”是什么意思？

这不是 Qwen ASR 不可用，而是主人声纹库为空。请在主界面右上角点击麦克风图标，打开声纹库后点 `+` 录入。

### “声纹模型未就绪”怎么办？

把下面这个模型放入 `assets/sherpa_speaker/`：

```text
3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
```

然后重新编译安装应用。

### TTS 是本地还是云端？

当前是腾讯云 TTS。声线切换是切腾讯云 `VoiceType`。本地离线 TTS 已移除。

### 为什么 Git status 看不到刚放进去的 ONNX？

因为 `.gitignore` 忽略了 `*.onnx`。这是正常现象，但也意味着新机器需要手动准备这些模型。

## 开发注意事项

- 不要把大模型文件、密钥、构建产物直接提交到仓库。
- 对话主链路尽量从 `SpeechNotifierSimplified` 和 `ConversationController` 读起。
- 新增外部能力优先接入 Router/Planner，不要绕过场景判定直接执行。
- 涉及麦克风、TTS、ASR、Sherpa 的改动要特别注意资源互斥，Android 上 AudioRecord 争用容易导致异常。
- 涉及蓝牙运动的改动要保守，必须考虑悬崖、障碍物和中断回包。
- 修改资源目录后要重新构建应用，确认 `AssetManifest.json` 包含新资源。
