import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:voicegpt/app/constants/app.keys.dart';
import 'package:voicegpt/app/routes/api.routes.dart';
import 'package:voicegpt/core/llm/llm_prompt_layers.dart';

class OpenAI {
  final client = http.Client();

  // 存储对话历史
  List<Map<String, dynamic>> _conversationHistory = [];

  /// 默认人格（文本/多模态 system 基底）；结构化对话另见 [generateTextLayered]
  static const String _xiaohangPersona = LlmPromptLayers.systemLayer;

  /// 公网网关对 HTTPS body 限制较严，视觉请求单独收紧体积。
  static const int _visionImageMaxWidth = 640;
  static const int _visionImageMinWidth = 384;
  static const int _visionImageTargetBytes = 95 * 1024;
  static const int _visionPromptMaxChars = 6000;
  static const int _visionHistoryTextTurns = 4;
  static const int _visionBatchMaxImages = 3;
  /// system 人格全文可能很长，视觉请求单独截断以减小 JSON。
  static const int _visionSystemMaxChars = 3800;

  // 重置对话历史
  void resetConversation() {
    _conversationHistory.clear();
    print("🔄 对话历史已重置");
  }

  // 添加用户消息到历史（简化版）
  void addUserMessage(dynamic content) {
    _conversationHistory.add({"role": "user", "content": content});
    print("👤 添加用户消息");
  }

  // 添加助手回复到历史
  void addAssistantMessage(String message) {
    _conversationHistory.add({"role": "assistant", "content": message});
    print("🤖 添加助手回复: $message");
  }


  String _truncateVisionUserPrompt(String prompt) {
    final t = prompt.trim();
    if (t.length <= _visionPromptMaxChars) return t;
    return '${t.substring(0, _visionPromptMaxChars)}…';
  }

  /// 强压缩 JPEG 再 base64，降低公网 413 概率。
  Future<String> _imageToBase64(String imagePath) async {
    final originalBytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) {
      return base64Encode(originalBytes);
    }

    var maxW = _visionImageMaxWidth;
    late Uint8List encoded;

    while (maxW >= _visionImageMinWidth) {
      img.Image working = decoded;
      if (working.width > maxW) {
        working = img.copyResize(working, width: maxW);
      }
      var quality = 68;
      encoded = img.encodeJpg(working, quality: quality);
      while (encoded.length > _visionImageTargetBytes && quality > 38) {
        quality -= 6;
        encoded = img.encodeJpg(working, quality: quality);
      }
      if (encoded.length <= _visionImageTargetBytes) break;
      maxW -= 96;
    }

    if (encoded.isEmpty) {
      return base64Encode(originalBytes);
    }

    final ratio = originalBytes.isEmpty
        ? 1.0
        : (originalBytes.length / encoded.length);
    print(
      '🗜️ [VISION_IMG] $imagePath 原=${(originalBytes.length / 1024).toStringAsFixed(1)}KB '
      '出=${(encoded.length / 1024).toStringAsFixed(1)}KB maxW=$maxW '
      '缩小=${ratio.toStringAsFixed(2)}x',
    );
    return base64Encode(encoded);
  }

  List<Map<String, dynamic>> _recentTextOnlyHistoryForVision() {
    final textOnly = _conversationHistory
        .where((m) => m['content'] is String)
        .cast<Map<String, dynamic>>()
        .toList();
    if (textOnly.length <= _visionHistoryTextTurns) return textOnly;
    return textOnly.sublist(textOnly.length - _visionHistoryTextTurns);
  }

  String _visionSystemText() {
    final s = _xiaohangPersona;
    if (s.length <= _visionSystemMaxChars) return s;
    return '${s.substring(0, _visionSystemMaxChars)}…';
  }

  List<Map<String, dynamic>> _buildVisionRequestMessages(
    List<Map<String, dynamic>> currentUserContent,
  ) {
    return [
      {
        'role': 'system',
        'content': [
          {'type': 'text', 'text': _visionSystemText()},
        ],
      },
      ..._recentTextOnlyHistoryForVision().map((msg) {
        return {
          'role': msg['role'],
          'content': [
            {'type': 'text', 'text': msg['content'].toString()},
          ],
        };
      }),
      {'role': 'user', 'content': currentUserContent},
    ];
  }

  // 纯文本生成方法
  // [deviceContext] 可选：当前时间、位置、天气等，用于回答「我在哪」「现在几点」「今天天气」等
  Future<Map<String, dynamic>> generateText(String prompt, {String? deviceContext}) async {
    // 添加用户消息到历史
    addUserMessage(prompt);

    // 构建完整的消息列表（纯文本格式），注入设备上下文
    final messages = _buildTextMessages(deviceContext: deviceContext);

    // 发送到文本API
    return _sendTextRequest(messages);
  }

  /// 分层 Prompt：自定义完整 system + 仅用户原话入历史。
  /// [deferAssistantHistory] 为 true 时不自动写入助手消息（便于先解析 JSON 再只写入 reply_text）
  Future<Map<String, dynamic>> generateTextLayered({
    required String fullSystemContent,
    required String userUtterance,
    String? assistantContentForHistory,
    bool deferAssistantHistory = false,
  }) async {
    addUserMessage(userUtterance);
    final messages = _buildLayeredTextMessages(fullSystemContent);
    return _sendTextRequest(
      messages,
      assistantContentForHistory: assistantContentForHistory,
      skipAssistantHistory: deferAssistantHistory,
    );
  }

  /// 仅 system + user，**不**拼接 [_conversationHistory]、不写回助手。
  /// 供 Planner 等「无状态结构化输出」使用。
  Future<Map<String, dynamic>> generateTextEphemeralNoHistory({
    required String systemContent,
    required String userUtterance,
  }) async {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemContent},
      {'role': 'user', 'content': userUtterance},
    ];
    return _sendTextRequest(messages, skipAssistantHistory: true);
  }

  /// 分层请求但**不**把本条 user 追加进 [_conversationHistory]（也不写入助手）。
  /// 供 Router 等「先判型再入主对话」使用，避免污染主会话与重复 user。
  Future<Map<String, dynamic>> generateTextLayeredEphemeral({
    required String fullSystemContent,
    required String userUtterance,
  }) async {
    final messages = <Map<String, dynamic>>[
      {"role": "system", "content": fullSystemContent},
      ..._conversationHistory.map((msg) {
        final content = msg["content"];
        return {
          "role": msg["role"],
          "content":
              content is String ? content : _extractTextFromContent(content),
        };
      }),
      {"role": "user", "content": userUtterance},
    ];
    return _sendTextRequest(messages, skipAssistantHistory: true);
  }

  /// 分层 Prompt + SSE 增量输出（OpenAI-compatible stream=true）。
  Stream<String> generateTextLayeredStream({
    required String fullSystemContent,
    required String userUtterance,
  }) async* {
    addUserMessage(userUtterance);
    final messages = _buildLayeredTextMessages(fullSystemContent);
    final req = http.Request('POST', Uri.parse(ApiRoutes.textApiUrl))
      ..headers.addAll({
        "Authorization": "Bearer ${AppKeys.apiKey}",
        "Content-Type": "application/json",
      })
      ..body = jsonEncode({
        "model": "Qwen/Qwen2.5-72B-Instruct-W8A8",
        "messages": messages,
        "stream": true,
      });
    final sendSw = Stopwatch()..start();
    final resp = await client.send(req);
    sendSw.stop();
    print(
      '⏱️ [ConvStage][LLM·HTTP] send→响应头 ${sendSw.elapsedMilliseconds}ms '
      'status=${resp.statusCode}',
    );
    if (resp.statusCode != 200) {
      final body = await resp.stream.bytesToString();
      throw Exception("流式文本请求失败: ${resp.statusCode} - $body");
    }
    final sseSw = Stopwatch()..start();
    int? firstDeltaMs;
    var deltaCount = 0;
    var charSum = 0;
    await for (final line in resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final l = line.trim();
      if (!l.startsWith('data:')) continue;
      final payload = l.substring(5).trim();
      if (payload == '[DONE]') break;
      if (payload.isEmpty) continue;
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final c0 = choices.first as Map<String, dynamic>;
        String delta = '';
        final d = c0['delta'];
        if (d is Map && d['content'] != null) {
          delta = d['content'].toString();
        } else if (c0['message'] is Map &&
            c0['message']['content'] != null) {
          delta = c0['message']['content'].toString();
        }
        if (delta.isNotEmpty) {
          firstDeltaMs ??= sseSw.elapsedMilliseconds;
          deltaCount++;
          charSum += delta.length;
          yield delta;
        }
      } catch (_) {
        continue;
      }
    }
    sseSw.stop();
    print(
      '⏱️ [ConvStage][LLM·SSE] 首包文本距流读取起点=${firstDeltaMs ?? -1}ms '
      '增量次数=$deltaCount 字符=$charSum '
      '流读取墙钟=${sseSw.elapsedMilliseconds}ms（含下游 await 拉取停顿）',
    );
  }

  List<Map<String, dynamic>> _buildLayeredTextMessages(String fullSystemContent) {
    return [
      {"role": "system", "content": fullSystemContent},
      ..._conversationHistory.map((msg) {
        final content = msg["content"];
        return {
          "role": msg["role"],
          "content":
              content is String ? content : _extractTextFromContent(content)
        };
      })
    ];
  }

  // 纯文本生成方法（无状态，不写入会话历史）
  Future<Map<String, dynamic>> generateTextStateless(String prompt) async {
    final messages = [
      {"role": "system", "content": _xiaohangPersona},
      {"role": "user", "content": prompt},
    ];
    return _sendTextRequest(messages);
  }

  // 图像+文本生成方法
  Future<Map<String, dynamic>> generateImageText(
      String prompt, String imagePath) async {
    final promptForApi = _truncateVisionUserPrompt(prompt);
    final imageBase64 = await _imageToBase64(imagePath);

    final content = [
      {"type": "text", "text": promptForApi},
      {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,$imageBase64"}
      }
    ];

    final messages = _buildVisionRequestMessages(content);
    final result = await _sendVisionRequest(
      messages,
      recordAssistantToHistory: false,
    );
    final assistantRaw = result['choices']?[0]?['message']?['content'];
    final assistantMessage = assistantRaw?.toString() ?? '';
    final histUser =
        '[附图] ${promptForApi.length > 400 ? '${promptForApi.substring(0, 400)}…' : promptForApi}';
    addUserMessage(histUser);
    if (assistantMessage.isNotEmpty) {
      addAssistantMessage(assistantMessage);
    }
    return result;
  }

  // 多图+文本生成方法（单次请求联合分析）
  Future<Map<String, dynamic>> generateImageTextBatch(
      String prompt, List<String> imagePaths) async {
    if (imagePaths.isEmpty) {
      throw Exception('imagePaths 不能为空');
    }

    final promptForApi = _truncateVisionUserPrompt(prompt);
    final selectedPaths = imagePaths.length > _visionBatchMaxImages
        ? imagePaths.sublist(imagePaths.length - _visionBatchMaxImages)
        : imagePaths;
    if (selectedPaths.length != imagePaths.length) {
      print(
        '⚠️ [VISION_BATCH] 共 ${imagePaths.length} 张，仅发送最近 ${selectedPaths.length} 张以控制体积',
      );
    }

    final content = <Map<String, dynamic>>[
      {"type": "text", "text": promptForApi},
    ];
    for (final path in selectedPaths) {
      final imageBase64 = await _imageToBase64(path);
      content.add({
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,$imageBase64"}
      });
    }

    final messages = _buildVisionRequestMessages(content);
    final result = await _sendVisionRequest(
      messages,
      recordAssistantToHistory: false,
    );
    final assistantRaw = result['choices']?[0]?['message']?['content'];
    final assistantMessage = assistantRaw?.toString() ?? '';
    addUserMessage(
      '[多图附图×${selectedPaths.length}] '
      '${promptForApi.length > 280 ? '${promptForApi.substring(0, 280)}…' : promptForApi}',
    );
    if (assistantMessage.isNotEmpty) {
      addAssistantMessage(assistantMessage);
    }
    return result;
  }

  // 构建纯文本消息（优化版）
  // [deviceContext] 可选：当前时间、位置、天气等，拼在 system 末尾供模型参考
  List<Map<String, dynamic>> _buildTextMessages({String? deviceContext}) {
    String systemContent = _xiaohangPersona;
    if (deviceContext != null && deviceContext.isNotEmpty) {
      systemContent = '$systemContent\n\n$deviceContext';
    }
    return [
      {"role": "system", "content": systemContent},
      ..._conversationHistory.map((msg) {
        final content = msg["content"];
        return {
          "role": msg["role"],
          "content":
              content is String ? content : _extractTextFromContent(content)
        };
      })
    ];
  }

  // 从多模态内容中提取文本
  String _extractTextFromContent(dynamic content) {
    if (content is List) {
      return content
          .where((item) => item["type"] == "text")
          .map((item) => item["text"] as String)
          .join(" ");
    }
    return content.toString();
  }

  // 发送文本请求
  Future<Map<String, dynamic>> _sendTextRequest(
    List<Map<String, dynamic>> messages, {
    String? assistantContentForHistory,
    bool skipAssistantHistory = false,
  }) async {
    // 截断历史记录（保留最近的10轮对话）
    if (messages.length > 11) {
      messages = [messages[0], ...messages.sublist(messages.length - 10)];
    }

    final bodyStr = jsonEncode({
      "model": "Qwen/Qwen2.5-72B-Instruct-W8A8",
      "messages": messages,
    });
    final bodyBytes = utf8.encode(bodyStr).length;

    final httpSw = Stopwatch()..start();
    final response = await client.post(
      Uri.parse(ApiRoutes.textApiUrl),
      headers: {
        "Authorization": "Bearer ${AppKeys.apiKey}",
        "Content-Type": "application/json",
      },
      body: bodyStr,
    );
    httpSw.stop();

    print(
      '⏱️ [Pipeline][LLM文本API] HTTP ${httpSw.elapsedMilliseconds}ms '
      'status=${response.statusCode} body≈${(bodyBytes / 1024).toStringAsFixed(1)}KB '
      'messages=${messages.length}',
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      final assistantMessage = responseData['choices'][0]['message']['content'];

      if (!skipAssistantHistory) {
        addAssistantMessage(
          (assistantContentForHistory != null &&
                  assistantContentForHistory.isNotEmpty)
              ? assistantContentForHistory
              : assistantMessage,
        );
      }

      return responseData;
    } else {
      throw Exception("文本请求失败: ${response.statusCode} - ${response.body}");
    }
  }

  // 发送视觉请求
  Future<Map<String, dynamic>> _sendVisionRequest(
    List<Map<String, dynamic>> messages, {
    bool recordAssistantToHistory = true,
  }) async {
    // 截断消息条数（system + 若干 user/assistant + 当前多模态 user）
    if (messages.length > 11) {
      messages = [messages[0], ...messages.sublist(messages.length - 10)];
    }

    final visionBody = jsonEncode({
      "model": "xhang_lmm_qwen2.5-vl-72b",
      "messages": messages,
      "max_tokens": 1000,
    });
    final visionBytes = utf8.encode(visionBody).length;

    final visionSw = Stopwatch()..start();
    print('════════════════ VISION API CALL ═════════════════');
    print('🌐 [VISION_API_URL] ${ApiRoutes.visionApiUrl}');
    final response = await client.post(
      Uri.parse(ApiRoutes.visionApiUrl),
      headers: {
        "Authorization": "Bearer ${AppKeys.apiKey2}",
        "Content-Type": "application/json",
      },
      body: visionBody,
    );
    visionSw.stop();

    print(
      '⏱️ [Pipeline][LLM视觉API] HTTP ${visionSw.elapsedMilliseconds}ms '
      'status=${response.statusCode} body≈${(visionBytes / 1024).toStringAsFixed(1)}KB',
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      final assistantMessage = responseData['choices'][0]['message']['content'];
      final preview = assistantMessage.toString().replaceAll('\n', ' ');
      final shortPreview =
          preview.length > 80 ? '${preview.substring(0, 80)}…' : preview;
      print('✅ [VISION_API] 调用成功 status=200 preview="$shortPreview"');
      print('════════════════════════════════════════════════════');

      if (recordAssistantToHistory && assistantMessage.toString().isNotEmpty) {
        addAssistantMessage(assistantMessage.toString());
      }

      return responseData;
    } else {
      print(
        '❌ [VISION_API] 调用失败 status=${response.statusCode} '
        'url=${ApiRoutes.visionApiUrl} body=${utf8.decode(response.bodyBytes, allowMalformed: true)}',
      );
      print('════════════════════════════════════════════════════');
      throw Exception("视觉请求失败: ${response.statusCode} - ${response.body}");
    }
  }
}
