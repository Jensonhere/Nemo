import 'package:audioplayers/audioplayers.dart';

/// 播放本地主人声纹 WAV 试听。
class SpeakerEnrollmentAudioPlayer {
  SpeakerEnrollmentAudioPlayer._();
  static final SpeakerEnrollmentAudioPlayer instance =
      SpeakerEnrollmentAudioPlayer._();

  final AudioPlayer _player = AudioPlayer();
  String? _playingId;

  String? get playingId => _playingId;

  Future<void> play(String sampleId, String wavAbsolutePath) async {
    await stop();
    _playingId = sampleId;
    await _player.play(DeviceFileSource(wavAbsolutePath));
    await _player.onPlayerComplete.first;
    _playingId = null;
  }

  Future<void> stop() async {
    _playingId = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
