import 'dart:async';
import 'dart:convert';
import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/services/camera_service.dart';
class _ComfortExtract {
  final EmotionType emotion;
  final String reply;
  _ComfortExtract(this.emotion, this.reply);
}

/// 情绪类型枚举
enum EmotionType {
  happy, // 高兴（正能量）
  sad, // 悲伤（负能量）
  surprise, // 惊讶
  angry, // 愤怒
  neutral, // 中性
  unknown, // 未知
}

/// 情绪识别模块
/// 处理用户情绪相关的交互，结合面部表情和语言内容进行情绪分析
class EmotionRecognitionModule {
  static final EmotionRecognitionModule _instance =
      EmotionRecognitionModule._internal();
  factory EmotionRecognitionModule() => _instance;
  EmotionRecognitionModule._internal();

  final OpenAI _openAI = OpenAI();
  CameraService? _cameraService;

  bool _isProcessing = false;

  /// 当前是否正在处理
  bool get isProcessing => _isProcessing;

  /// 处理情绪识别请求
  Future<EmotionRecognitionResult> processEmotionRecognition(String userInput,
      {String? conversationContext}) async {
    if (_isProcessing) {
      print("⏳ 情绪识别模块正在处理中，忽略新请求");
      return EmotionRecognitionResult(
        success: false,
        response: "系统正在处理中，请稍候",
        userInput: userInput,
        emotion: EmotionType.neutral,
      );
    }

    _isProcessing = true;
    print("😊 开始处理情绪识别: $userInput");

    try {
      // 首先从文本分析情绪倾向
      EmotionType textEmotion = _analyzeTextEmotion(userInput);
      print("📝 文本情绪分析结果: $textEmotion");

      // 表情在 ConversationController._speakText 与 TTS 对齐，此处不再提前切情绪脸

      // 初始化摄像头服务
      await _initializeCameraService();

      // 拍照获取用户表情
      String imagePath = await _captureImage();

      // 构建多模态分析提示词
      String prompt = _buildEmotionAnalysisPrompt(
          userInput, textEmotion, conversationContext);

      // 调用多模态大模型进行综合分析
      final response = await _openAI.generateImageText(prompt, imagePath);

      if (response['choices'] != null && response['choices'].isNotEmpty) {
        final rawModel =
            response['choices'][0]['message']['content'].toString();

        final extracted = _extractComfortReplyAndEmotion(rawModel, textEmotion);
        final EmotionType finalEmotion = extracted.emotion;
        final String replyForUser = extracted.reply;

        print("✅ 情绪识别成功 emotion=$finalEmotion TTS用短回复长度=${replyForUser.length}");
        return EmotionRecognitionResult(
          success: true,
          response: replyForUser,
          userInput: userInput,
          emotion: finalEmotion,
          textEmotion: textEmotion,
          imagePath: imagePath,
        );
      } else {
        throw Exception("多模态模型响应格式错误");
      }
    } catch (e) {
      print("❌ 情绪识别处理失败: $e");

      // 即使失败，表情仍在 TTS 阶段由对话控制器对齐

      EmotionType textEmotion = _analyzeTextEmotion(userInput);

      return EmotionRecognitionResult(
        success: false,
        response: "我能感受到您的情绪，让我来陪陪您吧。",
        userInput: userInput,
        emotion: textEmotion,
        textEmotion: textEmotion,
        error: e.toString(),
      );
    } finally {
      _isProcessing = false;
    }
  }

  /// 从文本分析情绪倾向
  EmotionType _analyzeTextEmotion(String text) {
    final lowerText = text.toLowerCase();

    // 高兴/正能量关键词
    final happyKeywords = [
      '开心',
      '高兴',
      '快乐',
      '兴奋',
      '激动',
      '满足',
      '幸福',
      '愉快',
      '爽',
      '棒',
      '好',
      '赞',
      '喜欢',
      '爱',
      '感谢',
      '谢谢',
      '成功',
      '胜利',
      '突破',
      '进步',
      '阳光',
      '灿烂',
      '明媚',
      '顺利',
      '美好',
      '精彩',
      '优秀',
      '出色',
      '完美',
      'happy',
      'good',
      'great',
      'awesome',
      'wonderful',
      'love',
      'like'
    ];

    // 悲伤/负能量关键词
    final sadKeywords = [
      '难过',
      '悲伤',
      '失落',
      '沮丧',
      '绝望',
      '孤独',
      '无助',
      '抑郁',
      '焦虑',
      '累',
      '疲惫',
      '无聊',
      '空虚',
      '冷漠',
      '麻木',
      '无望',
      '无奈',
      '自卑',
      '愧疚',
      '羞愧',
      '后悔',
      '遗憾',
      '痛苦',
      '苦闷',
      '忧郁',
      '忧伤',
      '哀伤',
      'sad',
      'down',
      'depressed',
      'lonely',
      'tired',
      'upset'
    ];

    // 愤怒关键词
    final angryKeywords = [
      '愤怒',
      '生气',
      '恼火',
      '暴躁',
      '狂怒',
      '烦',
      '郁闷',
      '气死了',
      '讨厌',
      '恶心',
      '烦人',
      '混蛋',
      '笨蛋',
      '白痴',
      '滚',
      '闭嘴',
      '该死',
      'angry',
      'mad',
      'furious',
      'annoyed',
      'hate',
      'stupid'
    ];

    // 惊讶关键词
    final surpriseKeywords = [
      '惊讶',
      '惊奇',
      '震惊',
      '吃惊',
      '意外',
      '没想到',
      '竟然',
      '居然',
      '真的吗',
      '不会吧',
      '天啊',
      '我的天',
      '哇',
      '太神奇了',
      'surprise',
      'wow',
      'amazing',
      'incredible',
      'unbelievable'
    ];

    // 检查情绪关键词
    for (String keyword in happyKeywords) {
      if (lowerText.contains(keyword)) {
        return EmotionType.happy;
      }
    }

    for (String keyword in angryKeywords) {
      if (lowerText.contains(keyword)) {
        return EmotionType.angry;
      }
    }

    for (String keyword in sadKeywords) {
      if (lowerText.contains(keyword)) {
        return EmotionType.sad;
      }
    }

    for (String keyword in surpriseKeywords) {
      if (lowerText.contains(keyword)) {
        return EmotionType.surprise;
      }
    }

    return EmotionType.neutral;
  }

  /// 初始化摄像头服务
  Future<void> _initializeCameraService() async {
    if (_cameraService == null) {
      _cameraService = CameraService();
      await _cameraService!.initialize();
      print("📷 情绪识别摄像头服务初始化完成");
    }
  }

  /// 拍照
  Future<String> _captureImage() async {
    if (_cameraService == null) {
      throw Exception("摄像头服务未初始化");
    }

    try {
      final imagePath = await _cameraService!.captureImage();
      print("📸 情绪识别拍照完成: $imagePath");
      return imagePath;
    } catch (e) {
      throw Exception("拍照失败: $e");
    }
  }

  /// 构建情绪分析提示词（分析只在模型内部完成，输出仅 JSON，避免 TTS 读出「从照片上看…」）
  String _buildEmotionAnalysisPrompt(
      String userInput, EmotionType textEmotion, String? conversationContext) {
    final buf = StringBuffer();

    buf.writeln('你是桌面陪伴精灵「小航」，正在做情绪陪伴。你会看到用户当前照片，并知道用户说的话。');
    buf.writeln('请在内心完成：结合面部表情与用户话语判断其情绪（高兴、悲伤、惊讶、愤怒、中性之一）。');
    buf.writeln('禁止在输出里写分析过程，禁止描述「从照片上看」「嘴角」「眼睛」「最终情绪判断」等字眼。');
    buf.writeln('');
    buf.writeln('用户说的话：$userInput');
    buf.writeln('参考文本情绪倾向：${_getEmotionDisplayName(textEmotion)}');
    if (conversationContext != null && conversationContext.isNotEmpty) {
      buf.writeln('对话上下文：$conversationContext');
    }
    buf.writeln('');
    buf.writeln('只输出一段合法 JSON，不要 Markdown 代码块，不要任何 JSON 以外的文字。格式：');
    buf.writeln(
        '{"emotion_label":"高兴|悲伤|惊讶|愤怒|中性之一","user_reply":"只给用户听的一句或两句中文，自然共情或安慰，口语化，不要分析、不要复述模型思考过程"}');

    return buf.toString();
  }

  /// 从模型输出取出 TTS 用语与情绪；解析失败时用文本情绪 + 简短兜底句
  _ComfortExtract _extractComfortReplyAndEmotion(
    String raw,
    EmotionType textEmotion,
  ) {
    final map = _tryParseLeadingJson(raw);
    if (map != null) {
      final label = map['emotion_label']?.toString();
      final reply = map['user_reply']?.toString().trim() ?? '';
      final emo = _emotionFromLabelString(label, textEmotion);
      if (reply.isNotEmpty && !_looksLikeAnalysisDump(reply)) {
        return _ComfortExtract(emo, reply);
      }
      if (reply.isNotEmpty) {
        final cleaned = _stripAnalysisPhrases(reply);
        if (cleaned.isNotEmpty) return _ComfortExtract(emo, cleaned);
      }
    }

    final stripped = _stripAnalysisPhrases(raw);
    if (stripped.isNotEmpty &&
        stripped.length < 120 &&
        !_looksLikeAnalysisDump(stripped)) {
      return _ComfortExtract(
          _parseEmotionFromResponse(raw, textEmotion), stripped);
    }

    return _ComfortExtract(textEmotion, _fallbackComfortLine(textEmotion));
  }

  Map<String, dynamic>? _tryParseLeadingJson(String text) {
    final t = text.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
    final m = fence.firstMatch(t);
    final candidate = (m != null ? m.group(1)! : t).trim();
    final start = candidate.indexOf('{');
    final end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final obj = jsonDecode(candidate.substring(start, end + 1));
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return Map<String, dynamic>.from(obj);
    } catch (_) {}
    return null;
  }

  EmotionType _emotionFromLabelString(String? label, EmotionType fallback) {
    if (label == null || label.isEmpty) return fallback;
    final s = label.toLowerCase();
    if (s.contains('高兴') ||
        s.contains('开心') ||
        s.contains('快乐') ||
        s.contains('happy')) {
      return EmotionType.happy;
    }
    if (s.contains('悲伤') ||
        s.contains('难过') ||
        s.contains('低落') ||
        s.contains('sad')) {
      return EmotionType.sad;
    }
    if (s.contains('愤怒') || s.contains('生气') || s.contains('angry')) {
      return EmotionType.angry;
    }
    if (s.contains('惊讶') || s.contains('吃惊') || s.contains('surprise')) {
      return EmotionType.surprise;
    }
    if (s.contains('中性') || s.contains('平静') || s.contains('neutral')) {
      return EmotionType.neutral;
    }
    return fallback;
  }

  bool _looksLikeAnalysisDump(String s) {
    const markers = [
      '从照片',
      '照片上看',
      '面部表情',
      '最终情绪判断',
      '结合他说',
      '嘴角',
      '上扬',
    ];
    return markers.any((k) => s.contains(k));
  }

  String _stripAnalysisPhrases(String s) {
    var t = s.trim();
    final cut = RegExp(r'最终情绪判断[^。]*。');
    t = t.replaceAll(cut, '');
    t = t.replaceAll(RegExp(r'从照片[^。]*。'), '');
    t = t.replaceAll(RegExp(r'结合[^。]*。'), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _fallbackComfortLine(EmotionType t) {
    switch (t) {
      case EmotionType.sad:
        return '我在这儿呢，慢慢说，我听着。';
      case EmotionType.angry:
        return '先深呼吸一下，我陪你待一会儿。';
      case EmotionType.happy:
        return '真好，我也替你开心。';
      case EmotionType.surprise:
        return '嗯，我在呢，你想聊聊吗？';
      case EmotionType.neutral:
      case EmotionType.unknown:
        return '我在呢，想说什么都可以。';
    }
  }

  /// 从AI回复中解析情绪结果
  EmotionType _parseEmotionFromResponse(
      String response, EmotionType textEmotion) {
    final lowerResponse = response.toLowerCase();

    // 查找情绪关键词
    if (lowerResponse.contains('高兴') ||
        lowerResponse.contains('开心') ||
        lowerResponse.contains('快乐') ||
        lowerResponse.contains('happy')) {
      return EmotionType.happy;
    } else if (lowerResponse.contains('悲伤') ||
        lowerResponse.contains('难过') ||
        lowerResponse.contains('失落') ||
        lowerResponse.contains('sad')) {
      return EmotionType.sad;
    } else if (lowerResponse.contains('愤怒') ||
        lowerResponse.contains('生气') ||
        lowerResponse.contains('angry')) {
      return EmotionType.angry;
    } else if (lowerResponse.contains('惊讶') ||
        lowerResponse.contains('吃惊') ||
        lowerResponse.contains('surprise')) {
      return EmotionType.surprise;
    } else if (lowerResponse.contains('中性') ||
        lowerResponse.contains('平静') ||
        lowerResponse.contains('neutral')) {
      return EmotionType.neutral;
    }

    // 如果无法从回复中识别，返回文本分析结果
    return textEmotion;
  }

  /// 与 [UIAnimationModule.handleEmotionAnimation] 入参一致，供 TTS 前对齐表情。
  static String emotionToUiLabel(EmotionType emotion) {
    switch (emotion) {
      case EmotionType.happy:
        return '高兴';
      case EmotionType.sad:
        return '悲伤';
      case EmotionType.surprise:
        return '惊讶';
      case EmotionType.angry:
        return '愤怒';
      case EmotionType.neutral:
      case EmotionType.unknown:
        return '中性';
    }
  }

  /// 获取情绪显示名称
  String _getEmotionDisplayName(EmotionType emotion) => emotionToUiLabel(emotion);

  /// 获取情绪对应的动画名称
  String _getEmotionAnimationName(EmotionType emotion) {
    switch (emotion) {
      case EmotionType.happy:
        return '正能量';
      case EmotionType.sad:
        return '负能量';
      case EmotionType.surprise:
        return '惊讶';
      case EmotionType.angry:
        return '愤怒';
      default:
        return '中性';
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    if (_cameraService != null) {
      await _cameraService!.dispose();
      _cameraService = null;
      print("📷 情绪识别模块摄像头资源已释放");
    }
  }
}

/// 情绪识别结果
class EmotionRecognitionResult {
  final bool success;
  final String response;
  final String userInput;
  final EmotionType emotion;
  final EmotionType? textEmotion;
  final String? imagePath;
  final String? error;
  final DateTime timestamp;

  EmotionRecognitionResult({
    required this.success,
    required this.response,
    required this.userInput,
    required this.emotion,
    this.textEmotion,
    this.imagePath,
    this.error,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    return 'EmotionRecognitionResult{success: $success, emotion: $emotion, userInput: "$userInput", response: "$response"${error != null ? ', error: "$error"' : ''}}';
  }
}
