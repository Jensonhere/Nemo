class TtsVoiceOption {
  const TtsVoiceOption({
    required this.voiceType,
    required this.name,
    required this.category,
    required this.description,
  });

  final int voiceType;
  final String name;
  final String category;
  final String description;
}

const List<TtsVoiceOption> ttsVoiceOptions = [
  TtsVoiceOption(
    voiceType: 101028,
    name: '默认声线',
    category: '原始版本',
    description: '沿用最开始版本的默认音色。',
  ),
  TtsVoiceOption(
    voiceType: 101002,
    name: '智聆',
    category: '自然女声',
    description: '清晰自然，适合日常陪伴对话。',
  ),
  TtsVoiceOption(
    voiceType: 101003,
    name: '智美',
    category: '甜美女声',
    description: '音色更明亮，适合轻快回应。',
  ),
  TtsVoiceOption(
    voiceType: 101005,
    name: '智莉',
    category: '温暖女声',
    description: '语气柔和，适合情绪安抚场景。',
  ),
  TtsVoiceOption(
    voiceType: 101004,
    name: '智云',
    category: '成熟男声',
    description: '沉稳清楚，适合说明和指令反馈。',
  ),
  TtsVoiceOption(
    voiceType: 101006,
    name: '智言',
    category: '厚重男声',
    description: '低沉有力，适合正式播报。',
  ),
];

const int defaultTtsVoiceType = 101028;

TtsVoiceOption ttsVoiceOptionForType(int voiceType) {
  for (final option in ttsVoiceOptions) {
    if (option.voiceType == voiceType) return option;
  }
  return ttsVoiceOptions.first;
}
