import 'package:voicegpt/core/services/tencent_streaming_text_tts_service.dart';
import 'package:voicegpt/core/services/voice_tts_service.dart';

/// 仅使用腾讯云 TTS（流式或 HTTP，由凭证决定）。
///
/// 本地 Kokoro / Sherpa 离线 TTS 已移除，以减小仓库与安装包体积。
class VoiceTtsServiceFactory {
  VoiceTtsServiceFactory._();

  /// [tencentVoiceType]：腾讯云语音合成音色 ID（控制台文档）。
  static Future<VoiceTtsService> create({
    required String tencentSecretId,
    required String tencentSecretKey,
    int tencentAppId = 0,
    int tencentVoiceType = 101028,
  }) async {
    print('ℹ️ TTS 使用腾讯云（VoiceTtsServiceFactory）');
    final cloud = (tencentAppId > 0 &&
            tencentSecretId.trim().isNotEmpty &&
            tencentSecretKey.trim().isNotEmpty)
        ? TencentStreamingTextTtsService(
            secretId: tencentSecretId,
            secretKey: tencentSecretKey,
            appId: tencentAppId,
            voiceType: tencentVoiceType,
            codec: 'mp3',
          )
        : TencentVoiceTtsService(
            secretId: tencentSecretId,
            secretKey: tencentSecretKey,
            voiceType: tencentVoiceType,
          );
    await cloud.prepare();
    return cloud;
  }
}
