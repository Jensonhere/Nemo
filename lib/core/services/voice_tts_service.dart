import 'dart:async';
import 'dart:ui';

import 'package:voicegpt/core/services/tencent_tts_service.dart';

/// 对话 / 环境监测共用的 TTS 抽象（腾讯云等）
abstract class VoiceTtsService {
  /// 是否为本机合成后端；`false` 表示腾讯云等云端实现。
  bool get isLocalBackend;

  /// 启动前准备（云端：配置密钥；本地：加载 ONNX）
  Future<void> prepare();

  Future<void> speak(String text, {VoidCallback? onPlaybackStarted});

  Future<void> stop();

  Future<void> release();

  /// 是否支持“增量输入文本”的流式合成（用于 LLM token 级输出）。
  bool get supportsInputStreaming => false;

  /// 开始一轮输入流（仅 supportsInputStreaming=true 的实现会真正启用）。
  Future<void> startInputStream({VoidCallback? onPlaybackStarted}) async {
    throw UnsupportedError('Current TTS backend does not support input stream');
  }

  /// 推送一段增量文本到当前输入流。
  Future<void> pushInputText(String text) async {
    throw UnsupportedError('Current TTS backend does not support input stream');
  }

  /// 结束当前输入流并等待本轮播报完成。
  Future<void> finishInputStream() async {
    throw UnsupportedError('Current TTS backend does not support input stream');
  }

  VoidCallback? get onCompleted;

  set onCompleted(VoidCallback? value);
}

/// 仍使用腾讯云合成（与原先 [TencentTtsService] 行为一致）。
///
/// 声线：修改 [voiceType]（及可选 [voiceLanguage]）为腾讯云控制台提供的音色编号。
class TencentVoiceTtsService extends VoiceTtsService {
  TencentVoiceTtsService({
    required this.secretId,
    required this.secretKey,
    this.voiceType = 101028,
    this.voiceLanguage = 1,
    this.voiceSpeed = 0,
    this.voiceVolume = 0,
    this.codec = 'mp3',
  });

  final String secretId;
  final String secretKey;
  final int voiceType;
  final int voiceLanguage;
  final double voiceSpeed;
  final double voiceVolume;
  final String codec;

  final TencentTtsService _inner = TencentTtsService();

  @override
  bool get isLocalBackend => false;

  @override
  Future<void> prepare() async {
    _inner.init(
      secretId: secretId,
      secretKey: secretKey,
      voiceType: voiceType,
      voiceLanguage: voiceLanguage,
      voiceSpeed: voiceSpeed,
      voiceVolume: voiceVolume,
      codec: codec,
    );
  }

  @override
  Future<void> speak(String text, {VoidCallback? onPlaybackStarted}) =>
      _inner.speak(text, onPlaybackStarted: onPlaybackStarted);

  @override
  Future<void> stop() => _inner.stop();

  @override
  Future<void> release() => _inner.release();

  @override
  VoidCallback? get onCompleted => _inner.onCompleted;

  @override
  set onCompleted(VoidCallback? value) => _inner.onCompleted = value;
}
