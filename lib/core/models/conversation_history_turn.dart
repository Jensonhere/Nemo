class ConversationHistoryTurn {
  const ConversationHistoryTurn({
    required this.userText,
    required this.assistantText,
    required this.createdAt,
  });

  final String userText;
  final String assistantText;
  final DateTime createdAt;

  factory ConversationHistoryTurn.fromJson(Map<String, dynamic> json) {
    return ConversationHistoryTurn(
      userText: (json['userText'] ?? '').toString(),
      assistantText: (json['assistantText'] ?? '').toString(),
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userText': userText,
      'assistantText': assistantText,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  bool get isValid =>
      userText.trim().isNotEmpty && assistantText.trim().isNotEmpty;
}
