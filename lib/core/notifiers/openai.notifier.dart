import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/models/response.model.dart';
import 'package:voicegpt/core/notifiers/speech_notifier_simplified.dart';
import 'package:voicegpt/core/services/ambient_context_cache.dart';
import 'package:voicegpt/core/services/device_context_service.dart';

class OpenAINotifier with ChangeNotifier {
  final OpenAI _openAI = OpenAI();
  bool check = false;
  List<String>? _data;
  String? _lastResponse;

  bool get getCheck => check;

  List<String>? get getData => _data;

  Future getResponse({
    required String parameter,
    required BuildContext context,
  }) async {
    try {
      // 检查是否重复问题
      if (_lastResponse == parameter) {
        return;
      }
      _lastResponse = parameter;

      final speechNotifier =
          Provider.of<SpeechNotifierSimplified>(context, listen: false);
      // 仅在与问题相关时拉定位/天气；普通问答不阻塞
      String? deviceContext;
      final mode = DeviceContextService.fetchModeForQuery(parameter);
      final svc = DeviceContextService();
      try {
        if (mode == DeviceContextFetchMode.full) {
          deviceContext = await svc.getContextBlock();
        } else if (mode == DeviceContextFetchMode.localTimeOnly) {
          deviceContext = svc.getLocalTimeContextBlock();
        } else if (mode == DeviceContextFetchMode.cachedAmbient) {
          deviceContext = AmbientContextCache.instance.buildPromptBlock();
        }
      } catch (e) {
        // 获取失败时仍可对话，仅无上下文
      }
      final userData = await _openAI.generateText(parameter, deviceContext: deviceContext);
      final response = ResponseModel.fromJson(userData);

      _data = response.choices.map((e) => e.message.content).toList();
      check = true;
      notifyListeners();

      // await speechNotifier.safeSpeak(_data!.first);
    } catch (e) {
      _lastResponse = null; // 失败时重置
      // ...错误处理...
    }
  }

  // 新增：发送图片和文本到多模态API,prompt:"描述一下这幅图片"  imagepath  OK
  Future generateImageTextResponse({
    required String prompt,
    required String imagePath,
    required BuildContext context,
  }) async {
    try {
      if (_lastResponse == prompt) {
        return;
      }
      _lastResponse = prompt;

      final userData = await _openAI.generateImageText(prompt, imagePath);
      final response = ResponseModel.fromJson(userData);

      _data = response.choices.map((e) => e.message.content).toList();
      check = true;
      notifyListeners();

      // 可选：播放TTS
      final speechNotifier =
          Provider.of<SpeechNotifierSimplified>(context, listen: false);
      //print("@@@@@@@@@@@@@@@@@@@@@@@@@@@    speaking    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@");
      // await speechNotifier.safeSpeak(_data!.first);
    } catch (e) {
      _lastResponse = null; // 失败时重置
      // ...错误处理...
    }
  }
}
