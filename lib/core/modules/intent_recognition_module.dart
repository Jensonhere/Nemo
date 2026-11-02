import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:voicegpt/core/utils/bert_tokenizer.dart';

/// 意图类型枚举（与 assets/labels.json / 新 BERT 六类标签语义对齐；索引顺序以运行时 [_labels] 为准）
enum IntentType {
  command, // 动作指令
  dialogue, // 普通对话
  idle, // 空闲 / 敷衍 / 意图不清
  comfort, // 情绪安抚与陪伴（原 comfort 类）
  apiCall, // 外部信息、设备事实、需上下文或 API 的查询
  image, // 图片 / 视觉分析
  unknown, // 解析失败或标签未识别
}

/// 意图识别模块
/// 六类意图：可仅关键词匹配，也可启用 tf_bert（将下方开关改为 false）
class IntentRecognitionModule {
  static final IntentRecognitionModule _instance =
      IntentRecognitionModule._internal();
  factory IntentRecognitionModule() => _instance;
  IntentRecognitionModule._internal();

  /// 为 true：不加载、不调用 BERT，六类意图全部由 [_classifyByKeywords] 决定。
  static const bool _keywordOnlyMode = true;

  Interpreter? _interpreter;
  BertTokenizer? _tokenizer;
  late List<String> _labels;
  bool _initialized = false;
  bool _useDeepLearningModel = false;

  /// 与 `tf_bert` 导出的 TFLite 一致（max_seq_length = 128）
  final int maxLen = 128;

  /// 初始化：加载模型、labels 和 tokenizer
  Future<void> initialize() async {
    if (_initialized) return;

    print("🧠 初始化意图识别模块...");

    try {
      if (_keywordOnlyMode) {
        _labels = await _loadLabelsOrDefault();
        _interpreter = null;
        _tokenizer = null;
        _useDeepLearningModel = false;
        _initialized = true;
        print("🔤 意图识别：仅关键词模式（BERT 已关闭，改回 BERT 请将 _keywordOnlyMode 设为 false）");
        print("🎉 意图识别模块初始化完成 (模式: 关键词匹配)");
        return;
      }

      // 1. 尝试加载 TFLite 模型
      try {
        try {
          _interpreter =
              await Interpreter.fromAsset("tf_bert/intent_model.tflite");
        } catch (_) {
          _interpreter = await Interpreter.fromAsset("intent_model.tflite");
        }
        print("✅ TFLite 模型加载成功");
      } catch (e) {
        print("⚠️ TFLite 模型文件不存在，将使用关键词匹配: $e");
        _interpreter = null;
      }

      _labels = await _loadLabelsOrDefault();

      // 3. 尝试加载 BERT tokenizer（新词表：tf_bert/vocab.txt）
      try {
        final vocab = await rootBundle.loadString('tf_bert/vocab.txt');
        _tokenizer = BertTokenizer.fromVocabulary(vocab);
        _useDeepLearningModel = _interpreter != null;
        print("✅ BERT tokenizer 初始化成功");
      } catch (e) {
        print("⚠️ BERT tokenizer 初始化失败，使用关键词匹配: $e");
        _tokenizer = null;
        _useDeepLearningModel = false;
      }

      _initialized = true;
      print(
          "🎉 意图识别模块初始化完成 (模式: ${_useDeepLearningModel ? 'BERT深度学习' : '关键词匹配'})");
    } catch (e) {
      print("⚠️ 意图识别模块部分功能不可用，使用基础模式: $e");
      _initialized = true;
      _useDeepLearningModel = false;
      _labels = _defaultLabels();
      print("✅ 降级为基础关键词匹配模式");
    }
  }

  static List<String> _defaultLabels() => [
        'command',
        'dialogue',
        'idle',
        'comfort',
        'api_call',
        'image',
      ];

  Future<List<String>> _loadLabelsOrDefault() async {
    try {
      String labelsJson;
      try {
        labelsJson = await rootBundle.loadString("tf_bert/labels.json");
      } catch (_) {
        labelsJson = await rootBundle.loadString("assets/labels.json");
      }
      final labelsData = json.decode(labelsJson);
      if (labelsData is List) {
        final list = List<String>.from(labelsData);
        print("✅ 意图标签加载成功: $list");
        return list;
      }
      if (labelsData is Map) {
        final list = List<String>.generate(
          labelsData.length,
          (i) => labelsData["$i"]?.toString() ?? "unknown",
        );
        print("✅ 意图标签加载成功: $list");
        return list;
      }
      throw Exception("labels.json 格式错误");
    } catch (e) {
      print("⚠️ 标签文件不存在，使用默认标签: $e");
      return _defaultLabels();
    }
  }

  /// 预测用户输入的意图
  Future<IntentResult> predictIntent(String text) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      print("🧠 开始意图识别，输入文本: '$text'");

      // 预处理文本：处理空格、同音字等
      String processedText = _preprocessText(text);
      print("🔄 文本预处理结果: '$processedText'");

      IntentType intentType;
      double confidence;
      List<double> allProbabilities;

      if (!_keywordOnlyMode &&
          _useDeepLearningModel &&
          _interpreter != null &&
          _tokenizer != null) {
        final modelResult = await _predictWithBertModel(processedText);
        intentType = modelResult['intent'] as IntentType;
        confidence = modelResult['confidence'] as double;
        allProbabilities =
            List<double>.from(modelResult['probabilities'] as List<double>);
        final src = modelResult['source'] as String? ?? 'bert';
        if (src == 'keyword_fallback') {
          print(
            '🔤 意图来源：关键词兜底（BERT 推理失败时仅此一条有效分类，不是「第二次识别」）',
          );
        } else {
          final lab = modelResult['label'] as String? ?? '';
          print('🤖 意图来源：BERT 模型（label=$lab）');
        }
      } else {
        // 降级到关键词匹配
        intentType = _classifyByKeywords(processedText);
        confidence = 0.7;
        allProbabilities = [confidence];
        print("🔤 使用关键词匹配识别");
      }

      final result = IntentResult(
        intent: intentType,
        confidence: confidence,
        originalText: text,
        processedText: processedText,
        allProbabilities: allProbabilities,
      );

      print(
          "🎯 意图识别结果: ${result.intent}, 置信度: ${(result.confidence * 100).toStringAsFixed(1)}%");
      return result;
    } catch (e) {
      print("❌ 意图识别失败: $e");
      return IntentResult(
        intent: IntentType.unknown,
        confidence: 0.0,
        originalText: text,
        processedText: text,
        allProbabilities: [],
      );
    }
  }

  /// 文本预处理：处理空格、同音字、常见输入错误等
  String _preprocessText(String text) {
    // 移除多余空格
    text = text.trim().replaceAll(RegExp(r'\s+'), ' ');

    // 同音字替换映射
    final Map<String, String> homophones = {
      '前近': '前进',
      '钱进': '前进',
      '浅进': '前进',
      '后腿': '后退',
      '厚退': '后退',
      '左传': '左转',
      '坐转': '左转',
      '右传': '右转',
      '有转': '右转',
      '脑带': '脑袋',
      '老大': '脑袋',
      '看看': '看一看',
      '康康': '看看',
      '分西': '分析',
      '风系': '分析',
      '开心': '高兴',
      '快乐': '高兴',
      '难过': '悲伤',
      '伤心': '悲伤',
      '惊讶': '惊奇',
      '愤怒': '生气',
      '火大': '愤怒',
    };

    // 应用同音字替换
    for (final entry in homophones.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }

    return text;
  }

  /// 使用 BERT 模型预测意图
  Future<Map<String, dynamic>> _predictWithBertModel(String text) async {
    try {
      // ---------- 编码 ----------
      final tok = _tokenizer;
      if (tok == null) {
        throw StateError('BERT tokenizer 未初始化');
      }
      final tokenResult = tok.tokenize(text, maxLen: maxLen);

      // 准备模型输入
      final inputIds = [tokenResult.inputIds];
      final attentionMask = [tokenResult.attentionMask];

      // ---------- 运行模型推理 ----------
      final output =
          List.filled(_labels.length, 0.0).reshape([1, _labels.length]);

      // 输入顺序：attention_mask, input_ids（根据模型训练时的顺序）
      _interpreter!
          .runForMultipleInputs([attentionMask, inputIds], {0: output});

      // ---------- 处理输出 ----------
      final probs = output[0].cast<double>();

      // 应用 softmax
      final softmaxProbs = _softmax(probs);

      final maxIdx = softmaxProbs
          .indexWhere((p) => p == softmaxProbs.reduce((a, b) => a > b ? a : b));

      final maxProb = softmaxProbs[maxIdx];
      final labelString = _labels[maxIdx];

      // 转换标签到意图类型
      IntentType intentType = _labelToIntentType(labelString);

      print(
          "🧠 BERT模型输出: 标签='$labelString', 置信度=${(maxProb * 100).toStringAsFixed(1)}%");
      print(
          "📊 所有概率: ${softmaxProbs.map((p) => (p * 100).toStringAsFixed(1) + '%').join(', ')}");

      return {
        'intent': intentType,
        'confidence': maxProb,
        'probabilities': softmaxProbs,
        'label': labelString,
        'source': 'bert',
      };
    } catch (e) {
      print("❌ BERT模型推理失败: $e");
      // 降级到关键词匹配（唯一对外结果；置信度略高于阈值以免被误判为「低置信度改走闲聊」）
      return {
        'intent': _classifyByKeywords(text),
        'confidence': 0.72,
        'probabilities': List<double>.filled(_labels.length, 1.0 / _labels.length),
        'label': 'fallback',
        'source': 'keyword_fallback',
      };
    }
  }

  /// Softmax 函数
  List<double> _softmax(List<double> logits) {
    final maxLogit = logits.reduce((a, b) => a > b ? a : b);
    final expValues = logits.map((x) => math.exp(x - maxLogit)).toList();
    final sumExp = expValues.reduce((a, b) => a + b);
    return expValues.map((x) => x / sumExp).toList();
  }

  /// 将模型标签转换为意图类型（含旧版标签兼容）
  IntentType _labelToIntentType(String label) {
    switch (label.toLowerCase()) {
      case 'command':
        return IntentType.command;
      case 'dialogue':
        return IntentType.dialogue;
      case 'idle':
        return IntentType.idle;
      case 'comfort':
        return IntentType.comfort;
      case 'api_call':
      case 'apicall':
        return IntentType.apiCall;
      case 'image':
        return IntentType.image;
      case 'emotion':
        return IntentType.comfort;
      case 'external_api':
      case 'externalapi':
        return IntentType.apiCall;
      case 'idle_unknown':
      case 'idleunknown':
        return IntentType.idle;
      default:
        return IntentType.unknown;
    }
  }

  /// 基于关键词的意图分类（备用方案）
  IntentType _classifyByKeywords(String text) {
    final lowerText = text.toLowerCase().replaceAll(' ', ''); // 移除空格影响匹配

    print("🔍 关键词匹配：处理文本 '$text' -> '$lowerText'");

    // 图片分析关键词 - 提高优先级，放在最前面
    final imageKeywords = [
      '周围环境',
      '环境怎么样',
      '看看周围',
      '看看前面',
      '看看这是什么',
      '这是什么',
      '看看',
      '分析',
      '图片',
      '照片',
      '场景',
      '帮我看',
      '看一下',
      '识别',
      '看看这个',
      '这个是什么',
      '拍照',
      '摄像',
      '视觉',
      '观察',
      '检查',
      '查看'
    ];
    for (String keyword in imageKeywords) {
      if (lowerText.contains(keyword.replaceAll(' ', ''))) {
        print("🎯 匹配到图片分析关键词: $keyword");
        return IntentType.image;
      }
    }

    // 动作指令关键词
    final commandKeywords = [
      '前进',
      '向前进',
      '继续前进',
      '继续向前进',
      '持续前进',
      '一直向前',
      '往前走',
      '向前走',
      '后退',
      '左转',
      '右转',
      '往前一点',
      '往后一点',
      '往前',
      '往后',
      '旋转',
      '旋转一周',
      '旋转一圈',
      '转一圈', // 含「转一圈儿」子串
      '转个圈',
      '向我靠近',
      '朝我靠近',
      '靠近我',
      '凑近点',
      '向后转',
      '脑袋角度',
      '抬头',
      '低头',
      '转圈',
      '停止'
    ];
    for (String keyword in commandKeywords) {
      if (lowerText.contains(keyword)) {
        print("🎯 匹配到动作指令关键词: $keyword");
        return IntentType.command;
      }
    }

    // 情绪识别关键词
    final emotionKeywords = [
      '高兴',
      '开心',
      '快乐',
      '愉快',
      '兴奋',
      '激动',
      '满足',
      '幸福',
      '欢乐',
      '悲伤',
      '难过',
      '沮丧',
      '失落',
      '孤独',
      '无助',
      '抑郁',
      '忧郁',
      '伤心',
      '愤怒',
      '生气',
      '恼火',
      '暴躁',
      '愤慨',
      '气愤',
      '恼怒',
      '惊讶',
      '震惊',
      '意外',
      '惊奇',
      '惊喜',
      '吃惊',
      '害怕',
      '恐惧',
      '紧张',
      '担心',
      '焦虑',
      '不安'
    ];
    for (String keyword in emotionKeywords) {
      if (lowerText.contains(keyword)) {
        print("🎯 匹配到情绪/安抚类关键词: $keyword");
        return IntentType.comfort;
      }
    }

    // 外部信息 / API 类（设备上下文、天气、新闻等；在视觉类之后避免「看看天气」误判）
    final externalKeywords = [
      '天气',
      '气温',
      '温度',
      '下雨',
      '刮风',
      '在哪',
      '位置',
      '定位',
      '地址',
      '时间',
      '几点',
      '新闻',
      '汇率',
      '股票',
      '快递',
    ];
    for (final keyword in externalKeywords) {
      if (lowerText.contains(keyword.replaceAll(' ', ''))) {
        print('🎯 匹配到外部信息/API 类关键词: $keyword');
        return IntentType.apiCall;
      }
    }

    // 空闲、敷衍、无实质内容
    final idleKeywords = [
      '嗯',
      '哦',
      '啊',
      '呃',
      '没事',
      '随便',
      '都行',
      '不知道说什么',
      '无聊',
    ];
    if (idleKeywords.any((k) => lowerText == k || lowerText.startsWith(k))) {
      print('🎯 匹配到空闲/敷衍类关键词');
      return IntentType.idle;
    }

    print("🎯 未匹配到特定关键词，归类为普通对话");
    // 默认为对话模式
    return IntentType.dialogue;
  }

  /// 获取模型信息
  Map<String, dynamic> getModelInfo() {
    return {
      'initialized': _initialized,
      'useDeepLearning': _useDeepLearningModel,
      'maxLength': maxLen,
      'labels': _labels,
      'vocabSize':
          (_useDeepLearningModel && _tokenizer != null) ? _tokenizer!.vocabSize : 0,
      'keywordOnlyMode': _keywordOnlyMode,
    };
  }

  /// 设置是否使用深度学习模型（[_keywordOnlyMode] 为 true 时无效）
  void setUseDeepLearningModel(bool use) {
    if (_keywordOnlyMode) {
      print("🔤 当前为强制关键词模式，忽略切换到 BERT 的请求");
      return;
    }
    _useDeepLearningModel = use && _initialized && _interpreter != null && _tokenizer != null;
    print(_useDeepLearningModel ? "🤖 切换到 BERT 模型" : "🔤 切换到关键词匹配");
  }

  /// 测试tokenizer
  TokenizerResult? testTokenizer(String text) {
    final tok = _tokenizer;
    if (!_useDeepLearningModel || tok == null) return null;
    return tok.tokenize(text, maxLen: maxLen);
  }

  /// 释放资源
  void dispose() {
    if (_initialized) {
      _interpreter?.close();
      _initialized = false;
      print("🗑️ 意图识别模块资源已释放");
    }
  }
}

/// 意图识别结果
class IntentResult {
  final IntentType intent;
  final double confidence;
  final String originalText;
  final String processedText;
  final List<double> allProbabilities;

  IntentResult({
    required this.intent,
    required this.confidence,
    required this.originalText,
    required this.processedText,
    required this.allProbabilities,
  });

  /// 是否为有效的意图识别结果（置信度大于阈值）
  bool get isValid => confidence > 0.6;

  @override
  String toString() {
    return 'IntentResult{intent: $intent, confidence: ${(confidence * 100).toStringAsFixed(1)}%, text: "$processedText"}';
  }
}
