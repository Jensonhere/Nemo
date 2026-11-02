/// 主人声纹库条目（UI 展示用，不含 embedding 向量）。
class OwnerVoiceprintSample {
  const OwnerVoiceprintSample({
    required this.id,
    required this.label,
    required this.durationMs,
    required this.createdAtMs,
    required this.hasAudio,
    required this.isActive,
  });

  final String id;
  final String label;
  final int durationMs;
  final int createdAtMs;
  final bool hasAudio;
  final bool isActive;

  String get durationLabel {
    final s = (durationMs / 1000).ceil();
    return '0:${s.toString().padLeft(2, '0')}';
  }
}
