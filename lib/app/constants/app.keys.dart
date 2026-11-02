class AppKeys {
  static const String apiKey = String.fromEnvironment(
    'OPENAI_API_KEY',
    defaultValue: '',
  );
  static const String apiKey2 = String.fromEnvironment(
    'OPENAI_API_KEY_2',
    defaultValue: '',
  );

  /// 高德开放平台 Web 服务 Key（天气、逆地理编码）。
  static const String amapWebServiceKey = String.fromEnvironment(
    'AMAP_WEB_SERVICE_KEY',
    defaultValue: '',
  );
}
