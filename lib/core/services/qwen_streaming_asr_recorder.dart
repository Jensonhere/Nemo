import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mic_stream/mic_stream.dart';
import 'package:voicegpt/core/debug/conversation_flow_tracer.dart';
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
    this.onPcmChunkReadyForSidecar,
    this.androidVoipEchoCapture = false,
    this.isTtsPlaying,
    this.onSpeechDuringTtsBargeIn,
    this.onSpeechActivity,
    this.silenceAutoFinalize = true,
    this.maxListenMsOverride,
  });

  final QwenCloudAsrClient client;
  final void Function(String text) onPartialText;
  final void Function(String text) onUtteranceFinal;
  final void Function(Uint8List chunk)? onPcmChunkReadyForSidecar;
  final bool androidVoipEchoCapture;

  /// 连续对话内机器人 TTS 是否正在播放（用于同麦打断检测）。
  final bool Function()? isTtsPlaying;

  /// TTS 播放中检测到用户抢话时回调（应异步停 TTS，勿在 PCM 线程内阻塞）。
  final void Function()? onSpeechDuringTtsBargeIn;

  /// 本轮听写首次检测到有效人声（能量 VAD），用于暂停空闲超时。
  final void Function()? onSpeechActivity;

  /// 为 false 时不在静音后自动定稿，仅 [finalizeUtteranceForPushToTalk] 松手定稿（多人按住说话）。
  final bool silenceAutoFinalize;

  /// 非空则替代 [_maxListenMs] 作为超长兜底（秒级按住仍须能结束）。
  final int? maxListenMsOverride;

  static const int sampleRate = 16000;

  /// 0.5s × 16000 × 2 bytes
  static const int chunkBytes = 16000;

  static const double _rmsSpeech = 900;
  static const double _rmsSilence = 450;
  static const int _silenceEndMs = 1300;
  static const int _minSpeechBeforeEndMs = 350;

  /// 必须 **小于** 连续对话 30s 超时，否则 VAD 迟迟不定稿时会先被会话超时踢出，用户体感「说了不回复」。
  static const int _maxListenMs = 22000;
  // 轻量前端增强：近场低音量时抬升语音能量（不依赖 native 音频特效）
  static const double _targetRms = 2200;
  static const double _maxAutoGain = 3.2;
  static const int _peakClipGuard = 30000;

  /// TTS 时段打断：略高于普通起说阈值，依赖 VoIP+AEC 压低扬声器串音；误触时可略调高。
  static const double _rmsDuplexBargeIn = 1350;
  static const int _duplexBargeNeedMs = 240;
  static const int _duplexBargeWarmupMs = 450;
  static const int _duplexBargeCooldownMs = 900;

  /// 近 2s PCM 环形缓冲，供 TTS 打断声纹比对。
  static const int _bargeInRingMaxSamples = 32000;
  final List<double> _bargeInRing = <double>[];

  /// 本轮听写完整 PCM（最多约 10s），供主人模式聆听定稿声纹比对。
  static const int _utteranceMaxSamples = 160000;
  final List<double> _utterancePcm = <double>[];

  int _duplexLoudMs = 0;
  DateTime? _duplexTtsSince;
  DateTime? _duplexLastFire;

  String? _sessionId;
  StreamSubscription<Uint8List>? _micSub;
  final List<int> _buf = <int>[];

  bool _emittedFinal = false;
  bool _speechSeen = false;
  bool _speechActivityNotified = false;
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
    _speechActivityNotified = false;
    _speechMs = 0;
    _silenceMs = 0;
    _totalMs = 0;
    _buf.clear();
    _duplexLoudMs = 0;
    _duplexTtsSince = null;
    _duplexLastFire = null;
    _bargeInRing.clear();
    _utterancePcm.clear();

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
    onPcmChunkReadyForSidecar?.call(Uint8List.fromList(enhanced));

    final ms = (enhanced.length ~/ 2) * 1000 ~/ sampleRate;
    _totalMs += ms;

    final rms = _rmsInt16Le(enhanced);
    _appendBargeInRing(enhanced);
    _appendUtterancePcm(enhanced);
    _tickDuplexTtsBargeVad(rms, ms);

    if (rms >= _rmsSpeech) {
      if (!_speechActivityNotified) {
        _speechActivityNotified = true;
        final activityCb = onSpeechActivity;
        if (activityCb != null) {
          scheduleMicrotask(activityCb);
        }
      }
      _speechSeen = true;
      _speechMs += ms;
      _silenceMs = 0;
    } else if (rms <= _rmsSilence) {
      _silenceMs += ms;
    } else {
      // 灰区 (_rmsSilence, _rmsSpeech)：与强静音一样按整段 ms 计入句尾静音，避免底噪长期卡在中间带导致永不定稿。
      _silenceMs += ms;
    }

    _buf.addAll(enhanced);

    final maxCap = maxListenMsOverride ?? _maxListenMs;
    final ttsOn = isTtsPlaying?.call() ?? false;
    final shouldEnd = silenceAutoFinalize &&
        !ttsOn &&
        _speechSeen &&
        _speechMs >= _minSpeechBeforeEndMs &&
        _silenceMs >= _silenceEndMs;
    final hitMax = _totalMs >= maxCap;

    _asyncTail = _asyncTail.then((_) => _flushChunksIfNeeded()).then((_) {
      if (_emittedFinal) return Future<void>.value();
      if (shouldEnd || hitMax) {
        return _finishUtterance(
          forcedByMaxListen: hitMax && !shouldEnd,
        );
      }
      return Future<void>.value();
    }).catchError((Object e, StackTrace st) {
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
        DateTime.now().difference(last).inMilliseconds <
            _duplexBargeCooldownMs) {
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
    _speechActivityNotified = false;
    _speechMs = 0;
    _silenceMs = 0;
  }

  /// 声纹打断：取近端 PCM 快照（float32 16kHz）。
  Float32List snapshotBargeInRingForVerify() {
    return Float32List.fromList(_bargeInRing);
  }

  /// 聆听定稿：取本轮完整听写 PCM（优先于 2s 环缓冲做声纹比对）。
  Float32List snapshotUtterancePcmForVerify() {
    return Float32List.fromList(_utterancePcm);
  }

  void _appendUtterancePcm(Uint8List pcm16) {
    final bd = pcm16.buffer.asByteData(pcm16.offsetInBytes, pcm16.length);
    final pairs = pcm16.length ~/ 2;
    for (var i = 0; i < pairs; i++) {
      _utterancePcm.add(bd.getInt16(i * 2, Endian.little) / 32768.0);
    }
    final overflow = _utterancePcm.length - _utteranceMaxSamples;
    if (overflow > 0) {
      _utterancePcm.removeRange(0, overflow);
    }
  }

  void _appendBargeInRing(Uint8List pcm16) {
    final bd = pcm16.buffer.asByteData(pcm16.offsetInBytes, pcm16.length);
    final pairs = pcm16.length ~/ 2;
    for (var i = 0; i < pairs; i++) {
      _bargeInRing.add(bd.getInt16(i * 2, Endian.little) / 32768.0);
    }
    final overflow = _bargeInRing.length - _bargeInRingMaxSamples;
    if (overflow > 0) {
      _bargeInRing.removeRange(0, overflow);
    }
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

  Future<void> _finishUtterance({bool forcedByMaxListen = false}) async {
    if (_emittedFinal) return;
    ConversationFlowTracer.asr(
      forcedByMaxListen
          ? 'qwen_asr_finish_BEGIN forcedMaxListen totalMs=$_totalMs cap=$_maxListenMs'
          : '_finishUtterance_begin',
    );
    _emittedFinal = true;

    final sid = _sessionId;
    _sessionId = null;

    await _micSub?.cancel();
    _micSub = null;

    // 必须通知上层「本轮听写已结束」，即使服务端 text 为空；否则外层仍认为 _isListening==true
    // 而麦克风流已取消，后续 startVoiceRecognition 会误判「已在运行」永远无法重开麦。
    if (sid == null) {
      onUtteranceFinal('');
      return;
    }

    var text = '';
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
      text = fin['text']?.toString().trim() ?? '';
    } catch (e, st) {
      print('❌ Qwen ASR finish 失败: $e\n$st');
      text = '';
    }
    ConversationFlowTracer.asr(
      '_finishUtterance_callback textLen=${text.length}',
    );
    onUtteranceFinal(text);
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

  /// 多人场景「按住说话」松手：不等待静音超时，串行 flush 后定稿并触发 [onUtteranceFinal]。
  Future<void> finalizeUtteranceForPushToTalk() async {
    _asyncTail = _asyncTail.then((_) async {
      if (_emittedFinal) return;
      await _flushChunksIfNeeded();
      if (!_emittedFinal) {
        await _finishUtterance();
      }
    });
    await _asyncTail;
  }

  Future<void> _abortMicOnly() async {
    ConversationFlowTracer.asr('_abortMicOnly chunk_error_mic_stopped');
    _emittedFinal = true;
    _sessionId = null;
    await _micSub?.cancel();
    _micSub = null;
    _buf.clear();
  }
}
