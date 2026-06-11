import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mic_stream/mic_stream.dart';

/// 声纹注册采音：最长 10s；说完后约 1.3s 相对静音即结束（非固定绝对阈值）。
class SpeakerEnrollmentRecorder {
  SpeakerEnrollmentRecorder({
    this.androidVoipEchoCapture = false,
    this.onProgress,
  });

  final bool androidVoipEchoCapture;

  /// 采音进度（用于 UI：已录时长 / 是否检测到说话 / 句尾静音累计）。
  final void Function({
    required int totalMs,
    required bool speechSeen,
    required int silenceMs,
    required double peakRms,
  })? onProgress;

  static const int sampleRate = 16000;
  static const int maxDurationMs = 10000;

  static const double _rmsSpeech = 650;
  static const double _rmsSilenceFloor = 280;
  static const int _silenceEndMs = 1300;
  static const int _minSpeechBeforeEndMs = 350;
  static const double _targetRms = 2200;
  static const double _maxAutoGain = 3.2;
  static const int _peakClipGuard = 30000;

  StreamSubscription<Uint8List>? _micSub;
  Timer? _maxTimer;
  final List<int> _pcmBytes = <int>[];
  bool _emittedFinal = false;
  bool _speechSeen = false;
  int _speechMs = 0;
  int _silenceMs = 0;
  int _totalMs = 0;
  double _peakRms = 0;
  Completer<Float32List?>? _done;

  Future<Float32List?> capture() async {
    if (_micSub != null) {
      await _abort();
    }
    _pcmBytes.clear();
    _emittedFinal = false;
    _speechSeen = false;
    _speechMs = 0;
    _silenceMs = 0;
    _totalMs = 0;
    _peakRms = 0;
    _done = Completer<Float32List?>();

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
      _done!.complete(null);
      return _done!.future;
    }

    _maxTimer = Timer(const Duration(milliseconds: maxDurationMs), () {
      if (!_emittedFinal) {
        print('🎤 [SpeakerEnroll] 达到 ${maxDurationMs}ms 上限，结束采录');
        _finish(_pcmToFloat32(), reason: 'max_duration');
      }
    });

    _micSub = stream.listen(
      _onPcm,
      onError: (_, __) => _finish(null, reason: 'mic_error'),
      cancelOnError: false,
    );

    return _done!.future;
  }

  Future<void> cancel() => _abort();

  void _onPcm(Uint8List data) {
    if (_emittedFinal || _done == null || _done!.isCompleted) return;
    if (data.length < 2) return;

    final enhanced = _enhancePcm16Le(data);
    final ms = (enhanced.length ~/ 2) * 1000 ~/ sampleRate;
    _totalMs += ms;

    final rms = _rmsInt16Le(enhanced);
    if (rms >= _rmsSpeech) {
      _speechSeen = true;
      _speechMs += ms;
      _silenceMs = 0;
      if (rms > _peakRms) _peakRms = rms;
    } else if (_speechSeen) {
      // 句尾：相对峰值回落即计静音（避免环境底噪一直高于固定阈值导致永不结束）
      final tailTh = math.max(_rmsSilenceFloor, _peakRms * 0.32);
      if (rms < tailTh) {
        _silenceMs += ms;
      } else {
        _silenceMs = math.max(0, _silenceMs - (ms ~/ 3));
      }
    }

    _pcmBytes.addAll(enhanced);

    onProgress?.call(
      totalMs: _totalMs,
      speechSeen: _speechSeen,
      silenceMs: _silenceMs,
      peakRms: _peakRms,
    );

    final vadEnd = _speechSeen &&
        _speechMs >= _minSpeechBeforeEndMs &&
        _silenceMs >= _silenceEndMs;
    if (vadEnd) {
      print(
        '🎤 [SpeakerEnroll] VAD 句尾结束 total=${_totalMs}ms '
        'speech=${_speechMs}ms silence=${_silenceMs}ms peak=${_peakRms.toStringAsFixed(0)}',
      );
      _finish(_pcmToFloat32(), reason: 'vad');
    }
  }

  void _finish(Float32List? samples, {String reason = ''}) {
    if (_emittedFinal) return;
    _emittedFinal = true;
    _maxTimer?.cancel();
    _maxTimer = null;
    unawaited(_micSub?.cancel());
    _micSub = null;
    if (_done != null && !_done!.isCompleted) {
      _done!.complete(samples);
    }
    if (reason.isNotEmpty) {
      print(
          '🎤 [SpeakerEnroll] 采录结束 reason=$reason samples=${samples?.length ?? 0}');
    }
  }

  Future<void> _abort() async {
    _emittedFinal = true;
    _maxTimer?.cancel();
    _maxTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    _pcmBytes.clear();
    if (_done != null && !_done!.isCompleted) {
      _done!.complete(null);
    }
    _done = null;
  }

  Float32List? _pcmToFloat32() {
    if (_pcmBytes.length < sampleRate ~/ 5) {
      return null;
    }
    final bd = Uint8List.fromList(_pcmBytes).buffer.asByteData();
    final pairs = _pcmBytes.length ~/ 2;
    final out = Float32List(pairs);
    for (var i = 0; i < pairs; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      out[i] = s / 32768.0;
    }
    return out;
  }

  Uint8List _enhancePcm16Le(Uint8List src) {
    final rms = _rmsInt16Le(src);
    if (rms <= 1) return src;

    var gain = _targetRms / rms;
    if (gain < 1.0) gain = 1.0;
    if (gain > _maxAutoGain) gain = _maxAutoGain;
    if (gain <= 1.05) return src;

    final out = Uint8List(src.length);
    final inBd = src.buffer.asByteData(src.offsetInBytes, src.length);
    final outBd = out.buffer.asByteData();
    final pairs = src.length ~/ 2;
    for (var i = 0; i < pairs; i++) {
      final s = inBd.getInt16(i * 2, Endian.little);
      var v = (s * gain).round();
      if (v > _peakClipGuard) v = _peakClipGuard;
      if (v < -_peakClipGuard) v = -_peakClipGuard;
      outBd.setInt16(i * 2, v, Endian.little);
    }
    return out;
  }

  double _rmsInt16Le(Uint8List bytes) {
    final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    var sum = 0.0;
    final pairs = bytes.length ~/ 2;
    if (pairs == 0) return 0;
    for (var i = 0; i < pairs; i++) {
      final s = bd.getInt16(i * 2, Endian.little).toDouble();
      sum += s * s;
    }
    return math.sqrt(sum / pairs);
  }
}
