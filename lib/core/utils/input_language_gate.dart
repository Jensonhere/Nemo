/// 在进入六分类意图前，判断是否为「英语教学」口语场景。
class InputLanguageGate {
  InputLanguageGate._();

  /// 纯英文为主，或中英混排且含一定量拉丁字母时，走英语教学专属 prompt。
  static bool isEnglishTeachingScene(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;

    final hasHan = RegExp(r'[\u4e00-\u9fff]').hasMatch(t);
    final latinCount = RegExp(r'[a-zA-Z]').allMatches(t).length;
    final nonSpace = t.replaceAll(RegExp(r'\s'), '');
    if (nonSpace.isEmpty) return false;

    if (!hasHan && latinCount >= 2) {
      return true;
    }
    if (hasHan && latinCount >= 4) {
      return true;
    }
    return false;
  }
}
