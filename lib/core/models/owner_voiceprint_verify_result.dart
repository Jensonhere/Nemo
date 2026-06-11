/// 主人声纹比对结果（用于 UI 展示）。
class OwnerVoiceprintVerifyResult {
  const OwnerVoiceprintVerifyResult({
    required this.bestScore,
    required this.pass,
    required this.valid,
    this.reason,
  });

  final double? bestScore;
  final bool pass;
  final bool valid;

  /// 诊断：`match` / `mismatch` / 或失败原因文案。
  final String? reason;

  static const invalid = OwnerVoiceprintVerifyResult(
    bestScore: null,
    pass: false,
    valid: false,
    reason: '无效',
  );
}
