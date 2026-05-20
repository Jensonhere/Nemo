/// VA 情绪服务地址配置。
///
/// 默认值使用公网可访问的 VA 服务地址，必要时仍可通过
/// `--dart-define=VA_BASE_URL=...` 和 `--dart-define=VA_API_KEY=...` 覆盖。
class VaServiceConfig {
  VaServiceConfig._();

  static const String defaultBaseUrl = 'https://226bee.xhang.buaa.edu.cn:52811';
  static const String defaultApiKey = '';

  static String get baseUrl {
    const fromEnv = String.fromEnvironment(
      'VA_BASE_URL',
      defaultValue: '',
    );
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return defaultBaseUrl;
  }

  static String get apiKey {
    const fromEnv = String.fromEnvironment(
      'VA_API_KEY',
      defaultValue: '',
    );
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return defaultApiKey;
  }
}
