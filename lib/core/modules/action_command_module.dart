import 'dart:async';
import 'dart:math' show Random;
import 'package:voicegpt/core/llm/structured_llm_reply.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';

/// command 场景结构化蓝牙链执行结果（用于追加「未连接」、悬崖/碰撞安全播报）
class BluetoothChainOutcome {
  final bool skippedDisconnected;
  final bool linearInterrupted;
  final int obstacleType;

  const BluetoothChainOutcome({
    this.skippedDisconnected = false,
    this.linearInterrupted = false,
    this.obstacleType = 0,
  });
}

/// 动作类型枚举
enum ActionType {
  forward, // 前进
  backward, // 后退
  turnLeft, // 左转
  turnRight, // 右转
  headAngle, // 头部角度
  nod, // 点头动作（下->上->中）
  stop, // 停止
  unknown, // 未知动作
}

/// 动作指令模块
/// 处理机器人的物理动作控制，包括移动、旋转、头部角度等
class ActionCommandModule {
  static final ActionCommandModule _instance = ActionCommandModule._internal();
  factory ActionCommandModule() => _instance;
  ActionCommandModule._internal();

  final UIAnimationModule _uiModule = UIAnimationModule();
  MyBluetoothService? _bluetoothService;

  bool _isProcessing = false;

  /// 当前是否正在处理
  bool get isProcessing => _isProcessing;

  /// 初始化蓝牙服务
  void initializeBluetoothService(MyBluetoothService bluetoothService) {
    _bluetoothService = bluetoothService;
    print("🔗 动作指令模块蓝牙服务已设置");
  }

  /// 处理动作指令
  Future<ActionCommandResult> processActionCommand(
    String userInput, {
    bool playCommandAnimation = true,
  }) async {
    if (_isProcessing) {
      print("⏳ 动作指令模块正在处理中，忽略新请求");
      return ActionCommandResult(
        success: false,
        response: "系统正在执行上一个动作，请稍候",
        userInput: userInput,
        action: ActionType.unknown,
      );
    }

    _isProcessing = true;
    print("🤖 开始处理动作指令: $userInput");

    try {
      // 显示动作指令动画（Planner 场景可关闭，避免覆盖每步表情切换）
      if (playCommandAnimation) {
        _uiModule.handleCommandAnimation();
      }

      // 解析动作类型和参数
      final commandInfo = _parseActionCommand(userInput);

      if (commandInfo.action == ActionType.unknown) {
        return ActionCommandResult(
          success: false,
          response: "抱歉，我不理解这个动作指令",
          userInput: userInput,
          action: ActionType.unknown,
        );
      }

      // 检查蓝牙连接
      if (_bluetoothService == null || !_bluetoothService!.isConnected) {
        return ActionCommandResult(
          success: false,
          response: "机器人未连接",
          userInput: userInput,
          action: commandInfo.action,
          error: "蓝牙未连接",
        );
      }

      // 执行动作（前进/后退会等 MCU 回包，避免未完成却播报满行程）
      final spoken = await _executeAction(commandInfo);

      print("✅ 动作指令处理完成: ${spoken.line}");
      final response =
          spoken.prependExecuted ? '已执行动作指令，${spoken.line}' : spoken.line;
      return ActionCommandResult(
        success: true,
        response: response,
        userInput: userInput,
        action: commandInfo.action,
        value: commandInfo.value,
        ttsEmotionUiLabel: spoken.showAnger ? '愤怒' : null,
      );
    } catch (e) {
      print("❌ 动作指令执行失败: $e");
      return ActionCommandResult(
        success: false,
        response: "动作执行失败，请重试",
        userInput: userInput,
        action: ActionType.unknown,
        error: e.toString(),
      );
    } finally {
      _isProcessing = false;
    }
  }

  /// 解析动作指令
  _ActionCommandInfo _parseActionCommand(String userInput) {
    final lowerInput = userInput.toLowerCase().trim();

    // 停止
    if (_containsAny(lowerInput, ['停止', '停下', '停', '别动', '不要动'])) {
      return _ActionCommandInfo(ActionType.stop, 0);
    }

    // 队列口令「向后转」= 原地调头 180°，勿与直线「向后」混淆（须在泛匹配「向后」之前）
    if (_containsAny(lowerInput, ['向后转', '向后转体', '后转'])) {
      return _ActionCommandInfo(ActionType.turnRight, 180);
    }

    // 朝用户靠近 → 直线前进（与 Router / motion_gate 口语一致）
    if (_containsAny(lowerInput, [
      '向我靠近',
      '朝我靠近',
      '靠近我',
      '离我近',
      '凑近一点',
      '凑近些',
      '靠近一点',
      '靠近一些',
    ])) {
      final distance = _parseLinearDistanceMm(
        userInput,
        const [
          '向我靠近',
          '朝我靠近',
          '靠近我',
          '离我近',
          '凑近一点',
          '凑近些',
          '靠近一点',
          '靠近一些',
        ],
        fallbackMm: 280,
      );
      return _ActionCommandInfo(ActionType.forward, distance);
    }

    // 前进指令（距离须跟在动词后解析，避免句首日期等抢先匹配）
    if (_containsAny(lowerInput, ['前进', '向前', '往前', '前走', '直行', '前行'])) {
      final distance = _parseLinearDistanceMm(
        userInput,
        const ['前进', '向前', '往前', '前走', '直行', '前行'],
        fallbackMm: 200,
      );
      return _ActionCommandInfo(ActionType.forward, distance);
    }

    // 后退指令
    if (_containsAny(lowerInput, ['后退', '向后', '往后', '后走', '倒退', '退后'])) {
      final distance = _parseLinearDistanceMm(
        userInput,
        const ['后退', '向后', '往后', '后走', '倒退', '退后'],
        fallbackMm: 200,
      );
      return _ActionCommandInfo(ActionType.backward, distance);
    }

    // 旋转/转圈指令（支持：旋转一圈/转一周/原地旋转/向右旋转两圈等）
    final spin = _tryParseSpinTurn(userInput);
    if (spin != null) {
      return spin;
    }

    // 左转指令
    if (_containsAny(lowerInput, ['左转', '向左转', '转左', '左拐', '往左'])) {
      int angle = _extractNumber(userInput, defaultValue: 90); // 默认90度
      return _ActionCommandInfo(ActionType.turnLeft, angle);
    }

    // 右转指令
    if (_containsAny(lowerInput, ['右转', '向右转', '转右', '右拐', '往右'])) {
      int angle = _extractNumber(userInput, defaultValue: 90); // 默认90度
      return _ActionCommandInfo(ActionType.turnRight, angle);
    }

    // 头部角度/点头指令（协议为绝对角度 8~20）
    if (_containsAny(lowerInput, [
      '脑袋角度',
      '头部角度',
      '抬头',
      '低头',
      '头角度',
      '点头',
      '上升',
      '下降'
    ])) {
      int angle;
      if (_containsAny(lowerInput, ['抬头', '向上', '仰头', '上升'])) {
        angle = _headNodMagnitude(_extractNumber(userInput, defaultValue: 20));
      } else if (_containsAny(lowerInput, ['低头', '向下', '俯头', '下降'])) {
        angle = _headNodMagnitude(_extractNumber(userInput, defaultValue: 8));
      } else if (_containsAny(lowerInput, ['点头'])) {
        final mag = _headNodMagnitude(_extractNumber(userInput, defaultValue: 12));
        return _ActionCommandInfo(ActionType.nod, mag);
      } else {
        // 显式角度：绝对角度 8~20
        final n = _extractNumber(userInput, defaultValue: 8);
        angle = _headNodMagnitude(n.abs());
      }
      return _ActionCommandInfo(ActionType.headAngle, angle);
    }

    return _ActionCommandInfo(ActionType.unknown, 0);
  }

  int _headNodMagnitude(int n) {
    if (n < 8) return 8;
    if (n > 20) return 20;
    return n;
  }

  _ActionCommandInfo? _tryParseSpinTurn(String raw) {
    final t = _asciiDigitsFromFullwidth(raw).toLowerCase();
    final hasSpinVerb = _containsAny(t, [
      '旋转',
      '转动',
      '自转',
      '转圈',
      '转一圈',
      '转个圈',
      '原地转',
    ]);
    final hasCircle = _containsAny(t, ['一圈', '一周', '圈', '周', '360']);
    if (!hasSpinVerb && !hasCircle) return null;

    final prefersLeft = _containsAny(t, ['左', '向左', '往左', '逆时针']);
    var angle = 360;
    final n = _extractNumber(t, defaultValue: 0);
    if (n > 0) {
      if (t.contains('圈') || t.contains('周')) {
        angle = (n * 360).clamp(90, 1440);
      } else {
        angle = n.clamp(90, 1440);
      }
    }
    return _ActionCommandInfo(
      prefersLeft ? ActionType.turnLeft : ActionType.turnRight,
      angle,
    );
  }

  /// 检查文本是否包含任意关键词
  bool _containsAny(String text, List<String> keywords) {
    return keywords.any((keyword) => text.contains(keyword));
  }

  /// 从文本中提取数字（整句第一个数字；仅用于角度等，直线距离请用 [_parseLinearDistanceMm]）
  int _extractNumber(String text, {required int defaultValue}) {
    final normalized = _asciiDigitsFromFullwidth(text);
    final regex = RegExp(r'\d+');
    final match = regex.firstMatch(normalized);
    if (match != null) {
      return int.tryParse(match.group(0)!) ?? defaultValue;
    }
    return defaultValue;
  }

  /// 全角数字 → 半角，便于 `\d+` 解析 ASR 结果
  String _asciiDigitsFromFullwidth(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xFF10 && r <= 0xFF19) {
        buf.writeCharCode(r - 0xFF10 + 0x30);
      } else {
        buf.writeCharCode(r);
      }
    }
    return buf.toString();
  }

  /// 在「前进/后退」类动词之后解析毫米；无有效数量时 3～10cm 随机（毫米）。
  int _parseLinearDistanceMm(
    String raw,
    List<String> verbs, {
    required int fallbackMm,
  }) {
    final text = _asciiDigitsFromFullwidth(raw);
    final lower = text.toLowerCase();

    int? fromVerbTail(String tail) {
      final t = tail.trim();
      if (t.isEmpty) return null;

      // 阿拉伯数字 + 单位（从动词后起算）
      final withUnit = RegExp(
        r'^(\d+)\s*(mm|millimeter|毫米|厘米|公分|cm|米|m)\b',
        caseSensitive: false,
      ).firstMatch(t);
      if (withUnit != null) {
        final n = int.tryParse(withUnit.group(1)!) ?? 0;
        if (n <= 0) return null;
        final u = (withUnit.group(2) ?? 'mm').toLowerCase();
        if (u == 'm' || u == '米') return (n * 1000).clamp(1, 20000);
        if (u == 'cm' || u == '厘米' || u == '公分') return (n * 10).clamp(1, 20000);
        return n.clamp(1, 20000);
      }

      final bare = RegExp(r'^(\d+)\b').firstMatch(t);
      if (bare != null) {
        final n = int.tryParse(bare.group(1)!) ?? 0;
        if (n > 0) return n.clamp(1, 20000);
      }

      final sloppy = RegExp(
        r'^\D*(\d+)\s*(mm|millimeter|毫米|厘米|公分|cm|米|m)?\b',
        caseSensitive: false,
      ).firstMatch(t);
      if (sloppy != null) {
        final n = int.tryParse(sloppy.group(1)!) ?? 0;
        if (n > 0) {
          final u = (sloppy.group(2) ?? 'mm').toLowerCase();
          if (u == 'm' || u == '米') return (n * 1000).clamp(1, 20000);
          if (u == 'cm' || u == '厘米' || u == '公分') {
            return (n * 10).clamp(1, 20000);
          }
          return n.clamp(1, 20000);
        }
      }

      final cn = _tryParseChineseDistanceMm(t);
      if (cn != null) return cn;

      return null;
    }

    int? best;
    var bestIdx = 1 << 30;
    for (final v in verbs) {
      final idx = lower.indexOf(v.toLowerCase());
      if (idx < 0) continue;
      final tail = text.substring(idx + v.length);
      final parsed = fromVerbTail(tail);
      if (parsed != null && idx < bestIdx) {
        bestIdx = idx;
        best = parsed;
      }
    }
    if (best != null) return best;

    // 句中无任何「动词后距离」时，再退回：全句是否有阿拉伯数字（兼容旧说法但易误判）
    if (RegExp(r'\d').hasMatch(text)) {
      return _extractNumber(text, defaultValue: fallbackMm);
    }

    final cm = Random().nextInt(8) + 3;
    return cm * 10;
  }

  /// 动词后紧跟的常见中文距离（数词为「个数」，再按 毫米/厘米/米 换算为毫米）
  int? _tryParseChineseDistanceMm(String tail) {
    final t = tail.trimLeft();
    const mm = '毫米';
    const cm = '厘米';
    const gf = '公分';
    const mi = '米';

    int? convertAfterNumber(int count, String rest) {
      if (rest.startsWith(mm)) return count.clamp(1, 20000);
      if (rest.startsWith(cm) || rest.startsWith(gf)) {
        return (count * 10).clamp(1, 20000);
      }
      if (rest.startsWith(mi)) return (count * 1000).clamp(1, 20000);
      return null;
    }

    int? tryBlock(String prefix, int count) {
      if (!t.startsWith(prefix)) return null;
      return convertAfterNumber(count, t.substring(prefix.length));
    }

    const hundreds = {
      '一百': 100,
      '二百': 200,
      '三百': 300,
      '四百': 400,
      '五百': 500,
      '六百': 600,
      '七百': 700,
      '八百': 800,
      '九百': 900,
    };
    for (final e in hundreds.entries) {
      final r = tryBlock(e.key, e.value);
      if (r != null) return r;
    }

    const tens = {
      '十': 10,
      '二十': 20,
      '三十': 30,
      '四十': 40,
      '五十': 50,
      '六十': 60,
      '七十': 70,
      '八十': 80,
      '九十': 90,
    };
    for (final e in tens.entries) {
      final r = tryBlock(e.key, e.value);
      if (r != null) return r;
    }

    const digit = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    for (final e in digit.entries) {
      final r = tryBlock(e.key, e.value);
      if (r != null) return r;
    }

    return null;
  }

  /// 执行动作
  Future<_SpokenMotion> _executeAction(_ActionCommandInfo commandInfo) async {
    try {
      switch (commandInfo.action) {
        case ActionType.forward:
          final fb = await _bluetoothService!
              .sendLinearMotionAndAwaitFeedback('前进', commandInfo.value);
          return _spokenForLinearMotion('前进', commandInfo.value, fb);

        case ActionType.backward:
          final fb = await _bluetoothService!
              .sendLinearMotionAndAwaitFeedback('后退', commandInfo.value);
          return _spokenForLinearMotion('后退', commandInfo.value, fb);

        case ActionType.turnLeft:
          await _bluetoothService!.sendCommand('左转', commandInfo.value);
          return _SpokenMotion('已左转 ${commandInfo.value} 度');

        case ActionType.turnRight:
          await _bluetoothService!.sendCommand('右转', commandInfo.value);
          return _SpokenMotion('已右转 ${commandInfo.value} 度');

        case ActionType.headAngle:
          await _bluetoothService!.sendCommand('脑袋角度', commandInfo.value);
          return _SpokenMotion(
            '头部已调整到 ${commandInfo.value} 度',
          );

        case ActionType.nod:
          await _bluetoothService!.sendCommand('脑袋角度', 8);
          await Future<void>.delayed(const Duration(milliseconds: 180));
          await _bluetoothService!.sendCommand('脑袋角度', 20);
          await Future<void>.delayed(const Duration(milliseconds: 180));
          await _bluetoothService!.sendCommand('脑袋角度', 8);
          await Future<void>.delayed(const Duration(milliseconds: 180));
          await _bluetoothService!.sendCommand('脑袋角度', 15);
          return const _SpokenMotion('已执行点头');

        case ActionType.stop:
          await _bluetoothService!.sendCommand('停止', 0);
          return const _SpokenMotion('已停止');

        default:
          throw Exception("未知的动作类型: ${commandInfo.action}");
      }
    } catch (e) {
      throw Exception("蓝牙通信失败: $e");
    }
  }

  _SpokenMotion _spokenForLinearMotion(
    String verbMmLabel,
    int requestedMm,
    LinearMotionFeedback fb,
  ) {
    switch (fb.kind) {
      case LinearMotionEndKind.completed:
        return _SpokenMotion(
          verbMmLabel == '前进'
              ? '已前进 $requestedMm 毫米'
              : '已后退 $requestedMm 毫米',
        );
      case LinearMotionEndKind.timedOut:
        return _SpokenMotion(
          '已下发$verbMmLabel指令，未收到完成回包，请留意机身与周围是否安全',
        );
      case LinearMotionEndKind.interrupted:
        final line = _ttsForObstacleByte(fb.obstacleType);
        return _SpokenMotion(line, showAnger: true, prependExecuted: false);
    }
  }

  /// MCU byte3：0x01/02 障碍，0x03/04 悬崖（与 [MyBluetoothService._parseObstacleType] 一致）
  String _ttsForObstacleByte(int type) {
    switch (type) {
      case 0x01:
      case 0x02:
        return '马上碰撞啦';
      case 0x03:
      case 0x04:
        return '遇到悬崖啦';
      default:
        return '碰到障碍啦，先停一下';
    }
  }

  /// 快速动作预设
  Future<ActionCommandResult> executeQuickAction(ActionType action,
      {int? value}) async {
    String commandText = _getActionDisplayName(action);
    if (value != null) {
      commandText += " $value";
    }
    return await processActionCommand(commandText);
  }

  /// 停止所有动作
  Future<void> stopAllActions() async {
    if (_bluetoothService != null && _bluetoothService!.isConnected) {
      try {
        await _bluetoothService!.sendCommand('停止', 0);
        print("🛑 停止所有动作");
      } catch (e) {
        print("❌ 停止动作失败: $e");
      }
    }
  }

  /// 获取动作类型的显示名称
  String _getActionDisplayName(ActionType action) {
    switch (action) {
      case ActionType.forward:
        return '前进';
      case ActionType.backward:
        return '后退';
      case ActionType.turnLeft:
        return '左转';
      case ActionType.turnRight:
        return '右转';
      case ActionType.headAngle:
        return '脑袋角度';
      case ActionType.nod:
        return '点头';
      case ActionType.stop:
        return '停止';
      case ActionType.unknown:
        return '未知动作';
    }
  }

  /// 检查蓝牙连接状态
  bool get isBluetoothConnected => _bluetoothService?.isConnected ?? false;

  /// 按顺序执行大模型输出的 `bluetooth_actions`（command 场景）；前进/后退会等 MCU 回包。
  Future<BluetoothChainOutcome> applyStructuredBluetoothActions(
      List<BluetoothActionJson> actions) async {
    if (actions.isEmpty) return const BluetoothChainOutcome();
    if (_bluetoothService == null || !_bluetoothService!.isConnected) {
      print("⚠️ 结构化蓝牙：未连接，跳过 ${actions.length} 条");
      return const BluetoothChainOutcome(skippedDisconnected: true);
    }
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      try {
        if (a.name == '前进' || a.name == '后退') {
          final fb = await _bluetoothService!
              .sendLinearMotionAndAwaitFeedback(a.name, a.value);
          if (fb.kind == LinearMotionEndKind.interrupted) {
            print(
              '🛑 结构化蓝牙直线运动被传感器中断，已中止后续步骤: ${a.name} '
              'obstacle=0x${fb.obstacleType.toRadixString(16)}',
            );
            return BluetoothChainOutcome(
              linearInterrupted: true,
              obstacleType: fb.obstacleType,
            );
          }
        } else {
          await _bluetoothService!.sendCommand(a.name, a.value);
        }
        print(
          '📡 结构化蓝牙 [${i + 1}/${actions.length}] 已发送: ${a.name} value=${a.value}',
        );
      } catch (e) {
        print("❌ 结构化蓝牙失败 ${a.name}: $e");
      }
    }
    return const BluetoothChainOutcome();
  }
}

/// 播报文案与表情（前进/后退遇悬崖/碰撞时不加「已执行动作指令」前缀，并切愤怒脸）
class _SpokenMotion {
  final String line;
  final bool showAnger;
  final bool prependExecuted;

  const _SpokenMotion(
    this.line, {
    this.showAnger = false,
    this.prependExecuted = true,
  });
}

/// 动作指令信息
class _ActionCommandInfo {
  final ActionType action;
  final int value;

  _ActionCommandInfo(this.action, this.value);
}

/// 动作指令结果
class ActionCommandResult {
  final bool success;
  final String response;
  final String userInput;
  final ActionType action;
  final int? value;
  final String? error;
  /// 非空时与 [TtsAlignedExpression.emotionSpeaking] 连用（如悬崖/碰撞 → `愤怒` → 愤怒 02.json）
  final String? ttsEmotionUiLabel;
  final DateTime timestamp;

  ActionCommandResult({
    required this.success,
    required this.response,
    required this.userInput,
    required this.action,
    this.value,
    this.error,
    this.ttsEmotionUiLabel,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    return 'ActionCommandResult{success: $success, action: $action, userInput: "$userInput", response: "$response"${error != null ? ', error: "$error"' : ''}}';
  }
}
