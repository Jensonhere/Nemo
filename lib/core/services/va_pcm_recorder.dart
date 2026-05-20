import 'dart:async';
import 'dart:typed_data';

import 'package:mic_stream/mic_stream.dart';

/// 在 VOSK 回退链路下使用的独立 VA PCM 录音器。
class VaPcmRecorder {
  VaPcmRecorder({
    required this.onChunk,
    this.androidVoipEchoCapture = false,
  });

  final FutureOr<void> Function(Uint8List chunk) onChunk;
  final bool androidVoipEchoCapture;

  static const int sampleRate = 16000;
  static const int chunkBytes = 16000;

  StreamSubscription<Uint8List>? _micSub;
  final List<int> _buf = <int>[];
  Future<void> _tail = Future<void>.value();
  bool _running = false;
  int _chunkCount = 0;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _chunkCount = 0;
    _buf.clear();

    final stream = await MicStream.microphone(
      sampleRate: sampleRate,
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,
      audioSource: androidVoipEchoCapture
          ? AudioSource.VOICE_COMMUNICATION
          : AudioSource.VOICE_RECOGNITION,
      androidVoipEchoCapture: androidVoipEchoCapture,
    );
    if (stream == null) {
      _running = false;
      throw StateError('无法打开 VA PCM 麦克风流');
    }

    print('🎧 [VA][VOSK] 独立 PCM 录音器启动');

    _micSub = stream.listen(
      _onPcm,
      onError: (Object e, StackTrace st) {
        print('❌ [VA][VOSK] 麦克风流错误: $e\n$st');
      },
      cancelOnError: false,
    );
  }

  void _onPcm(Uint8List data) {
    if (!_running || data.length < 2) return;
    _buf.addAll(data);
    _tail = _tail.then((_) => _flushChunksIfNeeded()).catchError(
      (Object e, StackTrace st) {
        print('❌ [VA][VOSK] PCM flush 异常: $e\n$st');
      },
    );
  }

  Future<void> _flushChunksIfNeeded() async {
    while (_buf.length >= chunkBytes && _running) {
      final chunk = Uint8List.fromList(_buf.sublist(0, chunkBytes));
      _buf.removeRange(0, chunkBytes);
      _chunkCount += 1;
      print('🎧 [VA][VOSK] 发送 chunk #$_chunkCount bytes=${chunk.length}');
      await onChunk(chunk);
    }
  }

  Future<void> stop({bool flushRemainder = true}) async {
    if (!_running) return;
    _running = false;
    await _tail;
    if (flushRemainder && _buf.isNotEmpty) {
      final rest = Uint8List.fromList(_buf);
      _buf.clear();
      print('🎧 [VA][VOSK] 发送尾块 bytes=${rest.length}');
      await onChunk(rest);
    } else {
      _buf.clear();
    }
    await _micSub?.cancel();
    _micSub = null;
    print('🛑 [VA][VOSK] 独立 PCM 录音器停止');
  }
}
