import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

enum CameraTaskPriority {
  high,
  normal,
  low,
}

class _CaptureRequest {
  _CaptureRequest({
    required this.completer,
    required this.priority,
    required this.keepStreamOn,
    required this.timeout,
    required this.seq,
  });

  final Completer<XFile> completer;
  final CameraTaskPriority priority;
  final bool keepStreamOn;
  final Duration timeout;
  final int seq;
}

/// 相机资源管理器
/// 统一管理相机资源，避免多个功能同时竞争相机资源
/// 采用单例模式，确保整个应用只有一个相机实例
class CameraResourceManager {
  // 单例实例
  static final CameraResourceManager _instance = CameraResourceManager._internal();
  factory CameraResourceManager() {
    print('📷 [相机资源管理器] 获取单例实例');
    return _instance;
  }
  CameraResourceManager._internal() {
    print('📷 [相机资源管理器] 单例实例已创建');
  }

  // 相机控制器
  CameraController? _controller;
  
  // 相机状态
  bool _isInitialized = false;
  bool _isInitializing = false;
  
  // 订阅者管理（流模式）
  final Map<String, StreamController<CameraImage>> _subscribers = {};
  StreamSubscription<CameraImage>? _imageStreamSubscription;
  
  // 单帧请求计数（用于跟踪是否有单帧需求）
  int _singleFrameRequestCount = 0;
  
  // 相机配置
  CameraDescription? _selectedCamera;
  ResolutionPreset _resolutionPreset = ResolutionPreset.medium;
  ImageFormatGroup _imageFormatGroup = ImageFormatGroup.yuv420;
  
  // 最新图像缓存（用于拍照功能）
  CameraImage? _latestImage;
  DateTime? _latestImageAt;
  
  // 图像流状态
  bool _isImageStreamRunning = false;

  // 拍照仲裁：串行队列 + 优先级 + 超时
  final List<_CaptureRequest> _captureQueue = <_CaptureRequest>[];
  bool _captureWorkerRunning = false;
  int _captureSeq = 0;
  static const Duration _streamSnapshotMaxAge = Duration(milliseconds: 280);
  bool _hardwareCaptureInFlight = false;
  
  /// 获取相机控制器（只读，用于UI预览等）
  CameraController? get cameraController => _controller;
  
  /// 检查相机是否已初始化
  bool get isInitialized => _isInitialized;
  
  /// 获取选中的相机描述
  CameraDescription? get selectedCamera => _selectedCamera;
  
  /// 获取预览尺寸
  Size? get previewSize {
    if (_controller?.value.isInitialized == true) {
      return _controller!.value.previewSize;
    }
    return null;
  }

  /// 初始化相机资源
  /// [preferredLens] 优先使用的镜头方向（前置或后置）
  /// [resolutionPreset] 分辨率预设
  /// [imageFormatGroup] 图像格式组
  Future<void> initialize({
    CameraLensDirection preferredLens = CameraLensDirection.front,
    ResolutionPreset resolutionPreset = ResolutionPreset.medium,
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.yuv420,
  }) async {
    // 如果已经初始化，直接返回
    if (_isInitialized) {
      print('📷 相机资源管理器已初始化，无需重复初始化');
      return;
    }
    
    // 如果正在初始化，等待完成
    if (_isInitializing) {
      print('⏳ 相机资源管理器正在初始化中，等待完成...');
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return;
    }
    
    _isInitializing = true;
    _resolutionPreset = resolutionPreset;
    _imageFormatGroup = imageFormatGroup;
    
    try {
      print('🔄 开始初始化相机资源管理器...');
      
      // 获取可用摄像头列表
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('没有找到可用的摄像头设备');
      }
      
      // 选择摄像头（优先使用指定方向）
      try {
        _selectedCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == preferredLens,
        );
        print('✅ 找到${preferredLens == CameraLensDirection.front ? "前置" : "后置"}摄像头: ${_selectedCamera!.name}');
      } catch (e) {
        // 如果找不到指定方向的摄像头，使用第一个可用的
        _selectedCamera = cameras.first;
        print('⚠️ 未找到${preferredLens == CameraLensDirection.front ? "前置" : "后置"}摄像头，使用第一个可用摄像头: ${_selectedCamera!.name}');
      }
      
      // 创建相机控制器
      _controller = CameraController(
        _selectedCamera!,
        _resolutionPreset,
        imageFormatGroup: _imageFormatGroup,
        enableAudio: false,
      );
      
      // 初始化相机
      await _controller!.initialize();
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      
      _isInitialized = true;
      print('✅ 相机资源管理器初始化成功');
      _printCurrentStatus('初始化完成');
    } catch (e) {
      print('❌ 相机资源管理器初始化失败: $e');
      _isInitialized = false;
      _controller = null;
      _selectedCamera = null;
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }
  
  /// 打印当前状态（实时监控）
  void _printCurrentStatus(String operation) {
    print('📊 [相机资源管理器状态] $operation');
    print('   ├─ 初始化状态: ${_isInitialized ? "✅ 已初始化" : "❌ 未初始化"}');
    print('   ├─ 图像流状态: ${_isImageStreamRunning ? "🟢 运行中" : "🔴 已停止"}');
    print('   ├─ 流订阅者数: ${_subscribers.length}');
    if (_subscribers.isNotEmpty) {
      print('   ├─ 订阅者列表: ${_subscribers.keys.join(", ")}');
    }
    print('   ├─ 单帧请求数: $_singleFrameRequestCount');
    print('   ├─ 使用模式: ${_getUsageModeDescription()}');
    if (_selectedCamera != null) {
      print('   ├─ 相机设备: ${_selectedCamera!.name} (${_selectedCamera!.lensDirection == CameraLensDirection.front ? "前置" : "后置"})');
    }
    if (previewSize != null) {
      print('   └─ 预览尺寸: ${previewSize!.width}x${previewSize!.height}');
    } else {
      print('   └─ 预览尺寸: 未知');
    }
  }

  /// 订阅相机图像流（视频流模式）
  /// [subscriberId] 订阅者唯一标识符（例如："gesture_service"）
  /// 返回一个Stream，订阅者可以监听这个流来持续接收相机图像
  /// 
  /// 使用场景：需要持续接收视频流的场景（如手势识别）
  Stream<CameraImage> subscribeImageStream(String subscriberId) {
    if (!_isInitialized) {
      throw Exception('相机资源管理器未初始化，请先调用 initialize()');
    }
    
    // 如果订阅者已存在，返回现有的流
    if (_subscribers.containsKey(subscriberId)) {
      print('📺 订阅者 $subscriberId 已存在，返回现有流');
      return _subscribers[subscriberId]!.stream;
    }
    
    print('📺 新流订阅者 $subscriberId 加入，创建新的流控制器');
    
    // 创建新的流控制器
    final streamController = StreamController<CameraImage>.broadcast();
    _subscribers[subscriberId] = streamController;
    
    // 如果这是第一个流订阅者，启动图像流
    if (_subscribers.length == 1) {
      _startImageStream();
    } else {
      _printCurrentStatus('新增流订阅者: $subscriberId');
    }
    
    return streamController.stream;
  }

  /// 取消订阅相机图像流
  /// [subscriberId] 订阅者唯一标识符
  Future<void> unsubscribeImageStream(String subscriberId) async {
    if (!_subscribers.containsKey(subscriberId)) {
      print('⚠️ 订阅者 $subscriberId 不存在，无需取消订阅');
      return;
    }
    
    print('📺 取消订阅者 $subscriberId 的订阅');
    
    // 关闭流控制器
    await _subscribers[subscriberId]!.close();
    _subscribers.remove(subscriberId);
    
    _printCurrentStatus('取消订阅: $subscriberId');
    
    // 如果没有订阅者了，停止图像流
    if (_subscribers.isEmpty) {
      await _stopImageStream();
    }
  }

  /// 启动图像流（内部方法）
  void _startImageStream() {
    if (_controller == null || !_isInitialized) {
      print('❌ 无法启动图像流：相机未初始化');
      return;
    }
    
    if (_isImageStreamRunning) {
      print('⚠️ 图像流已在运行中');
      return;
    }
    
    print('🔄 启动相机图像流...');
    
    try {
      _controller!.startImageStream((CameraImage image) {
        _latestImage = image;
        _latestImageAt = DateTime.now();
        
        // 将图像分发给所有订阅者
        for (var entry in _subscribers.entries) {
          if (!entry.value.isClosed) {
            entry.value.add(image);
          }
        }
      });
      
      _isImageStreamRunning = true;
      print('✅ 相机图像流已启动，当前有 ${_subscribers.length} 个流订阅者');
      _printCurrentStatus('图像流启动');
    } catch (e) {
      print('❌ 启动图像流失败: $e');
      _isImageStreamRunning = false;
      _printCurrentStatus('图像流启动失败');
    }
  }

  /// 停止图像流（内部方法）
  Future<void> _stopImageStream() async {
    if (!_isImageStreamRunning) {
      return;
    }
    
    print('🛑 停止相机图像流...');
    
    try {
      await _controller?.stopImageStream();
      _isImageStreamRunning = false;
      _latestImage = null;
      _latestImageAt = null;
      print('✅ 相机图像流已停止');
      _printCurrentStatus('图像流停止');
    } catch (e) {
      print('❌ 停止图像流失败: $e');
      _isImageStreamRunning = false;
      _printCurrentStatus('图像流停止失败');
    }
  }
  
  /// 临时停止图像流（用于拍照时避免冲突）
  /// 返回true表示需要恢复流，false表示不需要
  Future<bool> _pauseImageStreamTemporarily() async {
    if (_isImageStreamRunning && _subscribers.isNotEmpty) {
      print('⏸️ 临时暂停图像流以便拍照...');
      print('   └─ 当前订阅者: ${_subscribers.keys.join(", ")}');
      await _stopImageStream();
      return true; // 需要恢复
    }
    return false; // 不需要恢复
  }
  
  /// 恢复图像流（拍照后）
  Future<void> _resumeImageStream() async {
    if (!_isImageStreamRunning && _subscribers.isNotEmpty) {
      print('▶️ 恢复图像流...');
      print('   └─ 等待恢复的订阅者: ${_subscribers.keys.join(", ")}');
      _startImageStream();
    }
  }

  /// 拍照（单张图片）：
  /// 1) 默认优先「不停流」从实时流抓取最近帧转 JPEG，减少视频流卡顿；
  /// 2) 失败时降级到硬件拍照（必要时短暂停流并恢复）；
  /// 3) 所有拍照请求经串行队列仲裁，支持优先级与超时。
  Future<XFile> takePicture({
    CameraTaskPriority priority = CameraTaskPriority.normal,
    Duration timeout = const Duration(seconds: 2),
    bool keepStreamOn = true,
  }) async {
    if (!_isInitialized || _controller == null) {
      throw Exception('相机资源管理器未初始化，请先调用 initialize()');
    }

    _singleFrameRequestCount++;
    final completer = Completer<XFile>();
    _captureQueue.add(
      _CaptureRequest(
        completer: completer,
        priority: priority,
        keepStreamOn: keepStreamOn,
        timeout: timeout,
        seq: _captureSeq++,
      ),
    );
    _printCurrentStatus('拍照请求入队 p=$priority timeout=${timeout.inMilliseconds}ms');
    _drainCaptureQueue();
    return completer.future;
  }

  void _drainCaptureQueue() {
    if (_captureWorkerRunning) return;
    _captureWorkerRunning = true;
    Future<void>(() async {
      while (_captureQueue.isNotEmpty) {
        final req = _pickNextCaptureRequest();
        if (req == null) continue;
        try {
          final f = _executeCapture(req);
          final pic = await f.timeout(req.timeout);
          if (!req.completer.isCompleted) {
            req.completer.complete(pic);
          }
        } on TimeoutException catch (_) {
          if (!req.completer.isCompleted) {
            req.completer.completeError(
              TimeoutException(
                '拍照超时（${req.timeout.inMilliseconds}ms）',
                req.timeout,
              ),
            );
          }
        } catch (e) {
          if (!req.completer.isCompleted) {
            req.completer.completeError(e);
          }
        }
      }
      _captureWorkerRunning = false;
    });
  }

  _CaptureRequest? _pickNextCaptureRequest() {
    if (_captureQueue.isEmpty) return null;
    _captureQueue.sort((a, b) {
      final pa = a.priority.index;
      final pb = b.priority.index;
      if (pa != pb) return pa.compareTo(pb);
      return a.seq.compareTo(b.seq);
    });
    return _captureQueue.removeAt(0);
  }

  Future<XFile> _executeCapture(_CaptureRequest req) async {
    print('📸 [拍照执行] p=${req.priority} keepStreamOn=${req.keepStreamOn}');
    if (req.keepStreamOn) {
      final fromStream = await _captureFromLatestStreamFrame();
      if (fromStream != null) {
        print('📸 [拍照执行] 使用视频流快照成功（未停流）: ${fromStream.path}');
        return fromStream;
      }
      print('⚠️ [拍照执行] 无可用新鲜流帧，降级硬件拍照');
    }
    return _captureWithHardwareFallback();
  }

  Future<XFile?> _captureFromLatestStreamFrame() async {
    if (!_isImageStreamRunning) return null;
    final image = _latestImage;
    final at = _latestImageAt;
    if (image == null || at == null) return null;
    final age = DateTime.now().difference(at);
    if (age > _streamSnapshotMaxAge) {
      return null;
    }

    final jpgBytes = _cameraImageToJpegBytes(image);
    if (jpgBytes == null || jpgBytes.isEmpty) return null;

    final path = '${Directory.systemTemp.path}/camera_snapshot_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(path);
    await file.writeAsBytes(jpgBytes, flush: true);
    return XFile(file.path);
  }

  Uint8List? _cameraImageToJpegBytes(CameraImage image) {
    try {
      if (image.format.group == ImageFormatGroup.yuv420 && image.planes.length >= 3) {
        final width = image.width;
        final height = image.height;
        final out = img.Image(width: width, height: height);
        final yPlane = image.planes[0];
        final uPlane = image.planes[1];
        final vPlane = image.planes[2];

        for (var y = 0; y < height; y++) {
          final yRow = yPlane.bytesPerRow * y;
          final uvRow = uPlane.bytesPerRow * (y >> 1);
          for (var x = 0; x < width; x++) {
            final yVal = yPlane.bytes[yRow + x];
            final uvCol = (x >> 1) * (uPlane.bytesPerPixel ?? 1);
            final uVal = uPlane.bytes[uvRow + uvCol];
            final vVal = vPlane.bytes[uvRow + uvCol];

            var r = (yVal + 1.402 * (vVal - 128)).round();
            var g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).round();
            var b = (yVal + 1.772 * (uVal - 128)).round();
            if (r < 0) r = 0;
            if (g < 0) g = 0;
            if (b < 0) b = 0;
            if (r > 255) r = 255;
            if (g > 255) g = 255;
            if (b > 255) b = 255;
            out.setPixelRgb(x, y, r, g, b);
          }
        }
        return Uint8List.fromList(img.encodeJpg(out, quality: 88));
      }
    } catch (e) {
      print('⚠️ 流帧转 JPEG 失败: $e');
    }
    return null;
  }

  Future<XFile> _captureWithHardwareFallback() async {
    if (_hardwareCaptureInFlight) {
      throw CameraException(
        'captureInFlight',
        'Previous capture has not returned yet.',
      );
    }
    bool needResume = false;
    _hardwareCaptureInFlight = true;
    try {
      if (_isImageStreamRunning) {
        needResume = await _pauseImageStreamTemporarily();
        await Future.delayed(const Duration(milliseconds: 90));
      }

      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposureMode(ExposureMode.auto);
      await Future.delayed(const Duration(milliseconds: 220));
      final imageFile = await _controller!.takePicture();
      if (needResume) {
        await Future.delayed(const Duration(milliseconds: 80));
        await _resumeImageStream();
      }
      return imageFile;
    } catch (e) {
      if (needResume) {
        await _resumeImageStream();
      }
      rethrow;
    } finally {
      _hardwareCaptureInFlight = false;
    }
  }
  
  /// 获取单帧图像（从当前图像流中获取最新一帧）
  /// 返回最新的CameraImage，如果没有流运行则返回null
  /// 
  /// 使用场景：需要从视频流中获取一帧进行处理，但不想停止流
  CameraImage? getLatestFrameFromStream() {
    if (!_isImageStreamRunning) {
      print('⚠️ 图像流未运行，无法获取最新帧');
      return null;
    }
    if (_latestImage != null) {
      print('📷 获取最新帧: ${_latestImage!.width}x${_latestImage!.height}');
    } else {
      print('⚠️ 最新帧为空');
    }
    return _latestImage;
  }

  Uint8List? getLatestFrameJpegBytes({
    Duration maxAge = const Duration(milliseconds: 450),
  }) {
    if (!_isImageStreamRunning) return null;
    final image = _latestImage;
    final at = _latestImageAt;
    if (image == null || at == null) return null;
    final age = DateTime.now().difference(at);
    if (age > maxAge) return null;
    return _cameraImageToJpegBytes(image);
  }

  /// 获取最新的相机图像（用于需要实时图像的功能）
  CameraImage? getLatestImage() {
    return _latestImage;
  }

  /// 获取流订阅者数量
  int get streamSubscriberCount => _subscribers.length;

  /// 获取所有流订阅者ID
  List<String> get streamSubscriberIds => _subscribers.keys.toList();

  /// 检查是否有活跃的流订阅者
  bool get hasActiveStreamSubscribers => _subscribers.isNotEmpty;
  
  /// 检查图像流是否正在运行
  bool get isImageStreamRunning => _isImageStreamRunning;
  
  /// 获取单帧请求计数
  int get singleFrameRequestCount => _singleFrameRequestCount;

  /// 释放所有资源
  /// 注意：只有在确定不再需要相机时才调用此方法
  Future<void> dispose() async {
    print('🗑️ 开始释放相机资源管理器...');
    
    try {
      // 关闭所有订阅者
      for (var entry in _subscribers.entries) {
        await entry.value.close();
      }
      _subscribers.clear();
      
      // 停止图像流
      await _stopImageStream();
      
      // 释放相机控制器
      if (_controller != null) {
        await _controller!.dispose();
        _controller = null;
      }
      
      _isInitialized = false;
      _selectedCamera = null;
      _latestImage = null;
      
      print('✅ 相机资源管理器已释放');
      _printCurrentStatus('资源释放完成');
    } catch (e) {
      print('❌ 释放相机资源管理器失败: $e');
      _printCurrentStatus('资源释放失败');
    }
  }

  /// 获取调试信息
  Map<String, dynamic> getDebugInfo() {
    return {
      'isInitialized': _isInitialized,
      'isInitializing': _isInitializing,
      'isImageStreamRunning': _isImageStreamRunning,
      'hasActiveStreamSubscribers': hasActiveStreamSubscribers,
      'streamSubscriberCount': streamSubscriberCount,
      'streamSubscriberIds': streamSubscriberIds,
      'singleFrameRequestCount': _singleFrameRequestCount,
      'captureQueueDepth': _captureQueue.length,
      'captureWorkerRunning': _captureWorkerRunning,
      'cameraName': _selectedCamera?.name ?? '未知',
      'previewSize': previewSize?.toString() ?? '未知',
      'usageMode': _getUsageModeDescription(),
    };
  }
  
  /// 获取使用模式描述
  String _getUsageModeDescription() {
    if (hasActiveStreamSubscribers && _singleFrameRequestCount > 0) {
      return '混合模式（流+单帧）';
    } else if (hasActiveStreamSubscribers) {
      return '流模式（仅视频流）';
    } else if (_singleFrameRequestCount > 0) {
      return '单帧模式（仅拍照）';
    } else {
      return '待机模式';
    }
  }

  /// 打印调试信息
  void printDebugInfo() {
    final info = getDebugInfo();
    print('📊 相机资源管理器状态:');
    info.forEach((key, value) {
      print('  - $key: $value');
    });
  }
}

