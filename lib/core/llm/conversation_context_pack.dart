/// C. 上下文层：注入对话轮次、情绪、设备与环境摘要、时间等（由控制器组装）
class ConversationContextPack {
  /// 已格式化的「用户/小航」多行文本，约 2～4 轮
  final List<String> recentTurnLines;

  /// 语音/VA 情绪摘要（安抚场景用）
  final String? userEmotionFromVa;

  /// VA 数值摘要，例如 valence/arousal/dominance
  final String? vaValuesSummary;

  /// VA 标签摘要
  final String? vaTagsSummary;

  /// VA 给 LLM 的提示片段
  final String? vaPromptHint;

  /// 设备状态一行话（电量、连接等，暂无数据时可占位）
  final String? deviceStateLine;

  /// 环境解读用摘要（摄像头分析结论等）
  final String? environmentSummary;

  /// 来自 [DeviceContextService] 等的设备上下文块
  final String? deviceContextBlock;

  /// 距上次交互多久（可读中文）
  final String? idleSinceDescription;

  ConversationContextPack({
    this.recentTurnLines = const [],
    this.userEmotionFromVa,
    this.vaValuesSummary,
    this.vaTagsSummary,
    this.vaPromptHint,
    this.deviceStateLine,
    this.environmentSummary,
    this.deviceContextBlock,
    this.idleSinceDescription,
  });

  String formatContextBlock() {
    final sb = StringBuffer();
    if (recentTurnLines.isNotEmpty) {
      sb.writeln('【最近对话】');
      for (final line in recentTurnLines) {
        sb.writeln(line);
      }
    }
    if (userEmotionFromVa != null && userEmotionFromVa!.trim().isNotEmpty) {
      sb.writeln('【用户语气/情绪（VA）】${userEmotionFromVa!.trim()}');
    }
    if (vaValuesSummary != null && vaValuesSummary!.trim().isNotEmpty) {
      sb.writeln('【VA数值摘要】${vaValuesSummary!.trim()}');
    }
    if (vaTagsSummary != null && vaTagsSummary!.trim().isNotEmpty) {
      sb.writeln('【VA标签摘要】${vaTagsSummary!.trim()}');
    }
    if (vaPromptHint != null && vaPromptHint!.trim().isNotEmpty) {
      sb.writeln('【VA提示】${vaPromptHint!.trim()}');
    }
    if (deviceStateLine != null && deviceStateLine!.trim().isNotEmpty) {
      sb.writeln('【设备状态】${deviceStateLine!.trim()}');
    }
    if (environmentSummary != null && environmentSummary!.trim().isNotEmpty) {
      sb.writeln('【环境摘要】${environmentSummary!.trim()}');
    }
    if (idleSinceDescription != null &&
        idleSinceDescription!.trim().isNotEmpty) {
      sb.writeln('【交互间隔】${idleSinceDescription!.trim()}');
    }
    if (deviceContextBlock != null && deviceContextBlock!.trim().isNotEmpty) {
      sb.writeln(deviceContextBlock!.trim());
    }
    return sb.toString();
  }
}
