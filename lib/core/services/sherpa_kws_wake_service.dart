import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:mic_stream/mic_stream.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 使用 sherpa-onnx KeywordSpotter 做离线唤醒（默认短语「你好小航」）。
///
/// 请将以下文件放到 [assetDir] 对应的应用资源目录（见 pubspec `assets/sherpa_kws/`）：
/// - encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx
/// - decoder-epoch-13-avg-2-chunk-16-left-64.onnx
/// - joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx
/// - tokens.txt
/// - keywords.txt（仓库已提供，与 sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20 配套）
///
/// 模型包下载：
/// https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2
class SherpaKwsWakeService {
  SherpaKwsWakeService({
    this.assetDir = 'assets/sherpa_kws/',
    this.onKeyword,
    this.onSpeechBargeIn,
  });

  final String assetDir;
  final void Function(String keyword)? onKeyword;

  /// TTS 期间：能量 VAD 检测到人声时回调，附带最近约 2s 环形缓冲 PCM（供声纹比对）。
  final void Function(Float32List recentPcm)? onSpeechBargeIn;

  /// Android：与 [AndroidVoipAudioRoute] + [MicStream.androidVoipEchoCapture] 协同启用硬件 AEC 采集。
  bool _androidVoipEchoCapture = false;

  sherpa.KeywordSpotter? _spotterMain;
  sherpa.OnlineStream? _streamMain;
  sherpa.KeywordSpotter? _spotterLow;
  sherpa.OnlineStream? _streamLow;
  StreamSubscription<Uint8List>? _micSub;
  int _micSampleRate = 16000;
  bool _running = false;
  bool _paused = false;
  String? _modelDir;
  Timer? _rmsLogTimer;

  // 双阈值：main 负责稳态，low 负责低音量/含糊发音补偿。
  static const double _kwsThresholdMain = 0.10;
  static const double _kwsThresholdLow = 0.065;
  static const Duration _emitCooldown = Duration(milliseconds: 850);
  DateTime? _lastKeywordEmitAt;

  // 运行时音量/噪声统计（用于自适应放行 low 阈值结果与诊断日志）
  double _rmsEma = 0.0;
  double _peakEma = 0.0;
  double _noiseFloorEma = 0.0;
  double _snrLike = 1.0;
  bool _lowGateOpen = false;
  int _mainHitCount = 0;
  int _lowHitCount = 0;

  // 激进 lowGate：优先提升“含着说/轻声快读”召回率（误触上升时可回调）
  static const double _lowGateRmsMax = 0.024;
  static const double _lowGateSnrMin = 1.20;
  static const double _lowGatePeakMin = 0.016;

  /// mic_stream Android 端为全局单例 AudioRecord；与 VOSK/TTS 交叠时须串行并留冷却，否则易出现 dead IAudioRecord / AudioTrackShared 崩溃。
  Future<void> _micOpChain = Future<void>.value();

  Future<T> _runMicSerialized<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _micOpChain = _micOpChain.then((_) async {
      try {
        if (!completer.isCompleted) {
          completer.complete(await fn());
        }
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      }
    });
    return completer.future;
  }

  // 过大会明显拉长「唤醒词命中->首句回复」时延；过小可能在个别机型出现麦克风争用。
  static const _androidMicReleaseDelay = Duration(milliseconds: 240);
  static const _androidMicOpenDelay = Duration(milliseconds: 120);

  /// TTS 插话：短时 RMS/峰值超过阈值即视为「有人在说话」（非固定词条）。
  bool _ttsBargeInVadEnabled = false;
  DateTime? _vadArmedAt;
  int _vadLoudRunSamples = 0;
  DateTime? _vadCooldownUntil;

  /// VoIP+AEC 下回声更低，阈值可略低；否则略高减轻误触。
  static const double _vadRmsThreshVoip = 0.030;
  static const double _vadRmsThreshDefault = 0.052;
  static const double _vadPeakFactor = 2.8;
  static const int _vadMinLoudMsVoip = 190;
  static const int _vadMinLoudMsDefault = 260;
  static const int _vadMinLoudMsVoiceprintVoip = 110;
  static const int _vadMinLoudMsVoiceprintDefault = 140;
  static const int _vadWarmupMs = 450;
  static const int _vadWarmupVoiceprintMs = 160;
  static const int _vadCooldownMs = 1100;
  static const int _vadCooldownRejectMs = 220;

  /// 为 true 时：VAD 触发后先走声纹比对，仅在 [completeBargeInAttempt] 成功后再长冷却。
  bool _deferBargeInCooldown = false;

  /// TTS 打断声纹比对用环形缓冲（16kHz float mono，约 2s）。
  static const int _bargeInRingMaxSamples = 32000;
  final List<double> _bargeInRing = <double>[];

  static const _encoder = 'encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx';
  static const _decoder = 'decoder-epoch-13-avg-2-chunk-16-left-64.onnx';
  static const _joiner = 'joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx';
  static const _tokens = 'tokens.txt';
  static const _keywords = 'keywords.txt';
  static const double _targetRmsInt16 = 4800.0;
  static const double _maxAutoGain = 3.0;
  static const int _peakClipGuard = 29000;

  bool get isReady =>
      _spotterMain != null &&
      _streamMain != null &&
      _spotterLow != null &&
      _streamLow != null &&
      _modelDir != null;

  bool get androidVoipEchoCapture => _androidVoipEchoCapture;

  void setAndroidVoipEchoCapture(bool enabled) {
    _androidVoipEchoCapture = enabled;
    print(
        '🎚️ [SherpaKws] setAndroidVoipEchoCapture=$enabled (next MicStream will ${_androidVoipEchoCapture ? "use VOICE_COMMUNICATION+voip flag" : "use DEFAULT"})');
  }

  /// 仅在「对话内、TTS、Sherpa 正在采音」时打开；关 VOSK / pause 时务必关闭以免待机误触。
  void setTtsBargeInVadEnabled(bool enabled) {
    _ttsBargeInVadEnabled = enabled;
    _vadArmedAt = enabled ? DateTime.now() : null;
    _vadLoudRunSamples = 0;
    _vadCooldownUntil = null;
    if (!enabled) {
      _bargeInRing.clear();
      _deferBargeInCooldown = false;
    }
    print(
        '🎚️ [SherpaKws] setTtsBargeInVadEnabled=$enabled (rmsThresh=${_vadRmsThreshold.toStringAsFixed(3)} minLoudMs=$_vadMinLoudMs)');
  }

  double get _vadRmsThreshold =>
      _androidVoipEchoCapture ? _vadRmsThreshVoip : _vadRmsThreshDefault;

  int get _vadMinLoudMs {
    if (_deferBargeInCooldown) {
      return _androidVoipEchoCapture
          ? _vadMinLoudMsVoiceprintVoip
          : _vadMinLoudMsVoiceprintDefault;
    }
    return _androidVoipEchoCapture ? _vadMinLoudMsVoip : _vadMinLoudMsDefault;
  }

  int get _vadWarmupMsEffective =>
      _deferBargeInCooldown ? _vadWarmupVoiceprintMs : _vadWarmupMs;

  /// 声纹打断模式：VAD 先触发，比对成功后再长冷却。
  void setDeferBargeInCooldown(bool enabled) {
    _deferBargeInCooldown = enabled;
    print('🎚️ [SherpaKws] deferBargeInCooldown=$enabled');
  }

  /// 供声纹比对循环拉取最新环形缓冲（勿在 PCM 回调线程长时间阻塞）。
  Float32List snapshotBargeInRingForVerify() => _snapshotBargeInRing();

  /// [interruptGranted] true → 长冷却；false → 短冷却便于同一句内再次尝试。
  void completeBargeInAttempt({required bool interruptGranted}) {
    final ms = interruptGranted ? _vadCooldownMs : _vadCooldownRejectMs;
    _vadCooldownUntil = DateTime.now().add(Duration(milliseconds: ms));
  }

  void _appendBargeInRing(Float32List samples) {
    if (!_ttsBargeInVadEnabled) return;
    _bargeInRing.addAll(samples);
    final overflow = _bargeInRing.length - _bargeInRingMaxSamples;
    if (overflow > 0) {
      _bargeInRing.removeRange(0, overflow);
    }
  }

  Float32List _snapshotBargeInRing() {
    return Float32List.fromList(_bargeInRing);
  }

  void _tickSpeechVad(Float32List samples) {
    if (!_ttsBargeInVadEnabled || onSpeechBargeIn == null) return;
    _appendBargeInRing(samples);
    final now = DateTime.now();
    if (_vadCooldownUntil != null && now.isBefore(_vadCooldownUntil!)) {
      return;
    }
    if (_vadArmedAt != null &&
        now.difference(_vadArmedAt!).inMilliseconds < _vadWarmupMsEffective) {
      return;
    }

    var sumSq = 0.0;
    var peak = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i];
      sumSq += v * v;
      final a = v < 0 ? -v : v;
      if (a > peak) peak = a;
    }
    final rms = math.sqrt(sumSq / samples.length);
    final th = _vadRmsThreshold;
    final loud = rms >= th || peak >= th * _vadPeakFactor;

    if (loud) {
      _vadLoudRunSamples += samples.length;
      final ms = (_vadLoudRunSamples * 1000) ~/ _micSampleRate;
      if (ms >= _vadMinLoudMs) {
        print(
            '🎤 [VAD打断] 检测持续人声 ~${ms}ms rms=${rms.toStringAsFixed(4)} peak=${peak.toStringAsFixed(4)} th=${th.toStringAsFixed(3)} deferCooldown=$_deferBargeInCooldown');
        _vadLoudRunSamples = 0;
        if (_deferBargeInCooldown) {
          // 声纹比对进行中：极短防抖，避免同帧重复；失败不锁 1.1s。
          _vadCooldownUntil = now.add(const Duration(milliseconds: 80));
        } else {
          _vadCooldownUntil = now.add(Duration(milliseconds: _vadCooldownMs));
        }
        onSpeechBargeIn!(_snapshotBargeInRing());
      }
    } else {
      _vadLoudRunSamples = (_vadLoudRunSamples >> 1);
    }
  }

  Future<String?> _copyKwsAssetsIfNeeded() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory('${doc.path}/sherpa_kws');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final Map<String, dynamic> manifestMap = json.decode(manifestContent);

    var copied = 0;
    for (final key in manifestMap.keys) {
      if (!key.startsWith(assetDir)) continue;
      final relative = key.substring(assetDir.length);
      if (relative.isEmpty) continue;
      final target = File('${dir.path}/$relative');
      if (await target.exists()) continue;
      await target.parent.create(recursive: true);
      final data = await rootBundle.load(key);
      await target.writeAsBytes(data.buffer.asUint8List());
      copied++;
    }

    if (copied > 0) {
      print('📦 已复制 $copied 个 sherpa_kws 资源到 ${dir.path}');
    }

    return dir.path;
  }

  List<String> _missingModelFiles(String dirPath) {
    final need = [_encoder, _decoder, _joiner, _tokens, _keywords];
    final missing = <String>[];
    for (final name in need) {
      if (!File('$dirPath/$name').existsSync()) {
        missing.add(name);
      }
    }
    return missing;
  }

  /// 初始化 Spotter；若模型文件不齐则返回 false。
  Future<bool> init() async {
    if (_spotterMain != null && _spotterLow != null) return true;

    final dir = await _copyKwsAssetsIfNeeded();
    if (dir == null) {
      print('❌ sherpa_kws：无法准备模型目录');
      return false;
    }

    final missing = _missingModelFiles(dir);
    if (missing.isNotEmpty) {
      print('❌ sherpa_kws：缺少模型文件: ${missing.join(", ")}');
      print(
          '   请解压 tar.bz2 后将 int8 encoder/joiner、fp32 decoder、tokens.txt 与 keywords.txt 放入 assets/sherpa_kws/ 并重新构建。');
      print(
          '   下载: https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2');
      return false;
    }

    _modelDir = dir;

    final transducer = sherpa.OnlineTransducerModelConfig(
      encoder: '$dir/$_encoder',
      decoder: '$dir/$_decoder',
      joiner: '$dir/$_joiner',
    );

    final model = sherpa.OnlineModelConfig(
      transducer: transducer,
      tokens: '$dir/$_tokens',
      modelingUnit: 'cjkchar',
      numThreads: 2,
      debug: false,
    );

    final configMain = sherpa.KeywordSpotterConfig(
      model: model,
      keywordsFile: '$dir/$_keywords',
      // 主阈值：稳态优先，避免误触过多。
      keywordsThreshold: _kwsThresholdMain,
      keywordsScore: 1.0,
    );
    final configLow = sherpa.KeywordSpotterConfig(
      model: model,
      keywordsFile: '$dir/$_keywords',
      // 低阈值：给低音量/含糊发音补偿；需通过自适应门控才会放行。
      keywordsThreshold: _kwsThresholdLow,
      keywordsScore: 1.0,
    );

    try {
      _spotterMain = sherpa.KeywordSpotter(configMain);
      _streamMain = _spotterMain!.createStream();
      _spotterLow = sherpa.KeywordSpotter(configLow);
      _streamLow = _spotterLow!.createStream();
    } catch (e, st) {
      print('❌ sherpa KeywordSpotter 创建失败: $e\n$st');
      _spotterMain?.free();
      _streamMain?.free();
      _spotterLow?.free();
      _streamLow?.free();
      _spotterMain = null;
      _streamMain = null;
      _spotterLow = null;
      _streamLow = null;
      return false;
    }

    print(
        '✅ sherpa-onnx 唤醒模型已加载（main=$_kwsThresholdMain low=$_kwsThresholdLow 关键词见 keywords.txt）');
    return true;
  }

  Future<void> _ensureMicPermission() async {
    final s = await Permission.microphone.request();
    if (!s.isGranted) {
      print('❌ 麦克风权限未授予，无法使用 sherpa 唤醒');
    }
  }

  /// 开始从麦克风送流解码（与 VOSK 不要同时调用，请先 pause）。
  Future<bool> start() => _runMicSerialized(_startImpl);

  Future<bool> _startImpl() async {
    if (!_running &&
        (_spotterMain == null ||
            _streamMain == null ||
            _spotterLow == null ||
            _streamLow == null)) {
      print('⚠️ sherpa_kws：未初始化，跳过启动');
      return false;
    }
    if (_running && !_paused) return true;

    await _ensureMicPermission();

    if (Platform.isAndroid) {
      await Future<void>.delayed(_androidMicOpenDelay);
    }

    final useVoip = Platform.isAndroid && _androidVoipEchoCapture;
    final stream = await MicStream.microphone(
      sampleRate: 16000,
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,
      audioSource:
          useVoip ? AudioSource.VOICE_COMMUNICATION : AudioSource.DEFAULT,
      androidVoipEchoCapture: useVoip,
    );
    if (stream == null) {
      print('❌ 无法打开麦克风 PCM 流');
      return false;
    }

    final sr = await MicStream.sampleRate;
    _micSampleRate = sr?.round() ?? 16000;

    _paused = false;
    _running = true;
    _rmsEma = 0.0;
    _peakEma = 0.0;
    _noiseFloorEma = 0.0;
    _lowGateOpen = false;
    _mainHitCount = 0;
    _lowHitCount = 0;

    _micSub = stream.listen(
      _onMicBytes,
      onError: (e) => print('❌ sherpa 麦克风流错误: $e'),
      cancelOnError: false,
    );
    _rmsLogTimer?.cancel();
    _rmsLogTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_running || _paused) return;
      print(
          '📊 [KWS-RMS] rmsEma=${_rmsEma.toStringAsFixed(5)} peakEma=${_peakEma.toStringAsFixed(5)} noiseFloor=${_noiseFloorEma.toStringAsFixed(5)} '
          'snr=${_snrLike.toStringAsFixed(3)} lowGate=$_lowGateOpen hits(main=$_mainHitCount low=$_lowHitCount)');
    });
    print(
        '🎤 sherpa-onnx 唤醒已开始监听 ($_micSampleRate Hz) androidVoipEchoCapture=$useVoip');
    return true;
  }

  void _onMicBytes(Uint8List data) {
    if (_paused ||
        _spotterMain == null ||
        _streamMain == null ||
        _spotterLow == null ||
        _streamLow == null) {
      return;
    }

    final enhanced = _enhancePcm16Le(data);
    final n = enhanced.length >> 1;
    if (n == 0) return;

    final samples = Float32List(n);
    final bd = ByteData.sublistView(enhanced);
    for (var i = 0; i < n; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _updateAdaptiveStats(samples);

    _tickSpeechVad(samples);

    try {
      _streamMain!.acceptWaveform(samples: samples, sampleRate: _micSampleRate);
      _streamLow!.acceptWaveform(samples: samples, sampleRate: _micSampleRate);

      while (_spotterMain!.isReady(_streamMain!)) {
        _spotterMain!.decode(_streamMain!);
        final r = _spotterMain!.getResult(_streamMain!);
        if (r.keyword.isNotEmpty) {
          _mainHitCount++;
          _spotterMain!.reset(_streamMain!);
          _spotterLow!.reset(_streamLow!);
          _emitKeywordIfAllowed(r.keyword, source: 'main');
        }
      }
      while (_spotterLow!.isReady(_streamLow!)) {
        _spotterLow!.decode(_streamLow!);
        final r = _spotterLow!.getResult(_streamLow!);
        if (r.keyword.isNotEmpty) {
          _lowHitCount++;
          _spotterLow!.reset(_streamLow!);
          _spotterMain!.reset(_streamMain!);
          if (_lowGateOpen) {
            _emitKeywordIfAllowed(r.keyword, source: 'low');
          }
        }
      }
    } catch (e) {
      print('❌ sherpa 解码异常: $e');
    }
  }

  void _emitKeywordIfAllowed(String keyword, {required String source}) {
    final now = DateTime.now();
    final last = _lastKeywordEmitAt;
    if (last != null && now.difference(last) < _emitCooldown) return;
    _lastKeywordEmitAt = now;
    print(
        '🎯 [KWS] source=$source keyword=$keyword rmsEma=${_rmsEma.toStringAsFixed(5)} noiseFloor=${_noiseFloorEma.toStringAsFixed(5)} '
        'snr=${_snrLike.toStringAsFixed(3)} lowGate=$_lowGateOpen');
    onKeyword?.call(keyword);
  }

  void _updateAdaptiveStats(Float32List samples) {
    var sumSq = 0.0;
    var peak = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i];
      sumSq += v * v;
      final a = v < 0 ? -v : v;
      if (a > peak) peak = a;
    }
    final rms = math.sqrt(sumSq / samples.length);

    if (_rmsEma == 0) {
      _rmsEma = rms;
      _peakEma = peak;
      _noiseFloorEma = rms;
    } else {
      _rmsEma = _rmsEma * 0.88 + rms * 0.12;
      _peakEma = _peakEma * 0.88 + peak * 0.12;
      if (rms < _noiseFloorEma * 1.18) {
        _noiseFloorEma = _noiseFloorEma * 0.95 + rms * 0.05;
      } else {
        _noiseFloorEma = _noiseFloorEma * 0.995 + rms * 0.005;
      }
    }

    _snrLike = _noiseFloorEma <= 1e-6 ? 99.0 : (_rmsEma / _noiseFloorEma);
    // 自适应放行 low 阈值：
    // 1) 绝对音量偏低（含着说/远讲话）但相对底噪仍有增益；
    // 2) 峰值不过低，避免纯背景噪声触发。
    _lowGateOpen = _rmsEma < _lowGateRmsMax &&
        _snrLike >= _lowGateSnrMin &&
        _peakEma >= _lowGatePeakMin;
  }

  double _rmsInt16Le(Uint8List bytes) {
    final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    final pairs = bytes.length ~/ 2;
    if (pairs == 0) return 0;
    var sum = 0.0;
    for (var i = 0; i < pairs; i++) {
      final s = bd.getInt16(i * 2, Endian.little).toDouble();
      sum += s * s;
    }
    return math.sqrt(sum / pairs);
  }

  /// 轻量自动增益：改善近距离小声/偏闷输入造成的漏检。
  Uint8List _enhancePcm16Le(Uint8List src) {
    final rms = _rmsInt16Le(src);
    if (rms <= 1) return src;

    var gain = _targetRmsInt16 / rms;
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

  /// 暂停采集（释放与 VOSK 的麦克风争用）。
  Future<void> pause() => _runMicSerialized(_pauseImpl);

  Future<void> _pauseImpl() async {
    if (!_running) return;
    _ttsBargeInVadEnabled = false;
    _vadArmedAt = null;
    _vadLoudRunSamples = 0;
    _vadCooldownUntil = null;
    _paused = true;
    await _micSub?.cancel();
    _micSub = null;
    _running = false;
    _rmsLogTimer?.cancel();
    _rmsLogTimer = null;
    if (_spotterMain != null && _streamMain != null) {
      _spotterMain!.reset(_streamMain!);
    }
    if (_spotterLow != null && _streamLow != null) {
      _spotterLow!.reset(_streamLow!);
    }
    if (Platform.isAndroid) {
      await Future<void>.delayed(_androidMicReleaseDelay);
    }
    print('⏸️ sherpa-onnx 唤醒已暂停（麦克风让给语音识别）');
  }

  Future<void> resume() => _runMicSerialized(_resumeImpl);

  Future<void> _resumeImpl() async {
    if (_spotterMain == null ||
        _streamMain == null ||
        _spotterLow == null ||
        _streamLow == null) {
      return;
    }
    _spotterMain!.reset(_streamMain!);
    _spotterLow!.reset(_streamLow!);
    await _startImpl();
  }

  Future<void> stop() => _runMicSerialized(_stopImpl);

  Future<void> _stopImpl() async {
    await _pauseImpl();
    _streamMain?.free();
    _streamMain = null;
    _streamLow?.free();
    _streamLow = null;
    _spotterMain?.free();
    _spotterMain = null;
    _spotterLow?.free();
    _spotterLow = null;
    _modelDir = null;
    print('🛑 sherpa-onnx 唤醒已停止并释放');
  }
}
