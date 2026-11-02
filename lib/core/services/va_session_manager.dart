import 'dart:async';
import 'dart:typed_data';

import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/va_session_client.dart';

class _CachedVaFrame {
  _CachedVaFrame({
    required this.bytes,
    required this.capturedAt,
  });

  final Uint8List bytes;
  final DateTime capturedAt;
}

/// 一轮用户发言期间的 VA 会话管理器。
///
/// 当前策略：
/// 1. 音频分片实时旁路给 VA。
/// 2. 用户开口后先本地缓存最多 3 张图，不立即上传。
/// 3. 只有在 Companion 分支真正启动 VA 时，才统一上传缓存图。
class VaSessionManager {
  VaSessionManager({VaSessionClient? client, CameraService? cameraService})
      : _client = client ?? VaSessionClient(),
        _cameraService = cameraService ?? CameraService();

  final VaSessionClient _client;
  final CameraService _cameraService;

  String? _sessionId;
  bool _starting = false;
  bool _finishing = false;
  Future<void> _audioTail = Future<void>.value();
  Future<void> _imageTail = Future<void>.value();
  StreamSubscription? _vaPrebufferSubscription;
  Map<String, dynamic>? _latestSummary;
  Map<String, dynamic>? _finalResult;
  Object? _lastError;
  Timer? _imageTimer;
  bool _cameraReady = false;
  bool _imageCaptureInFlight = false;
  bool _visionEnabledForCurrentUtterance = false;
  bool _visionTemporarilyDisabled = false;
  bool _imageLoopStarted = false;
  bool _hadSuccessfulImageCaptureInCurrentUtterance = false;
  Completer<void>? _nextFrameWaiter;
  String? _closingSessionId;
  final List<_CachedVaFrame> _cachedFrames = <_CachedVaFrame>[];
  int _startSessionCostMs = 0;
  int _audioUploadTotalMs = 0;
  int _audioUploadCount = 0;
  int _imageCaptureTotalMs = 0;
  int _imageCaptureCount = 0;
  int _imageUploadTotalMs = 0;
  int _imageUploadCount = 0;

  static const Duration _imageInterval = Duration(seconds: 2);
  static const int _maxCachedFrames = 2;
  static const Duration _finishWaitNoImage = Duration(milliseconds: 250);
  static const Duration _finishWaitImageInFlight = Duration(milliseconds: 600);

  bool get isActive => _sessionId != null;
  String? get sessionId => _sessionId;
  Map<String, dynamic>? get latestSummary => _latestSummary;
  Map<String, dynamic>? get finalResult => _finalResult;
  Object? get lastError => _lastError;
  int get cachedFrameCount => _cachedFrames.length;

  Future<bool> healthCheck() => _client.health();

  Future<String?> startSession() async {
    if (_sessionId != null) return _sessionId;
    if (_starting) return _sessionId;
    _starting = true;
    _lastError = null;
    _latestSummary = null;
    _finalResult = null;
    final sw = Stopwatch()..start();
    try {
      final response = await _client.startSession();
      final data = _extractData(response);
      final sid = data['session_id']?.toString();
      if (sid == null || sid.isEmpty) {
        throw StateError('VA startSession 未返回有效 session_id');
      }
      _sessionId = sid;
      sw.stop();
      _startSessionCostMs = sw.elapsedMilliseconds;
      print('✅ [VA] 会话已创建 sid=$sid cost=${sw.elapsedMilliseconds}ms');
      return sid;
    } catch (e) {
      _lastError = e;
      sw.stop();
      print('❌ [VA] startSession 失败 cost=${sw.elapsedMilliseconds}ms error=$e');
      return null;
    } finally {
      _starting = false;
    }
  }

  Future<void> sendAudioChunk(Uint8List chunkBytes) async {
    final sid = _sessionId;
    if (sid == null || _finishing || chunkBytes.isEmpty) return;

    _audioTail = _audioTail.then((_) async {
      final sw = Stopwatch()..start();
      try {
        final wavBytes = _wrapPcm16MonoToWav(chunkBytes);
        final response = await _client.sendAudioChunk(
          sid,
          wavBytes,
          filename: 'chunk_${DateTime.now().millisecondsSinceEpoch}.wav',
        );
        final data = _extractData(response);
        final summary = data['current_summary'];
        if (summary is Map<String, dynamic>) {
          _latestSummary = summary;
        } else if (summary is Map) {
          _latestSummary = Map<String, dynamic>.from(summary);
        }
        sw.stop();
        _audioUploadTotalMs += sw.elapsedMilliseconds;
        _audioUploadCount += 1;
        print(
          '📊 [VA] audio current_summary sid=$sid '
          'bytes_pcm=${chunkBytes.length} bytes_wav=${wavBytes.length} '
          'cost=${sw.elapsedMilliseconds}ms',
        );
      } catch (e) {
        _lastError = e;
        sw.stop();
        print('❌ [VA] audio chunk 上传失败 sid=$sid cost=${sw.elapsedMilliseconds}ms error=$e');
      }
    });

    await _audioTail;
  }

  void beginSpeechWindowImageBuffering() {
    if (_finishing) return;
    if (_visionTemporarilyDisabled) return;
    if (_visionEnabledForCurrentUtterance) return;
    _visionEnabledForCurrentUtterance = true;
    _hadSuccessfulImageCaptureInCurrentUtterance = false;
    print('📷 [VA] 用户开口，开始缓存本轮图片');
    unawaited(_ensureVaPrebufferStream());
    _imageCaptureInFlight = true;
    _imageTail =
        _imageTail.then((_) => _captureAndCacheImage()).whenComplete(() {
      _imageCaptureInFlight = false;
    });
    _startImageLoop();
  }

  Future<void> _ensureVaPrebufferStream() async {
    if (_vaPrebufferSubscription != null) return;
    try {
      final stream = await _cameraService.subscribeVaPrebufferStream();
      _cameraReady = true;
      _vaPrebufferSubscription = stream.listen((_) {
        final waiter = _nextFrameWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete();
        }
      }, onError: (
        Object e,
        StackTrace st,
      ) {
        print('⚠️ [VA] 预缓存图像流异常: $e\n$st');
      });
      print('🎞️ [VA] 已开启预缓存图像流订阅');
    } catch (e, st) {
      _visionTemporarilyDisabled = true;
      _visionEnabledForCurrentUtterance = false;
      _imageTimer?.cancel();
      _imageLoopStarted = false;
      _imageCaptureInFlight = false;
      _lastError = e;
      print('⚠️ [VA] 预缓存图像流初始化失败，本轮降级为纯音频 VA: $e\n$st');
    }
  }

  void enableVisionEnhancement() {
    if (_finishing) return;
    if (_visionTemporarilyDisabled) {
      print('ℹ️ [VA] 相机当前不可用，跳过本轮视觉增强');
      return;
    }
    print('📷 [VA] 本轮命中视觉增强条件，继续使用当前图片缓存窗口');
    beginSpeechWindowImageBuffering();
  }

  void _startImageLoop() {
    if (_imageLoopStarted) return;
    _imageTimer?.cancel();
    _imageLoopStarted = true;
    _imageTimer = Timer.periodic(_imageInterval, (_) {
      if (_finishing) return;
      if (!_visionEnabledForCurrentUtterance) return;
      if (_imageCaptureInFlight) return;
      if (_cachedFrames.length >= _maxCachedFrames) {
        _imageTimer?.cancel();
        _imageLoopStarted = false;
        print('🖼️ [VA] 图片缓存已达上限 $_maxCachedFrames，停止继续拍摄');
        return;
      }
      _imageCaptureInFlight = true;
      _imageTail =
          _imageTail.then((_) => _captureAndCacheImage()).whenComplete(() {
        _imageCaptureInFlight = false;
      });
    });
    print(
      '🖼️ [VA] 图片缓存定时器已启动 interval=${_imageInterval.inSeconds}s sid=${_sessionId ?? 'prebuffer'}',
    );
  }

  Future<void> _captureAndCacheImage() async {
    final sidLabel = _sessionId ?? 'prebuffer';
    if (_finishing ||
        !_visionEnabledForCurrentUtterance ||
        _visionTemporarilyDisabled) {
      return;
    }

    final totalSw = Stopwatch()..start();
    try {
      var cameraInitMs = 0;
      if (!_cameraReady) {
        final initSw = Stopwatch()..start();
        print('📷 [VA] 初始化相机用于图片缓存 sid=$sidLabel');
        await _cameraService.initialize();
        _cameraReady = true;
        initSw.stop();
        cameraInitMs = initSw.elapsedMilliseconds;
      }

      if (_finishing) {
        totalSw.stop();
        print('⚠️ [VA] image 缓存任务在执行前取消 sid=$sidLabel total=${totalSw.elapsedMilliseconds}ms');
        return;
      }

      final captureSw = Stopwatch()..start();
      Uint8List? imageBytes = _cameraService.getLatestStreamFrameJpegBytes();
      imageBytes ??= await _awaitNextStreamFrameAndCapture();
      if (imageBytes == null || imageBytes.isEmpty) {
        throw Exception('未获取到可用新鲜流帧');
      }
      captureSw.stop();

      if (_finishing) {
        totalSw.stop();
        print(
          '⚠️ [VA] image 捕获完成但会话已关闭 sid=$sidLabel '
          'capture=${captureSw.elapsedMilliseconds}ms total=${totalSw.elapsedMilliseconds}ms',
        );
        return;
      }

      _cachedFrames.add(
        _CachedVaFrame(
          bytes: imageBytes,
          capturedAt: DateTime.now(),
        ),
      );
      _hadSuccessfulImageCaptureInCurrentUtterance = true;
      while (_cachedFrames.length > _maxCachedFrames) {
        _cachedFrames.removeAt(0);
      }
      if (_cachedFrames.length >= _maxCachedFrames) {
        _imageTimer?.cancel();
        _imageLoopStarted = false;
      }

      totalSw.stop();
      _imageCaptureTotalMs += totalSw.elapsedMilliseconds;
      _imageCaptureCount += 1;
      print(
        '🖼️ [VA] 已缓存图片 sid=$sidLabel '
        'cameraInit=${cameraInitMs}ms capture=${captureSw.elapsedMilliseconds}ms '
        'total=${totalSw.elapsedMilliseconds}ms cached=${_cachedFrames.length}',
      );
    } catch (e) {
      _lastError = e;
      totalSw.stop();
      final errorText = e.toString();
      final canRetry =
          !_hadSuccessfulImageCaptureInCurrentUtterance &&
          (errorText.contains('TimeoutException') ||
              errorText.contains('Previous capture has not returned yet') ||
              errorText.contains('未获取到可用新鲜流帧'));
      if (canRetry) {
        print(
          '⚠️ [VA] 首帧图片缓存暂不可用，保留视觉增强等待下一次流帧 sid=$sidLabel '
          'total=${totalSw.elapsedMilliseconds}ms error=$e',
        );
        return;
      }
      _visionTemporarilyDisabled = true;
      _visionEnabledForCurrentUtterance = false;
      _imageTimer?.cancel();
      _imageLoopStarted = false;
      print(
        '⚠️ [VA] image 缓存失败，本轮关闭视觉增强 sid=$sidLabel '
        'total=${totalSw.elapsedMilliseconds}ms error=$e',
      );
    }
  }

  Future<Uint8List?> _awaitNextStreamFrameAndCapture() async {
    if (_visionTemporarilyDisabled || _finishing) return null;
    final existing = _nextFrameWaiter;
    if (existing == null || existing.isCompleted) {
      _nextFrameWaiter = Completer<void>();
    }
    try {
      await _nextFrameWaiter!.future.timeout(const Duration(milliseconds: 420));
    } on TimeoutException {
      return null;
    } finally {
      _nextFrameWaiter = null;
    }
    return _cameraService.getLatestStreamFrameJpegBytes();
  }

  Future<int> uploadCachedImagesForEmotionBranch() async {
    final sid = _sessionId;
    if (sid == null || _finishing) return 0;
    if (_cachedFrames.isEmpty &&
        _visionEnabledForCurrentUtterance &&
        !_visionTemporarilyDisabled) {
      final frame = await _awaitNextStreamFrameAndCapture();
      if (frame != null && frame.isNotEmpty) {
        _cachedFrames.add(
          _CachedVaFrame(bytes: frame, capturedAt: DateTime.now()),
        );
        _hadSuccessfulImageCaptureInCurrentUtterance = true;
        print('🖼️ [VA] Router 命中后补抓到一帧流图 sid=$sid bytes=${frame.length}');
      }
    }
    if (_cachedFrames.isEmpty) {
      print('ℹ️ [VA] 当前无缓存图片可上传 sid=$sid');
      return 0;
    }

    final frames = <_CachedVaFrame>[_cachedFrames.last];
    var successCount = 0;
    for (var index = 0; index < frames.length; index++) {
      final frame = frames[index];
      final uploadSw = Stopwatch()..start();
      try {
        if (_finishing || _sessionId != sid) break;
        print(
          '📷 [VA] 情绪分支上传缓存图 sid=$sid '
          'try=${index + 1}/${frames.length} bytes=${frame.bytes.length}',
        );
        final response = await _client.sendImageFrame(
          sid,
          frame.bytes,
          filename: 'cached_${frame.capturedAt.millisecondsSinceEpoch}.jpg',
        );
        uploadSw.stop();
        final data = _extractData(response);
        final summary = data['current_summary'];
        if (summary is Map<String, dynamic>) {
          _latestSummary = summary;
        } else if (summary is Map) {
          _latestSummary = Map<String, dynamic>.from(summary);
        }
        _imageUploadTotalMs += uploadSw.elapsedMilliseconds;
        _imageUploadCount += 1;
        print(
          '📊 [VA] image current_summary sid=$sid '
          'upload=${uploadSw.elapsedMilliseconds}ms source=cached '
          'summary=${_latestSummary ?? summary}',
        );
        successCount += 1;
      } catch (e) {
        uploadSw.stop();
        final message = e.toString();
        final noFace =
            message.contains('No clear face detected in image') ||
                message.contains('no clear face detected in image');
        if (noFace) {
          print(
            '⚠️ [VA] 缓存图未检测到清晰人脸 sid=$sid '
            'try=${index + 1}/${frames.length} upload=${uploadSw.elapsedMilliseconds}ms',
          );
          continue;
        }
        _lastError = e;
        print(
          '❌ [VA] 缓存图上传失败 sid=$sid '
          'try=${index + 1}/${frames.length} upload=${uploadSw.elapsedMilliseconds}ms error=$e',
        );
      }
    }

    print('🖼️ [VA] 本轮缓存图上传完成 sid=$sid success=$successCount total=${frames.length}');
    return successCount;
  }

  Future<Map<String, dynamic>?> finishSession() async {
    final sid = _sessionId;
    if (sid == null) return _finalResult;
    if (_finishing) return _finalResult;

    _finishing = true;
    _closingSessionId = sid;
    final totalSw = Stopwatch()..start();
    try {
      final waitAudioSw = Stopwatch()..start();
      await _audioTail;
      waitAudioSw.stop();
      _imageTimer?.cancel();
      _imageLoopStarted = false;
      final waitImageBudget =
          _imageCaptureInFlight ? _finishWaitImageInFlight : _finishWaitNoImage;
      final waitImageSw = Stopwatch()..start();
      await _imageTail.timeout(
        waitImageBudget,
        onTimeout: () async {
          print(
            '⚠️ [VA] finish 等待图片缓存收尾超时 '
            'budget=${waitImageBudget.inMilliseconds}ms sid=$sid',
          );
        },
      );
      waitImageSw.stop();
      final finishHttpSw = Stopwatch()..start();
      final response = await _client.finishSession(sid);
      finishHttpSw.stop();
      final data = _extractData(response);
      _finalResult = data;
      final fusionSummary = data['fusion_summary'];
      if (fusionSummary is Map<String, dynamic>) {
        _latestSummary = <String, dynamic>{
          'fusion_summary': fusionSummary,
        };
      } else if (fusionSummary is Map) {
        _latestSummary = <String, dynamic>{
          'fusion_summary': Map<String, dynamic>.from(fusionSummary),
        };
      }
      totalSw.stop();
      final avgAudioUploadMs =
          _audioUploadCount == 0 ? 0 : (_audioUploadTotalMs ~/ _audioUploadCount);
      final avgImageCaptureMs =
          _imageCaptureCount == 0 ? 0 : (_imageCaptureTotalMs ~/ _imageCaptureCount);
      final avgImageUploadMs =
          _imageUploadCount == 0 ? 0 : (_imageUploadTotalMs ~/ _imageUploadCount);
      print(
        '⏱️ [VA][Timing] sid=$sid '
        'start=${_startSessionCostMs}ms '
        'audioUploadTotal=${_audioUploadTotalMs}ms count=$_audioUploadCount avg=${avgAudioUploadMs}ms '
        'imageCaptureTotal=${_imageCaptureTotalMs}ms count=$_imageCaptureCount avg=${avgImageCaptureMs}ms '
        'imageUploadTotal=${_imageUploadTotalMs}ms count=$_imageUploadCount avg=${avgImageUploadMs}ms '
        'finishTotal=${totalSw.elapsedMilliseconds}ms',
      );
      print(
        '✅ [VA] finishSession 完成 sid=$sid '
        'waitAudio=${waitAudioSw.elapsedMilliseconds}ms '
        'waitImage=${waitImageSw.elapsedMilliseconds}ms '
        'finishHttp=${finishHttpSw.elapsedMilliseconds}ms '
        'total=${totalSw.elapsedMilliseconds}ms',
      );
      return _finalResult;
    } catch (e) {
      _lastError = e;
      totalSw.stop();
      print('❌ [VA] finishSession 失败 sid=$sid total=${totalSw.elapsedMilliseconds}ms error=$e');
      return null;
    } finally {
      _sessionId = null;
      _finishing = false;
      _closingSessionId = null;
    }
  }

  Future<void> reset() async {
    _closingSessionId = null;
    await _audioTail;
    _imageTimer?.cancel();
    await _imageTail;
    await _vaPrebufferSubscription?.cancel();
    _vaPrebufferSubscription = null;
    _nextFrameWaiter = null;
    await _cameraService.unsubscribeVaPrebufferStream();
    _sessionId = null;
    _latestSummary = null;
    _finalResult = null;
    _lastError = null;
    _starting = false;
    _finishing = false;
    _audioTail = Future<void>.value();
    _imageTail = Future<void>.value();
    _imageCaptureInFlight = false;
    _visionEnabledForCurrentUtterance = false;
    _visionTemporarilyDisabled = false;
    _imageLoopStarted = false;
    _cameraReady = false;
    _hadSuccessfulImageCaptureInCurrentUtterance = false;
    _nextFrameWaiter = null;
    _startSessionCostMs = 0;
    _audioUploadTotalMs = 0;
    _audioUploadCount = 0;
    _imageCaptureTotalMs = 0;
    _imageCaptureCount = 0;
    _imageUploadTotalMs = 0;
    _imageUploadCount = 0;
    _cachedFrames.clear();
  }

  Uint8List _wrapPcm16MonoToWav(Uint8List pcmBytes) {
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataLength = pcmBytes.length;
    final totalLength = 44 + dataLength;

    final out = Uint8List(totalLength);
    final bd = ByteData.sublistView(out);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bd.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bd.setUint32(4, totalLength - 8, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    bd.setUint32(40, dataLength, Endian.little);
    out.setRange(44, totalLength, pcmBytes);
    return out;
  }

  Map<String, dynamic> _extractData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw StateError('VA 响应缺少 data 字段: $response');
  }
}
