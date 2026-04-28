import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android：将 [AudioManager] 切到 VoIP 模式，使硬件 AEC 与
/// [MediaRecorder.AudioSource.VOICE_COMMUNICATION] 录音、语音类播放协同工作。
///
/// 须在打开使用 [MicStream.androidVoipEchoCapture] 的录音**之前**调用 [setConversationVoipEnabled](true)。
class AndroidVoipAudioRoute {
  AndroidVoipAudioRoute._();

  static final AndroidVoipAudioRoute instance = AndroidVoipAudioRoute._();

  static const MethodChannel _channel =
      MethodChannel('com.dev.voicegpt/voip_audio');

  bool _lastApplied = false;

  bool get isVoipRouteEnabled => _lastApplied;

  /// [speakerphone]: 外放时多数机型需 true 才能把下行纳入 AEC 参考（具体因设备而异）。
  Future<void> setConversationVoipEnabled(
    bool enabled, {
    bool speakerphone = true,
    String debugTag = '',
  }) async {
    if (!Platform.isAndroid) {
      debugPrint(
          '[VoipAudioRoute${debugTag.isEmpty ? '' : ':$debugTag'}] skip (not Android)');
      return;
    }
    try {
      debugPrint(
          '[VoipAudioRoute${debugTag.isEmpty ? '' : ':$debugTag'}] '
          'invoke setConversationVoipEnabled enabled=$enabled speaker=$speakerphone '
          '(was $_lastApplied)');
      await _channel.invokeMethod<void>('setConversationVoipEnabled', {
        'enabled': enabled,
        'speakerphone': speakerphone,
        'tag': debugTag,
      });
      _lastApplied = enabled;
      debugPrint(
          '[VoipAudioRoute${debugTag.isEmpty ? '' : ':$debugTag'}] native done, _lastApplied=$_lastApplied');
    } catch (e, st) {
      debugPrint('[VoipAudioRoute] ERROR: $e\n$st');
    }
  }
}
