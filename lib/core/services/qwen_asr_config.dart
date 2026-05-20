/// 通义 / Qwen 流式 ASR 服务地址。
/// 默认使用公网 HTTPS，可通过 --dart-define 覆盖。
class QwenAsrConfig {
  QwenAsrConfig._();

  /// 业务接口基地址（/healthz、/api/start、/api/chunk、/api/finish）。
  static const String defaultBaseUrl = 'https://a40954.xhang.buaa.edu.cn:52811';

  /// 文档中的 WebSocket ASR 地址（当前客户端走 HTTP 分块接口，预留给后续直连 WS 场景）。
  static const String defaultWsUrl = 'wss://a40954.xhang.buaa.edu.cn:52811/ws/asr';

  static String get baseUrl {
    const fromEnv = String.fromEnvironment(
      'QWEN_ASR_BASE_URL',
      defaultValue: '',
    );
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return defaultBaseUrl;
  }

  static String get wsUrl {
    const fromEnv = String.fromEnvironment(
      'QWEN_ASR_WS_URL',
      defaultValue: '',
    );
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return defaultWsUrl;
  }
}
