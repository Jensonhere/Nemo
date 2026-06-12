import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicegpt/core/storage/app_database.dart';
import 'package:voicegpt/core/models/conversation_history_turn.dart';
import 'package:voicegpt/core/models/private_agent_profile.dart';
import 'package:voicegpt/core/models/tts_voice_option.dart';

/// 本地偏好管理器。
///
/// 设置项仍在 SharedPreferences；账号、私人智能体、对话历史已迁到 SQLite。
class PreferenceManager {
  static final PreferenceManager _instance = PreferenceManager._internal();
  factory PreferenceManager() => _instance;
  PreferenceManager._internal();

  late SharedPreferences _prefs;

  // === storage keys ===
  static const String _themeMode = 'theme_mode';
  static const String _animationStyle = 'animation_style';

  static const String _ttsEnabled = 'tts_enabled';
  static const String _ttsSpeed = 'tts_speed';
  static const String _ttsVolume = 'tts_volume';
  static const String _ttsVoiceType = 'tts_voice_type';
  static const String _wakeWordEnabled = 'wake_word_enabled';

  static const String _conversationTimeout = 'conversation_timeout';
  static const String _autoStartListening = 'auto_start_listening';

  static const String _gestureRecognitionEnabled =
      'gesture_recognition_enabled';
  static const String _emotionRecognitionEnabled =
      'emotion_recognition_enabled';
  static const String _environmentMonitoringEnabled =
      'environment_monitoring_enabled';

  static const String _robotName = 'robot_name';
  static const String _robotPersonality = 'robot_personality';

  // ========== 初始化 ==========
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ========== 基础偏好 ==========
  Future<void> setThemeMode(String value) async {
    await _prefs.setString(_themeMode, value);
  }

  String getThemeMode() => _prefs.getString(_themeMode) ?? 'dark';

  Future<void> setAnimationStyle(String value) async {
    await _prefs.setString(_animationStyle, value);
  }

  String getAnimationStyle() => _prefs.getString(_animationStyle) ?? 'default';

  // ========== 语音设置 ==========
  Future<void> setTtsEnabled(bool value) async {
    await _prefs.setBool(_ttsEnabled, value);
  }

  bool getTtsEnabled() => _prefs.getBool(_ttsEnabled) ?? true;

  Future<void> setTtsSpeed(double value) async {
    await _prefs.setDouble(_ttsSpeed, value);
  }

  double getTtsSpeed() => _prefs.getDouble(_ttsSpeed) ?? 0.0;

  Future<void> setTtsVolume(double value) async {
    await _prefs.setDouble(_ttsVolume, value);
  }

  double getTtsVolume() => _prefs.getDouble(_ttsVolume) ?? 1.0;

  Future<void> setTtsVoiceType(int value) async {
    await _prefs.setInt(_ttsVoiceType, value);
  }

  int getTtsVoiceType() => _prefs.getInt(_ttsVoiceType) ?? defaultTtsVoiceType;

  TtsVoiceOption getTtsVoiceOption() =>
      ttsVoiceOptionForType(getTtsVoiceType());

  Future<void> setWakeWordEnabled(bool value) async {
    await _prefs.setBool(_wakeWordEnabled, value);
  }

  bool getWakeWordEnabled() => _prefs.getBool(_wakeWordEnabled) ?? true;

  // ========== 对话设置 ==========
  Future<void> setConversationTimeout(int seconds) async {
    await _prefs.setInt(_conversationTimeout, seconds);
  }

  int getConversationTimeout() => _prefs.getInt(_conversationTimeout) ?? 12;

  Future<void> setAutoStartListening(bool value) async {
    await _prefs.setBool(_autoStartListening, value);
  }

  bool getAutoStartListening() => _prefs.getBool(_autoStartListening) ?? true;

  // ========== 功能开关 ==========
  Future<void> setGestureRecognitionEnabled(bool value) async {
    await _prefs.setBool(_gestureRecognitionEnabled, value);
  }

  bool getGestureRecognitionEnabled() =>
      _prefs.getBool(_gestureRecognitionEnabled) ?? true;

  Future<void> setEmotionRecognitionEnabled(bool value) async {
    await _prefs.setBool(_emotionRecognitionEnabled, value);
  }

  bool getEmotionRecognitionEnabled() =>
      _prefs.getBool(_emotionRecognitionEnabled) ?? true;

  Future<void> setEnvironmentMonitoringEnabled(bool value) async {
    await _prefs.setBool(_environmentMonitoringEnabled, value);
  }

  bool getEnvironmentMonitoringEnabled() =>
      _prefs.getBool(_environmentMonitoringEnabled) ?? true;

  // ========== 机器人设置 ==========
  Future<void> setRobotName(String value) async {
    await _prefs.setString(_robotName, value);
  }

  String getRobotName() => _prefs.getString(_robotName) ?? '小航';

  Future<void> setRobotPersonality(String value) async {
    await _prefs.setString(_robotPersonality, value);
  }

  String getRobotPersonality() =>
      _prefs.getString(_robotPersonality) ?? 'friendly';

  // ========== 登录状态（SQLite） ==========
  Future<void> setUserId(String value) async {
    await AppDatabase.instance
        .setActiveUser(value.trim().isEmpty ? null : value);
  }

  String getUserId() => '';

  Future<void> setAuthUser(String jsonValue) async {
    // 账号数据已迁移到 SQLite；保留方法避免旧调用崩溃。
  }

  String getAuthUser() => '';

  Future<void> clearAuthUser() async {
    await AppDatabase.instance.setActiveUser(null);
  }

  // ========== 私人智能体配置（SQLite） ==========
  Future<PrivateAgentProfile?> getPrivateAgentProfileModel(
      String userId) async {
    return AppDatabase.instance.getPrivateAgentProfile(userId);
  }

  Future<bool> setPrivateAgentProfileModel(PrivateAgentProfile profile) async {
    return AppDatabase.instance.upsertPrivateAgentProfile(profile);
  }

  // ========== 对话历史（SQLite） ==========
  Future<List<ConversationHistoryTurn>> getConversationHistory(String userId) {
    return AppDatabase.instance.getConversationHistory(userId);
  }

  Future<void> addConversationHistoryTurn(
    String userId,
    ConversationHistoryTurn turn, {
    int maxTurns = 80,
  }) async {
    await AppDatabase.instance.addConversationHistoryTurn(
      userId,
      turn,
      maxTurns: maxTurns,
    );
  }

  Future<void> clearConversationHistory(String userId) async {
    await AppDatabase.instance.clearConversationHistory(userId);
  }
}
