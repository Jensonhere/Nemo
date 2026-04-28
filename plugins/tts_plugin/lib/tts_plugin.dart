import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class TTSData {
  Uint8List data; //音频数据
  String text; //合成文本
  String resp; //服务端返回的原始数据
  String? utteranceId; //合成传入标识
  TTSData(this.data, this.text, this.utteranceId, this.resp);
}

class TTSError implements Exception {
  int code = 0; // 错误码
  String message = ""; // 错误信息
  String? serverMessage; // 服务端错误信息
}

class TTSControllerConfig {
  String secretId = ""; // 腾讯云 secretId
  String secretKey = ""; //腾讯云 secretKey
  String? token; //使用临时密钥需要设置token
  double voiceSpeed = 0; // 语速,详情见API文档
  double voiceVolume = 1; // 音量,详情见API文档
  int voiceType = 1001; // 音色,详情见API文档
  int voiceLanguage = 1; // 语音,详情见API文档
  String codec = "mp3"; // 编码,详情见API文档
  int connectTimeout = 15 * 1000; //连接超时，范围：[500,30000]，单位ms，默认15000ms
  int readTimeout = 30 * 1000; //读取超时，范围：[2200,60000]，单位ms ，默认30000ms

  Map toMap() {
    return {
      "secretId": secretId,
      "secretKey": secretKey,
      "token": token,
      "voiceSpeed": voiceSpeed,
      "voiceVolume": voiceVolume,
      "voiceType": voiceType,
      "voiceLanguage": voiceLanguage,
      "codec": codec,
      "connectTimeout": connectTimeout,
      "readTimeout": readTimeout
    };
  }
}

class TTSController {
  final MethodChannel _methodChannel = const MethodChannel('tts_plugin');
  final StreamController<TTSData> _streamCtl =
      StreamController<TTSData>.broadcast();

  set config(TTSControllerConfig config) {
    _methodChannel.invokeMethod("TTSController.config", config.toMap());
  }

  Stream<TTSData> get listener {
    return _streamCtl.stream;
  }

  static TTSController instance = TTSController();

  TTSController() {
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method == "onSynthesizeData") {
        var data = call.arguments["data"];
        var text = call.arguments["text"];
        var resp = call.arguments["resp"];
        var utteranceId = call.arguments["utteranceId"];
        _streamCtl.add(TTSData(data, text, utteranceId, resp));
      } else if (call.method == "onError") {
        var ttsError = TTSError();
        var info = Map<String, dynamic>.from(call.arguments as Map);
        ttsError.code = call.arguments["code"];
        ttsError.message = call.arguments["message"];
        if (info.containsKey("serverMessage")) {
          ttsError.serverMessage = info['serverMessage'];
        }
        _streamCtl.addError(ttsError);
      }
    });
  }

  /**
   * 合成
   * @text 合成文本
   * @utterancId 合成文本附带参数,仅用于回调
   */
  synthesize(String text, String? utteranceId) async {
    await _methodChannel.invokeMethod("TTSController.init", null);
    await _methodChannel.invokeMethod("TTSController.synthesize", {
      "text": text,
      "utteranceId": utteranceId,
    });
  }

  /**
   * 设置自定义参数
   * @param key 自定义参数key
   * @param value 自定义参数value
   */
  setApiParam(String key, Object value) async {
    if (Platform.isIOS && value is bool) {
      value = value ? "true" : "false";
    }
    await _methodChannel.invokeMethod("TTSController.setApiParam", {
      "key": key,
      "value": value,
    });
  }

  /**
   * 取消未进行合成的任务
   */
  cancel() async {
    await _methodChannel.invokeMethod("TTSController.cancel", null);
  }

  /**
   * 释放资源
   */
  release() async {
    await _methodChannel.invokeMethod("TTSController.release");
  }
}
