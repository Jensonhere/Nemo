import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/llm/conversation_context_pack.dart';
import 'package:voicegpt/core/llm/llm_prompt_layers.dart';
import 'package:voicegpt/core/llm/structured_llm_reply.dart';
import 'package:voicegpt/core/modules/intent_recognition_module.dart';
import 'package:voicegpt/core/services/ambient_context_cache.dart';
import 'package:voicegpt/core/services/device_context_service.dart';

/// 纯文本问答模块结果
class TextQAResult {
  final String response;
  final bool success;
  final String? errorMessage;
  final StructuredLlmReply? structured;

  TextQAResult({
    required this.response,
    required this.success,
    this.errorMessage,
    this.structured,
  });
}

/// 纯文本问答模块：分层 Prompt + 结构化 JSON 解析
class TextQAModule {
  static final TextQAModule _instance = TextQAModule._internal();
  factory TextQAModule() => _instance;
  TextQAModule._internal();

  final OpenAI _openAI = OpenAI();

  /// Router 直出回复后写入主会话历史，避免后续轮次缺失上文。
  void recordRouterDirectTurn(String userUtterance, String assistantReply) {
    final u = userUtterance.trim();
    final a = assistantReply.trim();
    if (u.isEmpty || a.isEmpty) return;
    _openAI.addUserMessage(u);
    _openAI.addAssistantMessage(a);
  }

  /// [sceneIntent] 决定 B 场景模板；[contextPack] 为 C 层；[replyLengthMode] 行走/待机等
  /// [deviceContextMode] 默认 [DeviceContextFetchMode.none]，仅命中天气/位置等意图时再拉定位与天气
  Future<TextQAResult> handleTextQA(
    String userInput,
    List<String> conversationHistory, {
    IntentType sceneIntent = IntentType.dialogue,
    bool englishTeachingScene = false,
    ConversationContextPack? contextPack,
    String replyLengthMode = '待机',
    DeviceContextFetchMode deviceContextMode = DeviceContextFetchMode.none,
  }) async {
    try {
      final utterance = sceneIntent == IntentType.command
          ? StructuredLlmReplyParser.normalizeUserMotionForCommandLlm(userInput)
          : userInput;
      print(
        "💬 分层文本问答: $userInput scene=$sceneIntent deviceCtx=$deviceContextMode",
      );
      final totalSw = Stopwatch()..start();

      String? deviceBlock;
      final ctxSw = Stopwatch()..start();
      try {
        final svc = DeviceContextService();
        switch (deviceContextMode) {
          case DeviceContextFetchMode.full:
            deviceBlock = await svc.getContextBlock();
            break;
          case DeviceContextFetchMode.localTimeOnly:
            deviceBlock = svc.getLocalTimeContextBlock();
            break;
          case DeviceContextFetchMode.cachedAmbient:
            deviceBlock = AmbientContextCache.instance.buildPromptBlock();
            break;
          case DeviceContextFetchMode.none:
            break;
        }
      } catch (_) {}
      ctxSw.stop();

      String ctxLabel;
      switch (deviceContextMode) {
        case DeviceContextFetchMode.full:
          ctxLabel = '定位+天气';
          break;
        case DeviceContextFetchMode.localTimeOnly:
          ctxLabel = '仅本地时间';
          break;
        case DeviceContextFetchMode.cachedAmbient:
          ctxLabel = '缓存定位天气+本机时间';
          break;
        case DeviceContextFetchMode.none:
          ctxLabel = '无';
          break;
      }

      final pack = contextPack ??
          ConversationContextPack(deviceContextBlock: deviceBlock);
      final merged = ConversationContextPack(
        recentTurnLines: pack.recentTurnLines,
        userEmotionFromVa: pack.userEmotionFromVa,
        vaValuesSummary: pack.vaValuesSummary,
        vaTagsSummary: pack.vaTagsSummary,
        vaPromptHint: pack.vaPromptHint,
        deviceStateLine: pack.deviceStateLine,
        environmentSummary: pack.environmentSummary,
        deviceContextBlock: pack.deviceContextBlock ?? deviceBlock,
        idleSinceDescription: pack.idleSinceDescription,
      );

      final localSw = Stopwatch()..start();
      final contextBlock = merged.formatContextBlock();
      final fullSystem = LlmPromptLayers.composeFullSystem(
        intent: sceneIntent,
        contextBlock: contextBlock,
        replyLengthMode: replyLengthMode,
        englishTeachingScene: englishTeachingScene,
      );
      localSw.stop();

      final llmSw = Stopwatch()..start();
      final response = await _openAI.generateTextLayered(
        fullSystemContent: fullSystem,
        userUtterance: utterance,
        deferAssistantHistory: true,
      );
      llmSw.stop();

      String raw;
      if (response.containsKey('choices') &&
          response['choices'] is List &&
          (response['choices'] as List).isNotEmpty) {
        final choice = response['choices'][0];
        if (choice['message'] != null && choice['message']['content'] != null) {
          raw = choice['message']['content'].toString();
        } else {
          raw = choice['text']?.toString() ?? '';
        }
      } else {
        raw = response['content']?.toString() ??
            response['message']?.toString() ??
            response['text']?.toString() ??
            '';
      }

      final parseSw = Stopwatch()..start();
      final parsed = StructuredLlmReplyParser.parse(raw);
      parseSw.stop();

      var replyOut = parsed.replyText.trim();
      if (replyOut.isEmpty || _looksLikeUnparsedStructuredJson(replyOut)) {
        replyOut = '我没整理好话，你再说一遍？';
      }

      _openAI.addAssistantMessage(replyOut);

      totalSw.stop();
      print(
        '⏱️ [ConvStage][TextQA·整段] 设备上下文($ctxLabel)=${ctxSw.elapsedMilliseconds}ms '
        '拼prompt=${localSw.elapsedMilliseconds}ms '
        'LLM含HTTP=${llmSw.elapsedMilliseconds}ms '
        '解析JSON=${parseSw.elapsedMilliseconds}ms '
        '合计=${totalSw.elapsedMilliseconds}ms',
      );
      print("✅ 文本问答成功: $replyOut");
      return TextQAResult(
        response: replyOut,
        success: true,
        structured: parsed,
      );
    } catch (e) {
      print("❌ 纯文本问答失败: $e");
      return TextQAResult(
        response: "抱歉，处理您的问题时出现了错误。",
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  /// 流式文本问答：边接收 LLM token，边通过 [onDelta] 回传给上层做流式 TTS。
  Future<TextQAResult> handleTextQAStream(
    String userInput,
    List<String> conversationHistory, {
    required Future<void> Function(String delta) onDelta,
    IntentType sceneIntent = IntentType.dialogue,
    bool englishTeachingScene = false,
    ConversationContextPack? contextPack,
    String replyLengthMode = '待机',
    DeviceContextFetchMode deviceContextMode = DeviceContextFetchMode.none,
  }) async {
    try {
      final utterance = sceneIntent == IntentType.command
          ? StructuredLlmReplyParser.normalizeUserMotionForCommandLlm(userInput)
          : userInput;
      final totalSw = Stopwatch()..start();

      String? deviceBlock;
      final ctxSw = Stopwatch()..start();
      try {
        final svc = DeviceContextService();
        switch (deviceContextMode) {
          case DeviceContextFetchMode.full:
            deviceBlock = await svc.getContextBlock();
            break;
          case DeviceContextFetchMode.localTimeOnly:
            deviceBlock = svc.getLocalTimeContextBlock();
            break;
          case DeviceContextFetchMode.cachedAmbient:
            deviceBlock = AmbientContextCache.instance.buildPromptBlock();
            break;
          case DeviceContextFetchMode.none:
            break;
        }
      } catch (_) {}
      ctxSw.stop();

      String ctxLabel;
      switch (deviceContextMode) {
        case DeviceContextFetchMode.full:
          ctxLabel = '定位+天气';
          break;
        case DeviceContextFetchMode.localTimeOnly:
          ctxLabel = '仅本地时间';
          break;
        case DeviceContextFetchMode.cachedAmbient:
          ctxLabel = '缓存定位天气+本机时间';
          break;
        case DeviceContextFetchMode.none:
          ctxLabel = '无';
          break;
      }

      final pack = contextPack ??
          ConversationContextPack(deviceContextBlock: deviceBlock);
      final merged = ConversationContextPack(
        recentTurnLines: pack.recentTurnLines,
        userEmotionFromVa: pack.userEmotionFromVa,
        vaValuesSummary: pack.vaValuesSummary,
        vaTagsSummary: pack.vaTagsSummary,
        vaPromptHint: pack.vaPromptHint,
        deviceStateLine: pack.deviceStateLine,
        environmentSummary: pack.environmentSummary,
        deviceContextBlock: pack.deviceContextBlock ?? deviceBlock,
        idleSinceDescription: pack.idleSinceDescription,
      );

      final promptSw = Stopwatch()..start();
      final fullSystem = LlmPromptLayers.composeFullSystem(
        intent: sceneIntent,
        contextBlock: merged.formatContextBlock(),
        replyLengthMode: replyLengthMode,
        englishTeachingScene: englishTeachingScene,
      );
      promptSw.stop();

      final raw = StringBuffer();
      final loopSw = Stopwatch()..start();
      int? firstDeltaLoopMs;
      var sumOnDeltaMs = 0;
      var deltaEvents = 0;
      await for (final delta in _openAI.generateTextLayeredStream(
        fullSystemContent: fullSystem,
        userUtterance: utterance,
      )) {
        firstDeltaLoopMs ??= loopSw.elapsedMilliseconds;
        deltaEvents++;
        raw.write(delta);
        final od = Stopwatch()..start();
        await onDelta(delta);
        od.stop();
        sumOnDeltaMs += od.elapsedMilliseconds;
      }
      loopSw.stop();

      final parseSw = Stopwatch()..start();
      final parsed = StructuredLlmReplyParser.parse(raw.toString());
      parseSw.stop();
      var replyOut = parsed.replyText.trim();
      if (replyOut.isEmpty || _looksLikeUnparsedStructuredJson(replyOut)) {
        replyOut = '我没整理好话，你再说一遍？';
      }
      _openAI.addAssistantMessage(replyOut);
      totalSw.stop();
      var idleInLoopMs = loopSw.elapsedMilliseconds - sumOnDeltaMs;
      if (idleInLoopMs < 0) idleInLoopMs = 0;
      print(
        '⏱️ [ConvStage][TextQA·流式] 设备上下文($ctxLabel)=${ctxSw.elapsedMilliseconds}ms '
        '拼prompt=${promptSw.elapsedMilliseconds}ms '
        'await_for墙钟=${loopSw.elapsedMilliseconds}ms '
        '其中首增量距循环起点=${firstDeltaLoopMs ?? -1}ms '
        '累计await_onDelta=${sumOnDeltaMs}ms（TTS入队/切句等） '
        '推算循环内非回调≈${idleInLoopMs}ms（多为等下一 token） '
        'delta事件=$deltaEvents 解析=${parseSw.elapsedMilliseconds}ms '
        '本模块合计=${totalSw.elapsedMilliseconds}ms',
      );
      return TextQAResult(
        response: replyOut,
        success: true,
        structured: parsed,
      );
    } catch (e) {
      return TextQAResult(
        response: "抱歉，处理您的问题时出现了错误。",
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  /// 仅当整段仍像未解析的 JSON 模板时才兜底（合法英文/中文回复不过滤）
  static bool _looksLikeUnparsedStructuredJson(String s) {
    final t = s.trimLeft();
    if (!t.startsWith('{')) return false;
    return t.contains('"reply_text"') ||
        t.contains("'reply_text'") ||
        t.contains('"emotion_tag"') ||
        t.contains('"bluetooth_actions"');
  }
}
