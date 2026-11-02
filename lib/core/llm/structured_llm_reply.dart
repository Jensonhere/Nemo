import 'dart:convert';

/// 大模型结构化输出（D 层解析结果）
class StructuredLlmReply {
  final String replyText;
  final String emotionTag;
  final List<BluetoothActionJson> bluetoothActions;
  final bool interruptible;
  final bool memoryWorthy;
  final String? rawAssistant;

  StructuredLlmReply({
    required this.replyText,
    this.emotionTag = '中性',
    this.bluetoothActions = const [],
    this.interruptible = true,
    this.memoryWorthy = false,
    this.rawAssistant,
  });
}

class BluetoothActionJson {
  final String name;
  final int value;

  BluetoothActionJson({required this.name, required this.value});

  Map<String, dynamic> toMap() => {'name': name, 'value': value};
}

/// 解析与轻量后处理
class StructuredLlmReplyParser {
  static const Set<String> _allowedCommands = {
    '停止',
    '前进',
    '后退',
    '左转',
    '右转',
    '持续前进',
    '持续后退',
    '脑袋角度',
    '查询传感器',
  };

  static const List<String> _bannedPhrases = [
    '当然可以',
    '我很高兴为你服务',
    '作为你的助手',
    '我来帮你分析一下',
    '很乐意为您',
    '希望能帮到你',
  ];

  /// 从模型原文解析；失败时尽量抽出 reply_text 或给出口语化兜底，避免整段 JSON 送去 TTS
  static StructuredLlmReply parse(String raw) {
    final trimmed = raw.trim();
    final jsonStr = _extractJsonObject(trimmed);
    if (jsonStr == null) {
      final loose = _extractReplyTextQuoted(trimmed);
      return StructuredLlmReply(
        replyText: loose != null ? _postProcessPlain(loose) : _postProcessPlain(trimmed),
        rawAssistant: raw,
      );
    }
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final reply = map['reply_text']?.toString() ?? '';
      final emo = map['emotion_tag']?.toString() ?? '中性';
      final actions = _parseActions(map['bluetooth_actions']);
      final inter = map['interruptible'] is bool
          ? map['interruptible'] as bool
          : true;
      final mem = map['memory_worthy'] is bool
          ? map['memory_worthy'] as bool
          : false;
      return StructuredLlmReply(
        replyText: _postProcessPlain(reply),
        emotionTag: emo,
        bluetoothActions: actions,
        interruptible: inter,
        memoryWorthy: mem,
        rawAssistant: raw,
      );
    } catch (_) {
      final loose = _extractReplyTextQuoted(trimmed);
      return StructuredLlmReply(
        replyText: loose != null ? _postProcessPlain(loose) : _postProcessPlain(trimmed),
        rawAssistant: raw,
      );
    }
  }

  /// 模型偶发多字或截断时，尝试从原文抓取 reply_text 字段
  static String? _extractReplyTextQuoted(String text) {
    final re = RegExp(
      r'reply_text["\s]*:["\s]*"([\s\S]*?)"\s*[,}]',
      caseSensitive: false,
    );
    final m = re.firstMatch(text);
    if (m == null) return null;
    var inner = m.group(1) ?? '';
    inner = inner.replaceAll(r'\n', '');
    return inner.isEmpty ? null : inner;
  }

  /// 用户原话里「拐」→「转」，便于模型生成标准 JSON（与 [canonicalBluetoothCommandName] 一致）
  static String normalizeUserMotionForCommandLlm(String raw) {
    return raw
        .replaceAll('向左拐', '向左转')
        .replaceAll('向右拐', '向右转')
        .replaceAll('往左拐', '往左转')
        .replaceAll('往右拐', '往右转')
        .replaceAll('左拐', '左转')
        .replaceAll('右拐', '右转')
        .replaceAll('左转弯', '左转')
        .replaceAll('右转弯', '右转');
  }

  /// 口语「拐」等与协议名「转」对齐（ASR/模型偶发写左拐/右拐）
  static String canonicalBluetoothCommandName(String raw) {
    final n = raw.trim();
    const map = {
      '左拐': '左转',
      '右拐': '右转',
      '向左拐': '左转',
      '向右拐': '右转',
      '往左拐': '左转',
      '往右拐': '右转',
      '左转弯': '左转',
      '右转弯': '右转',
      '左转拐': '左转',
      '右转拐': '右转',
    };
    return map[n] ?? n;
  }

  static List<BluetoothActionJson> _parseActions(dynamic v) {
    if (v is! List) return [];
    final out = <BluetoothActionJson>[];
    for (final e in v) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final rawName = (m['name'] ?? m['command'] ?? '').toString().trim();
      final name = canonicalBluetoothCommandName(rawName);
      if (!_allowedCommands.contains(name)) continue;
      final val = m['value'];
      final iv = val is int ? val : int.tryParse(val?.toString() ?? '') ?? 0;
      out.add(BluetoothActionJson(name: name, value: iv));
    }
    return out;
  }

  static String? _extractJsonObject(String text) {
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
    final m = fence.firstMatch(text);
    final candidate = m != null ? m.group(1)!.trim() : text;
    final start = candidate.indexOf('{');
    final end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return candidate.substring(start, end + 1);
  }

  static String _postProcessPlain(String s) {
    var t = s.trim();
    for (final p in _bannedPhrases) {
      t = t.replaceAll(p, '');
    }
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 过短会截断正常英文段落，易被误以为「没播报」；口语回复仍不宜无限长
    return _compressIfNeeded(t, maxChars: 500);
  }

  /// 按字符数（Unicode 码点）压缩
  static String _compressIfNeeded(String text, {int maxChars = 50}) {
    if (text.isEmpty) return text;
    final runes = text.runes.toList();
    if (runes.length <= maxChars) return text;
    return '${String.fromCharCodes(runes.take(maxChars))}…';
  }
}
