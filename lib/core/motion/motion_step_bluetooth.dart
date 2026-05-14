import 'package:voicegpt/core/llm/structured_llm_reply.dart';

/// Router 输出的 `motion_step`（如 `前进,200` / `向左,100mm`）解析为协议内单步蓝牙动作。
class MotionStepBluetooth {
  MotionStepBluetooth._();

  /// 与 Router「单轴 B 类」对齐：仅四向/直线短指令时走 motion_step 快路径。
  ///
  /// 须覆盖 ASR 口语（儿化、靠近我）等，否则 Router 已给出 [motion_step] 仍会被会话层拒执行。
  static bool isSimpleCardinalMotionQuery(String raw) {
    var s = raw.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return false;
    // 儿化音：「转一圈儿」与「转一圈」等价，便于子串命中
    s = s.replaceAll('转一圈儿', '转一圈').replaceAll('转个圈儿', '转个圈');
    const keys = [
      '向前',
      '向后',
      '向左',
      '向右',
      '前进',
      '后退',
      '左转',
      '右转',
      '往前',
      '往后',
      '往左',
      '往右',
      '左拐',
      '右拐',
      '直行',
      // 朝用户靠近（Router 常映射为前进）
      '向我靠近',
      '朝我靠近',
      '靠近我',
      '离我近',
      '凑近',
      '过来一点',
      // 原地转圈（Router 常映射为左转/右转 360）
      '转一圈',
      '转个圈',
      '转圈',
      '旋转',
      '原地转',
    ];
    return keys.any(s.contains);
  }

  /// 将 Router 给出的 `motion_step` 解析为单条 [BluetoothActionJson]；失败返回 null。
  ///
  /// 支持：`协议或口语动词,数值` 或 `动词,数值单位`（英文/中文单位）。
  /// - **前进/后退**：数值为 **毫米**（若写厘米/米会换算为 mm）。
  /// - **左转/右转**：若单位为 **度**或未标单位则按 **度**；若为 **mm/毫米/厘米/米** 则按保守启发式换算为角度（15～180）。
  static BluetoothActionJson? parseMotionStepToBluetooth(String raw) {
    final t = raw.trim().replaceAll('，', ',');
    final idx = t.indexOf(',');
    if (idx <= 0 || idx >= t.length - 1) return null;
    final verbRaw = t.substring(0, idx).trim();
    final rest = t.substring(idx + 1).trim();
    final protocol = _canonicalMotionVerb(verbRaw);
    if (protocol == null) return null;

    final isLinear = protocol == '前进' || protocol == '后退';
    final parsed = _parseNumericWithUnit(rest, isLinear: isLinear);
    if (parsed == null) return null;
    return BluetoothActionJson(name: protocol, value: parsed);
  }

  /// 给 TTS 的一句短确认（不含 JSON）。
  static String spokenAckFor(BluetoothActionJson a) {
    switch (a.name) {
      case '前进':
        return '好的，前进约 ${a.value} 毫米。';
      case '后退':
        return '好的，后退约 ${a.value} 毫米。';
      case '左转':
        return '好的，左转约 ${a.value} 度。';
      case '右转':
        return '好的，右转约 ${a.value} 度。';
      default:
        return '好的。';
    }
  }

  static String? _canonicalMotionVerb(String raw) {
    final v = raw.trim();
    const forward = {'前进', '向前', '往前', '直行'};
    const backward = {'后退', '向后', '往后'};
    const left = {'左转', '向左', '往左', '左拐'};
    const right = {'右转', '向右', '往右', '右拐'};
    if (forward.contains(v)) return '前进';
    if (backward.contains(v)) return '后退';
    if (left.contains(v)) return '左转';
    if (right.contains(v)) return '右转';
    return null;
  }

  static int? _parseNumericWithUnit(String rest, {required bool isLinear}) {
    final re = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(mm|毫米|厘米|公分|cm|米|m|度|deg|°)?',
      caseSensitive: false,
    );
    final m = re.firstMatch(rest.trim());
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null || n <= 0) return null;
    final u = (m.group(2) ?? '').toLowerCase();

    if (isLinear) {
      if (u == 'm' || u == '米') return (n * 1000).round().clamp(1, 20000);
      if (u == 'cm' || u == '厘米' || u == '公分') return (n * 10).round().clamp(1, 20000);
      // mm / 毫米 / 默认
      return n.round().clamp(1, 20000);
    }

    // 转向：明确角度
    if (u == '度' || u == 'deg' || u == '°' || u.isEmpty) {
      return n.round().clamp(1, 360);
    }
    // 转向：长度类 → 保守换算为角度（仅启发式，避免过大转角）
    double mm;
    if (u == 'm' || u == '米') {
      mm = n * 1000;
    } else if (u == 'cm' || u == '厘米' || u == '公分') {
      mm = n * 10;
    } else {
      mm = n; // 视为毫米
    }
    final deg = (mm / 6.0).round().clamp(15, 180);
    return deg;
  }
}
