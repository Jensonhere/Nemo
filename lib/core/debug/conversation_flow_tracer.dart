/// 对话主链路追踪：统一前缀 `[ConvFlow]`，日志里 grep `ConvFlow` 即可对齐一轮用户输入。
///
/// - `#<n>`：当前 [ConversationController.processUserInput] 轮次（从设置处理中标志到 `finally` 结束）。
/// - `—`：无活跃轮次时的事件（如 30s 超时、纯 ASR 生命周期）。
class ConversationFlowTracer {
  ConversationFlowTracer._();

  static int _seq = 0;
  static int? _activeTurn;

  static int? get activeTurnId => _activeTurn;

  static void _print(String line) {
    // ignore: avoid_print
    print(line);
  }

  /// 在已将 [_isProcessingUserInput] 置为 true 后调用。
  static int beginTurn(String userPreview) {
    _activeTurn = ++_seq;
    final p = userPreview.trim();
    final short = p.length > 48 ? '${p.substring(0, 48)}…' : p;
    _print('[ConvFlow]#$_activeTurn BEGIN preview="$short"');
    return _activeTurn!;
  }

  /// 当前轮内打点；若无活跃轮次则降级为 [orphan]（避免丢信息）。
  static void step(String phase, [String detail = '']) {
    final t = _activeTurn;
    final tail = detail.isEmpty ? '' : ' | $detail';
    if (t == null) {
      orphan('$phase$tail');
      return;
    }
    _print('[ConvFlow]#$t $phase$tail');
  }

  /// 无用户处理轮次时仍要打点（超时、退出对话、初始化等）。
  static void orphan(String message) {
    _print('[ConvFlow] — ${message.trim()}');
  }

  /// 麦克风 / Qwen ASR 专用，便于与对话轮次交叉对照。
  static void asr(String message) {
    orphan('[ASR] ${message.trim()}');
  }

  static void endTurn(String outcome) {
    final t = _activeTurn;
    if (t == null) return;
    _print('[ConvFlow]#$t END ${outcome.trim()}');
    _activeTurn = null;
  }
}
