/// Planner / 执行器共用的表情标签（与 assets 下 face2 等资源一致；KISS 在 face1）。
abstract class PlannerExpressionCatalog {
  PlannerExpressionCatalog._();

  /// 允许写入 Planner JSON 的「expression」字段，须完全命中下列之一（大小写：KISS 仅大写，其余中文）。
  static const List<String> allowedLabels = [
    'KISS',
    '愤怒',
    '感激',
    '孤独',
    '观察',
    '坚定',
    '惊喜',
    '惊讶',
    '开心',
    '可爱',
    '热切',
    '倾听',
    '失落',
    '说话',
    '思考',
    '委屈',
    '晕',
    '寻找',
    '疑惑',
    '眨眼',
  ];

  static final Set<String> _allowedLower = {
    for (final e in allowedLabels) e.toLowerCase(),
  };

  /// 将模型输出规范为白名单内标签；无法识别时返回「思考」。
  static String canonicalize(String? raw) {
    if (raw == null) return '思考';
    final t = raw.trim();
    if (t.isEmpty) return '思考';
    if (t.toUpperCase() == 'KISS') return 'KISS';
    for (final label in allowedLabels) {
      if (label != 'KISS' && label == t) return label;
    }
    if (_allowedLower.contains(t.toLowerCase())) {
      for (final label in allowedLabels) {
        if (label.toLowerCase() == t.toLowerCase()) return label;
      }
    }
    return '思考';
  }

  /// 与 [canonicalize] 对应的一条 Lottie 资源路径（优先 02 变体）。
  static String? assetPathFor(String canonicalLabel) {
    switch (canonicalLabel) {
      case 'KISS':
        return 'assets/emotion/face1/KISS/02/Kiss 02.json';
      case '眨眼':
        return 'assets/emotion/face2/眨眼.json';
      case '疑惑':
        return 'assets/emotion/face2/疑惑/01/疑惑 01.json';
      case '晕':
        return 'assets/emotion/face2/晕/02/晕 02.json';
      case '愤怒':
        return 'assets/emotion/face2/愤怒/02/愤怒 02.json';
      case '失落':
        return 'assets/emotion/face2/失落/02/失落 02.json';
      case '惊讶':
        return 'assets/emotion/face2/惊讶/02/惊讶 02.json';
      case '可爱':
        return 'assets/emotion/face2/可爱/02/可爱 02.json';
      case '开心':
        return 'assets/emotion/face2/开心/02/开心 02.json';
      case '思考':
        return 'assets/emotion/face2/思考/02/思考 02.json';
      case '说话':
        return 'assets/emotion/face2/说话/02/说话 02.json';
      case '观察':
        return 'assets/emotion/face2/观察/02/观察 02.json';
      case '热切':
        return 'assets/emotion/face2/热切/02/热切 02.json';
      case '感激':
        return 'assets/emotion/face2/感激/02/感激 02.json';
      case '孤独':
        return 'assets/emotion/face2/孤独/02/孤独 02.json';
      case '坚定':
        return 'assets/emotion/face2/坚定/02/坚定 02.json';
      case '惊喜':
        return 'assets/emotion/face2/惊喜/02/惊喜 02.json';
      case '倾听':
        return 'assets/emotion/face2/倾听/02/倾听 02.json';
      case '委屈':
        return 'assets/emotion/face2/委屈/02/委屈 02.json';
      case '寻找':
        return 'assets/emotion/face2/寻找/02/寻找 02.json';
      default:
        return null;
    }
  }

  static String allowedLabelsForPrompt() => allowedLabels.join('、');
}
