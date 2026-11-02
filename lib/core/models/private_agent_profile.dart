/// 私人智能体配置模型
/// 每个用户拥有独立的智能体配置
class PrivateAgentProfile {
  /// 所属用户ID
  final String userId;

  /// 智能体名称
  final String name;

  /// 设定描述/人设（用于生成 system prompt）
  final String persona;

  /// 对话风格（如：简洁、详细、幽默等）
  final String style;

  /// 声线选择
  final String? voice;

  /// 头像类型（预留，用于后续扩展）
  final String? avatarType;

  /// 最后更新时间
  final DateTime updatedAt;

  PrivateAgentProfile({
    required this.userId,
    required this.name,
    required this.persona,
    required this.style,
    this.voice,
    this.avatarType,
    required this.updatedAt,
  });

  factory PrivateAgentProfile.fromJson(Map<String, dynamic> json) {
    return PrivateAgentProfile(
      userId: json['userId'] as String,
      name: json['name'] as String,
      persona: json['persona'] as String,
      style: json['style'] as String,
      voice: json['voice'] as String?,
      avatarType: json['avatarType'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'persona': persona,
      'style': style,
      'voice': voice,
      'avatarType': avatarType,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// 检查配置是否有效
  bool get isValid {
    return userId.isNotEmpty &&
        name.trim().isNotEmpty &&
        persona.trim().isNotEmpty &&
        style.trim().isNotEmpty;
  }
}
