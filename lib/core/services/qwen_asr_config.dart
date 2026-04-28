/// 通义 / Qwen 流式 ASR 服务（内网部署时可改此常量或通过 --dart-define 覆盖）。
class QwenAsrConfig {
  QwenAsrConfig._();

  /// 与文档一致：`http://10.70.247.24:8015`
  static const String defaultBaseUrl = 'http://10.70.247.24:8015';

  static String get baseUrl {
    const fromEnv = String.fromEnvironment(
      'QWEN_ASR_BASE_URL',
      defaultValue: '',
    );
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return defaultBaseUrl;
  }
}
