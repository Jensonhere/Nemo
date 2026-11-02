# Flutter SDK
SDK以插件的方式封装了Android和iOS语音合成功能,提供flutter版本的语音合成,本文介绍SDK的安装方法及示例

## 开发环境
- dart >= 2.18.4
- flutter >= 3.3.8

## 获取安装
[下载SDK]() SDK内tts_plugin目录即为flutter插件,插件内example目录下为demo示例

## 接口说明
接口示例代码为demo部分代码,完整代码请参考位于example里的demo示例
### TTSControllerConfig
TTSController相关配置

**参数**
```
String secretId = ""; // 腾讯云 secretId
String secretKey = ""; //腾讯云 secretKey
String? token; //使用临时密钥需要设置token
double voiceSpeed = 0; // 语速,详情见API文档
double voiceVolume = 1; // 音量,详情见API文档
int voiceType = 1001; // 音色,详情见API文档
int voiceLanguage = 1; // 语音,详情见API文档
String codec = "mp3"; // 编码,详情见API文档
int connectTimeout = 15 * 1000; //连接超时，范围：[500,30000]，单位ms，默认15000ms
int readTimeout = 30 * 1000;//读取超时，范围：[2200,60000]，单位ms ，默认30000ms
```
**示例**
```dart
var _config = TTSControllerConfig();
_config.secretId = secretId;
TTSController.instance.config = _config;
```
### TTSController
控制语音合成的流程及获取语音合成的结果,该类为单例模式

**方法**
```
synthesize(String text, String? utteranceId) async <--> 合成
cancel() async <--> 停止合成
release() async <--> 释放资源
```
**示例**
```dart
await TTSController.instance
    .synthesize(_text, null);
await for (TTSData ret
    in TTSController.instance.listener) {
  final dir = await getTemporaryDirectory();
  var file = await File(
          "${dir.path}/tmp_${DateTime.now().millisecondsSinceEpoch}_${_config.voiceVolume}.${_config.codec}")
      .writeAsBytes(ret.data);
  setState(() {
    _result = "合成成功";
    _state = 0;
    _synthesize_file_path =
        file.absolute.path;
  });
```
### TTSData
合成的音频数据

**参数**
```
Uint8List data; //音频数据
String text; //合成文本
String? utteranceId; //合成传入标识
```
### TTSError
合成过程中的错误,错误码参考[Android SDK](https://cloud.tencent.com/document/product/1073/80487)与[iOS SDK文档](https://cloud.tencent.com/document/product/1073/80488)里面客户端错误码

**参数**
```
int code = 0; // 错误码
String message = ""; // 错误信息
String? serverMessage; // 服务端错误信息
```
