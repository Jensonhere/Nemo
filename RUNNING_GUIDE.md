# LOOI Nemo 运行指南（Windows + Android 真机）

这份指南面向第一次接触 Flutter 的同学。请按顺序操作；第一次构建会下载依赖，可能需要几分钟。

> **先了解**
>
> - 当前项目主要面向 Android 真机调试。
> - `pubspec.yaml` 要求 Dart `>=2.19.2 <3.0.0`。请使用 Flutter 3.7.12（自带 Dart 2.19.6）这一代的 Flutter，不要直接使用自带 Dart 3 的新版 Flutter，否则 `flutter pub get` 会因 SDK 版本不兼容而失败。
> - 项目的唤醒词模型文件不在 Git 中，需要按第 5 步单独准备。
> - 大语言模型、语音合成等云服务需要获批的 API 凭证和网络访问权限。没有凭证时仍可尝试编译、安装和打开应用，但云端问答、语音等功能可能不可用。

## 1. 安装开发工具

在 Windows 上准备：

1. **Git**：用于下载项目。安装后打开 PowerShell，运行 `git --version` 检查。
2. **Flutter 3.7.12**：从 [Flutter SDK archive](https://docs.flutter.dev/install/archive) 下载 Windows 版本，并将 Flutter 的 `bin` 目录加入 `PATH`。重新打开 PowerShell 后运行：

   ```powershell
   flutter --version
   ```

   输出中的 Flutter 版本应为 `3.7.12`，Dart 版本应为 `2.19.x`。
3. **Android Studio**：安装 Android SDK、Android SDK Platform 34、Android SDK Platform-Tools 和 Android SDK Command-line Tools。Android Studio 自带的 JDK 通常可以使用。

然后在 PowerShell 运行：

```powershell
flutter doctor
flutter doctor --android-licenses
```

按提示接受 Android SDK 许可。再次运行 `flutter doctor`，确认 Android toolchain 没有错误。暂时不用处理与 Android 真机运行无关的平台提示。

## 2. 下载项目

打开 PowerShell，逐行运行：

```powershell
cd $HOME
git clone https://github.com/Jensonhere/Nemo.git
cd .\Nemo
```

后续命令都在项目根目录执行——也就是能看到 `pubspec.yaml` 的目录。可以用下面的命令确认：

```powershell
Get-ChildItem pubspec.yaml
```

## 3. 连接 Android 手机

1. 在手机设置中打开“开发者选项”和“USB 调试”。
2. 用 USB 数据线连接电脑，手机弹出授权提示时选择“允许”。
3. 在项目目录运行：

   ```powershell
   flutter devices
   ```

   确认列表中出现手机名称、设备 ID 和 `android-arm64`。如果没有出现，检查手机是否已解锁、USB 调试授权是否已允许，或更换数据线/USB 接口。

## 4. 获取 Flutter 依赖

在项目根目录运行：

```powershell
flutter pub get
```

看到 `Got dependencies!` 表示依赖解析完成。**普通运行不需要每次都执行 `flutter clean`**；只有更换 Flutter 版本或遇到构建缓存问题时再尝试清理。

## 5. 准备唤醒词模型

Git 不包含 `.onnx` 模型文件。缺少这些文件时，应用可能仍能打开，但离线唤醒词“你好小航”不能正常工作。

1. 从 Sherpa-ONNX 官方的 [KWS 模型发布页](https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models)下载模型包 `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2`。
2. 用 7-Zip 等工具解压。解压后的模型目录中，找到下面三个文件和 `tokens.txt`，复制到项目的 `assets\sherpa_kws\` 目录：

   ```text
   encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx
   decoder-epoch-13-avg-2-chunk-16-left-64.onnx
   joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx
   tokens.txt
   ```

   仓库已提供 `assets\sherpa_kws\keywords.txt`，不需要替换。复制后，目录中应同时有上面四个文件和 `keywords.txt`。
3. 在 PowerShell 检查文件是否齐全：

   ```powershell
   $required = @(
     "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
     "decoder-epoch-13-avg-2-chunk-16-left-64.onnx",
     "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
     "tokens.txt",
     "keywords.txt"
   )
   $required | ForEach-Object {
     if (Test-Path (Join-Path "assets\sherpa_kws" $_)) {
       "OK      $_"
     } else {
       "缺少    $_"
     }
   }
   ```

模型文件被 Git 忽略是有意的：不要把模型或其他大文件提交到仓库。更换模型后必须重新完整构建和安装，不能只做热重载。

## 6. 配置云服务凭证（按需）

请向课程/项目负责人申请**获准使用**的凭证和服务访问权限。不要向同学群、截图、Git 提交或公开仓库发送真实密钥。

应用使用 `--dart-define` 接收构建时配置。以下 PowerShell 会逐项隐藏输入；只填写负责人实际发给你的值，拿不到的可按后文说明留空：

```powershell
function Read-LocalApiKey($name) {
  $secure = Read-Host $name -AsSecureString
  [System.Net.NetworkCredential]::new("", $secure).Password
}

$env:OPENAI_API_KEY = Read-LocalApiKey "OPENAI_API_KEY（文本问答）"
$env:OPENAI_API_KEY_2 = Read-LocalApiKey "OPENAI_API_KEY_2（如负责人提供）"
$env:AMAP_WEB_SERVICE_KEY = Read-LocalApiKey "AMAP_WEB_SERVICE_KEY（如负责人提供）"
$env:TENCENT_TTS_APP_ID = Read-Host "TENCENT_TTS_APP_ID（如负责人提供）"
$env:TENCENT_TTS_SECRET_ID = Read-LocalApiKey "TENCENT_TTS_SECRET_ID（如负责人提供）"
$env:TENCENT_TTS_SECRET_KEY = Read-LocalApiKey "TENCENT_TTS_SECRET_KEY（如负责人提供）"
```

这些变量只存在于当前 PowerShell 窗口。运行应用时，在同一窗口执行下一步的命令。不要把自己的值写进 `.dart`、`.md`、`.ps1` 文件。

文本 API 凭证缺失时，应用可能无法回答云端问答；腾讯云 TTS 的 App ID、SecretId 或 SecretKey 缺失时，云端语音合成不可用。高德地图凭证用于天气/位置等设备上下文，可按需配置。Qwen ASR 和 VA 服务默认使用项目配置的服务器地址；如服务器不可达或没有访问权限，请联系项目负责人。

## 7. 编译并运行

先查看 `flutter devices` 输出，设置手机设备 ID，然后运行：

```powershell
$deviceId = "替换成手机对应的设备ID"
flutter run -d $deviceId `
  --dart-define=OPENAI_API_KEY=$env:OPENAI_API_KEY `
  --dart-define=OPENAI_API_KEY_2=$env:OPENAI_API_KEY_2 `
  --dart-define=AMAP_WEB_SERVICE_KEY=$env:AMAP_WEB_SERVICE_KEY `
  --dart-define=TENCENT_TTS_APP_ID=$env:TENCENT_TTS_APP_ID `
  --dart-define=TENCENT_TTS_SECRET_ID=$env:TENCENT_TTS_SECRET_ID `
  --dart-define=TENCENT_TTS_SECRET_KEY=$env:TENCENT_TTS_SECRET_KEY
```

首次构建需要下载 Android/Flutter 依赖，耐心等待；手机上出现应用界面即表示安装启动成功。手机弹出麦克风、相机、蓝牙等权限请求时，根据要测试的功能允许。

在运行 Flutter 的终端中：

- `r`：热重载 Dart/UI 代码。
- `R`：热重启应用。
- `q`：停止运行。

热重载不会更新新增的模型资源；模型放好后需要停止应用，再重新执行 `flutter run`。

运行完毕后，可以清理当前终端中的凭证变量：

```powershell
Remove-Item Env:OPENAI_API_KEY, Env:OPENAI_API_KEY_2, Env:AMAP_WEB_SERVICE_KEY, Env:TENCENT_TTS_APP_ID, Env:TENCENT_TTS_SECRET_ID, Env:TENCENT_TTS_SECRET_KEY -ErrorAction SilentlyContinue
```

## 8. 首次运行可能遇到的情况

- **`flutter pub get` 报 Dart SDK 版本不兼容**：运行 `flutter --version` 检查是不是 Flutter 3.7.12 / Dart 2.19.x。该项目当前的 `pubspec.yaml` 不接受 Dart 3。
- **`flutter devices` 看不到手机**：解锁手机并接受 USB 调试授权；检查数据线、USB 调试开关和 Android SDK Platform-Tools。
- **提示缺少 Sherpa/KWS 模型**：回到第 5 步，检查五个文件是否都在 `assets\sherpa_kws\` 下，然后停止并重新运行应用。
- **唤醒正常，但没有识别结果**：Qwen ASR 需要能访问项目配置的服务器。若云端 ASR 不可用，本地 VOSK 回退模型 `assets\cn\vosk-model-small-cn-0.22\` 不在 Git 中，需要另行准备。
- **“声纹模型未就绪”**：这是可选功能。主人声纹模型 `.onnx` 不在 Git 中；如需录入声纹，请按 `assets\sherpa_speaker\README.md` 的说明获取模型。
- **问答或 TTS 报认证错误**：确认已获得对应服务的授权凭证、当前网络可访问服务，并重新运行命令传入 `--dart-define`。不要把真实密钥贴进公开 issue。
- **构建失败或报错看不懂**：先记录终端中第一条 `Error` 及其前后信息，并向项目负责人求助；不要先删除模型或修改 Gradle 配置。

## 9. 常用命令速查

在项目根目录：

```powershell
flutter --version
flutter doctor
flutter devices
flutter pub get
flutter run -d "手机设备ID"
```
