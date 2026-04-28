import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mic_stream/mic_stream.dart';
import 'package:voicegpt/core/services/qwen_cloud_asr_client.dart';

/// 使用麦克风按 0.5s PCM 块调用 Qwen 流式 ASR；静音结束句子时 [onUtteranceFinal]。
///
/// 连续对话「边播边听」：在 [isTtsPlaying] 为 true 时于本路 PCM 上做能量 VAD，检测到持续人声则
/// 触发 [onSpeechDuringTtsBargeIn]（由上层停 TTS），同一条麦克风流继续送 ASR，减少切麦丢字。
class QwenStreamingAsrRecorder {
  QwenStreamingAsrRecorder({
    required this.client,
    required this.onPartialText,
    required this.onUtteranceFinal,
    this.androidVoipEchoCapture = false,
    this.isTtsPlaying,
    this.onSpeechDuringTtsBargeIn,
  });

  final QwenCloudAsrClient client;
  final void Function(String text) onPartialText;
  final void Function(String text) onUtteranceFinal;
  final bool androidVoipEchoCapture;

  /// 连续对话内机器人 TTS 是否正在播放（用于同麦打断检测）。
  final bool Function()? isTtsPlaying;

  /// TTS 播放中检测到用户抢话时回调（应异步停 TTS，勿在 PCM 线程内阻塞）。
  final void Function()? onSpeechDuringTtsBargeIn;

  static const int sampleRate = 16000;
  /// 0.5s × 16000 × 2 bytes
  static const int chunkBytes = 16000;

  static const double _rmsSpeech = 900;
  static const double _rmsSilence = 450;
  static const int _silenceEndMs = 1300;
  static const int _minSpeechBeforeEndMs = 350;
  static const int _maxListenMs = 45000;
  // 轻量前端增强：近场低音量时抬升语音能量（不依赖 native 音频特效）
  static const double _targetRms = 2200;
  static const double _maxAutoGain = 3.2;
  static const int _peakClipGuard = 30000;

  /// TTS 时段打断：略高于普通起说阈值，依赖 VoIP+AEC 压低扬声器串音；误触时可略调高。
  static const double _rmsDuplexBargeIn = 1350;
  static const int _duplexBargeNeedMs = 240;
  static const int _duplexBargeWarmupMs = 450;
  static const int _duplexBargeCooldownMs = 900;

  int _duplexLoudMs = 0;
  DateTime? _duplexTtsSince;
  DateTime? _duplexLastFire;

  String? _sessionId;
  StreamSubscription<Uint8List>? _micSub;
  final List<int> _buf = <int>[];

  bool _emittedFinal = false;
  bool _speechSeen = false;
  int _speechMs = 0;
  int _silenceMs = 0;
  int _totalMs = 0;

  /// 串行执行 flush / 结束，避免 chunk 与 finish 并发
  Future<void> _asyncTail = Future<void>.value();

  Future<void> start() async {
    if (_micSub != null) return;

    _sessionId = await client.startSession();
    _emittedFinal = false;
    _speechSeen = false;
    _speechMs = 0;
    _silenceMs = 0;
    _totalMs = 0;
    _buf.clear();
    _duplexLoudMs = 0;
    _duplexTtsSince = null;
    _duplexLastFire = null;

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
      throw StateError('无法打开麦克风流');
    }

    _micSub = stream.listen(
      _onPcm,
      onError: (Object e, StackTrace st) {
        print('❌ Qwen ASR 麦克风流错误: $e\n$st');
      },
      cancelOnError: false,
    );
  }

  void _onPcm(Uint8List data) {
    if (_sessionId == null || _emittedFinal) return;

    final n = data.length;
    if (n < 2) return;
    final enhanced = _enhancePcm16Le(data);

    final ms = (enhanced.length ~/ 2) * 1000 ~/ sampleRate;
    _totalMs += ms;

    final rms = _rmsInt16Le(enhanced);
    _tickDuplexTtsBargeVad(rms, ms);

    if (rms >= _rmsSpeech) {
      _speechSeen = true;
      _speechMs += ms;
      _silenceMs = 0;
    } else if (rms <= _rmsSilence) {
      _silenceMs += ms;
    } else {
      _silenceMs = 0;
    }

    _buf.addAll(enhanced);

    final shouldEnd = _speechSeen &&
        _speechMs >= _minSpeechBeforeEndMs &&
        _silenceMs >= _silenceEndMs;
    final hitMax = _totalMs >= _maxListenMs;

    _asyncTail = _asyncTail
        .then((_) => _flushChunksIfNeeded())
        .then((_) {
          if (_emittedFinal) return Future<void>.value();
          if (shouldEnd || hitMax) {
            return _finishUtterance();
          }
          return Future<void>.value();
        })
        .catchError((Object e, StackTrace st) {
          print('❌ Qwen ASR 异步处理: $e\n$st');
        });
  }

  void _tickDuplexTtsBargeVad(double rms, int frameMs) {
    final cb = onSpeechDuringTtsBargeIn;
    if (cb == null) return;

    final ttsOn = isTtsPlaying?.call() ?? false;
    if (!ttsOn) {
      _duplexLoudMs = 0;
      _duplexTtsSince = null;
      return;
    }

    if (_duplexTtsSince == null) {
      _duplexTtsSince = DateTime.now();
    }
    if (DateTime.now().difference(_duplexTtsSince!).inMilliseconds <
        _duplexBargeWarmupMs) {
      return;
    }
    final last = _duplexLastFire;
    if (last != null &&
        DateTime.now().difference(last).inMilliseconds < _duplexBargeCooldownMs) {
      return;
    }

    if (rms >= _rmsDuplexBargeIn) {
      _duplexLoudMs += frameMs;
    } else {
      _duplexLoudMs = (_duplexLoudMs - (frameMs >> 1)).clamp(0, 1 << 30);
    }

    if (_duplexLoudMs >= _duplexBargeNeedMs) {
      _duplexLoudMs = 0;
      _duplexLastFire = DateTime.now();
      scheduleMicrotask(cb);
    }
  }

  /// TTS 被同麦 VAD 打断后，重置句尾判定，便于继续收本轮用户后半句。
  void resetSegmentAfterTtsBargeIn() {
    _speechSeen = false;
    _speechMs = 0;
    _silenceMs = 0;
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

  /// 自适应增益 + 峰值保护，改善“距离近但输入偏小/偏闷”场景。
  Uint8List _enhancePcm16Le(Uint8List src) {
    final rms = _rmsInt16Le(src);
    if (rms <= 1) return src;

    var gain = _targetRms / rms;
    if (gain < 1.0) gain = 1.0;
    if (gain > _maxAutoGain) gain = _maxAutoGain;
    if (gain <= 1.05) return src; // 已足够响时不处理

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

  Future<void> _flushChunksIfNeeded() async {
    final sid = _sessionId;
    if (sid == null || _emittedFinal) return;

    while (_buf.length >= chunkBytes && !_emittedFinal) {
      final chunk = Uint8List.fromList(_buf.sublist(0, chunkBytes));
      _buf.removeRange(0, chunkBytes);
      try {
        final map = await client.sendChunk(sid, chunk);
        final text = map['text']?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          onPartialText(text);
        }
        final isFinal = map['is_final'] == true;
        if (isFinal && !_emittedFinal) {
          await _finishUtterance();
          return;
        }
      } catch (e, st) {
        print('❌ Qwen ASR chunk 失败: $e\n$st');
        await _abortMicOnly();
        return;
      }
    }
  }

  Future<void> _finishUtterance() async {
    if (_emittedFinal) return;
    _emittedFinal = true;

    final sid = _sessionId;
    _sessionId = null;

    await _micSub?.cancel();
    _micSub = null;

    if (sid == null) return;

    try {
      if (_buf.isNotEmpty) {
        final rest = Uint8List.fromList(_buf);
        _buf.clear();
        try {
          final map = await client.sendChunk(sid, rest);
          final t = map['text']?.toString().trim() ?? '';
          if (t.isNotEmpty) onPartialText(t);
        } catch (e) {
          print('⚠️ Qwen ASR 尾块上传: $e');
        }
      } else {
        _buf.clear();
      }

      final fin = await client.finishSession(sid);
      final text = fin['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        onUtteranceFinal(text);
      }
    } catch (e, st) {
      print('❌ Qwen ASR finish 失败: $e\n$st');
    }
  }

  /// 外部停止（超时退出对话等）：结束会话，不触发 [onUtteranceFinal]。
  Future<void> stopWithoutSubmit() async {
    if (_emittedFinal) {
      await _micSub?.cancel();
      _micSub = null;
      return;
    }
    _emittedFinal = true;
    final sid = _sessionId;
    _sessionId = null;
    await _micSub?.cancel();
    _micSub = null;
    _buf.clear();
    if (sid != null) {
      try {
        await client.finishSession(sid);
      } catch (_) {}
    }
  }

  Future<void> _abortMicOnly() async {
    _emittedFinal = true;
    _sessionId = null;
    await _micSub?.cancel();
    _micSub = null;
    _buf.clear();
  }
}
