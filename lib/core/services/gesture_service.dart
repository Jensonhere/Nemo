import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/core/notifiers/speech_notifier_simplified.dart';
import 'package:voicegpt/core/services/camera_resource_manager.dart'
    show CameraResourceManager, CameraTaskPriority;

// 定义Method Channel和Event Channel的名称 (与原生保持一致)
const String _platformChannel = 'com.example.gesture_recognizer_app/mediapipe';
const MethodChannel _methodChannel = MethodChannel(_platformChannel);
const EventChannel _eventChannel = EventChannel('$_platformChannel/gestures');

/// 手势识别模块使用的相机流订阅者 ID（统一由 CameraResourceManager 管理）
const String _kGestureStreamSubscriberId = 'gesture_service';

// 手势结果数据类
class GestureResult {
  final String gesture;
  final double? score;
  final double? x;
  final double? y;

  GestureResult({
    required this.gesture,
    this.score,
    this.x,
    this.y,
  });

  factory GestureResult.fromMap(Map<dynamic, dynamic> map) {
    return GestureResult(
      gesture: map['gesture']?.toString() ?? 'Unknown',
      score: map['score']?.toDouble(),
      x: map['x']?.toDouble(),
      y: map['y']?.toDouble(),
    );
  }

  @override
  String toString() {
    if (x != null && y != null) {
      return 'Gesture: $gesture (Score: ${score?.toStringAsFixed(2)}, Position: (${x?.toStringAsFixed(3)}, ${y?.toStringAsFixed(3)}))';
    } else {
      return 'Gesture: $gesture (Score: ${score?.toStringAsFixed(2)})';
    }
  }
}

class GestureService {
  final BuildContext _context;
  final CameraResourceManager _cameraManager = CameraResourceManager();

  StreamSubscription<CameraImage>? _imageStreamSubscription;
  late StreamSubscription _gestureSubscription;

  bool _isInitialized = false;
  bool _isProcessingImage = false;
  Timer? _gestureProcessingCooldownTimer;

  GestureService(this._context);

  /// 初始化：通过相机资源管理器初始化相机并订阅图像流（视频流模式）
  Future<void> initializeCameraAndGestureRecognition() async {
    if (_isInitialized) {
      print('GestureService 已初始化，无需重复初始化');
      return;
    }

    try {
      // 统一通过 CameraResourceManager 初始化相机（前置、低分辨率，与手势场景匹配）
      await _cameraManager.initialize(
        preferredLens: CameraLensDirection.front,
        resolutionPreset: ResolutionPreset.low,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      // 初始化手势识别器（调用原生）
      print('🔄 正在初始化手势识别器...');
      await _methodChannel.invokeMethod('initializeRecognizer');
      print('✅ 手势识别器初始化成功');

      // 通过管理器订阅图像流，不再直接操作 Camera
      final imageStream = _cameraManager.subscribeImageStream(_kGestureStreamSubscriberId);
      _imageStreamSubscription = imageStream.listen((CameraImage image) {
        _handleImageStream(image);
      });
      print('✅ 已订阅相机图像流（手势识别）');

      _isInitialized = true;
      print('🎉 摄像头和手势识别服务初始化完成（已接入 CameraResourceManager）');
    } catch (e) {
      print('❌ 初始化摄像头和手势识别服务失败: $e');
      rethrow;
    }
  }

  /// 处理图像流
  void _handleImageStream(CameraImage image) {
    final speechNotifier =
        Provider.of<SpeechNotifierSimplified>(_context, listen: false);

    bool shouldProcessImage = false;
    if (speechNotifier.isInFollowMode) {
      shouldProcessImage = true;
    } else if (speechNotifier.isInGestureRecognitionMode &&
        !speechNotifier.isInConversationMode) {
      shouldProcessImage = true;
    }

    if (shouldProcessImage && !_isProcessingImage) {
      _processCameraImage(image);
    }
  }

  /// 处理摄像头图像（送原生识别）
  Future<void> _processCameraImage(CameraImage image) async {
    _isProcessingImage = true;
    final speechNotifier =
        Provider.of<SpeechNotifierSimplified>(_context, listen: false);
    final cooldownDuration = speechNotifier.isInFollowMode
        ? Duration(milliseconds: 150)
        : Duration(milliseconds: 500);

    _gestureProcessingCooldownTimer?.cancel();
    _gestureProcessingCooldownTimer = Timer(cooldownDuration, () {
      _isProcessingImage = false;
    });

    try {
      await _methodChannel.invokeMethod('processCameraImage', {
        'plane0': image.planes[0].bytes,
        'plane1': image.planes[1].bytes,
        'plane2': image.planes[2].bytes,
        'width': image.width,
        'height': image.height,
        'pixelStride0': image.planes[0].bytesPerPixel ?? 1,
        'rowStride0': image.planes[0].bytesPerRow,
        'pixelStride1': image.planes[1].bytesPerPixel ?? 1,
        'rowStride1': image.planes[1].bytesPerRow,
        'pixelStride2': image.planes[2].bytesPerPixel ?? 1,
        'rowStride2': image.planes[2].bytesPerRow,
      });
    } on PlatformException catch (e) {
      print("❌ 处理图像失败: '${e.message}'");
    } catch (e) {
      print("❌ 处理图像时发生未知错误: $e");
    }
  }

  /// 开始监听手势识别结果（EventChannel）
  void _startListeningForGestures() {
    _gestureSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic gestureData) {
        try {
          _handleGestureResult(gestureData);
        } catch (e) {
          print('❌ 解析手势数据出错: $e');
        }
      },
      onError: (error) {
        print('❌ 手势监听出错: $error');
      },
      cancelOnError: false,
    );
  }

  void _handleGestureResult(dynamic gestureData) {
    final speechNotifier =
        Provider.of<SpeechNotifierSimplified>(_context, listen: false);

    String recognizedGesture;
    double? x, y;

    if (gestureData is Map) {
      final gestureResult = GestureResult.fromMap(gestureData);
      recognizedGesture = gestureResult.gesture;
      x = gestureResult.x;
      y = gestureResult.y;
      if (speechNotifier.isInFollowMode ||
          recognizedGesture.toLowerCase() != 'none') {
        print('🖐️ 手势识别结果: $gestureResult');
      }
      if (x != null && y != null) {
        print('🎯 手势位置: (${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})');
      }
    } else {
      recognizedGesture = gestureData.toString();
      print('🖐️ 手势识别结果: $recognizedGesture');
    }

    speechNotifier.updateGestureRecognition(recognizedGesture, x: x, y: y);
  }

  /// 获取当前摄像头控制器（只读，用于 UI 预览；来自 CameraResourceManager）
  CameraController? get cameraController => _cameraManager.cameraController;

  bool get isInitialized => _cameraManager.isInitialized;

  bool get isProcessingImage => _isProcessingImage;

  Size? get previewSize => _cameraManager.previewSize;

  void pauseImageProcessing() {
    _isProcessingImage = true;
    print('⏸️ 手势识别图像处理已暂停');
  }

  void resumeImageProcessing() {
    _isProcessingImage = false;
    print('▶️ 手势识别图像处理已恢复');
  }

  /// 释放本模块资源：仅取消流订阅与手势监听，不释放相机（由 CameraResourceManager 统一管理）
  void dispose() {
    print('🗑️ 开始释放手势识别服务资源...');

    try {
      _gestureProcessingCooldownTimer?.cancel();

      _gestureSubscription.cancel();

      _methodChannel.invokeMethod('stopRecognizer').then((_) {
        print('✅ 手势识别器已停止');
      }).catchError((e) {
        print('⚠️ 停止手势识别器时出错: $e');
      });

      _imageStreamSubscription?.cancel();
      _imageStreamSubscription = null;
      _cameraManager.unsubscribeImageStream(_kGestureStreamSubscriberId);

      _isInitialized = false;
      print('🎉 手势识别服务资源释放完成（已取消相机流订阅）');
    } catch (e) {
      print('❌ 释放手势识别服务资源时发生错误: $e');
    }
  }

  /// 重新启动手势识别服务
  Future<void> restart() async {
    print('🔄 重新启动手势识别服务...');
    dispose();
    await Future.delayed(const Duration(milliseconds: 500));
    await initializeCameraAndGestureRecognition();
    print('✅ 手势识别服务重启完成');
  }

  Map<String, dynamic> getServiceStatus() {
    return {
      'isInitialized': isInitialized,
      'isProcessingImage': _isProcessingImage,
      'cameraName': _cameraManager.selectedCamera?.name,
      'previewSize': previewSize?.toString(),
    };
  }

  /// 单帧手势检测：通过 CameraResourceManager 拍照（内部会处理与流的互斥）
  Future<GestureResult?> detectSingleGestureFromCamera() async {
    if (!_isInitialized) {
      print('未初始化，自动初始化一次...');
      await initializeCameraAndGestureRecognition();
      if (!_isInitialized) {
        print('初始化失败');
        return null;
      }
    }
    if (!_cameraManager.isInitialized) {
      print('❌ 相机未初始化');
      return null;
    }
    try {
      final imageFile = await _cameraManager.takePicture(
        priority: CameraTaskPriority.low,
        timeout: const Duration(seconds: 3),
        keepStreamOn: true,
      );
      final gestureResultMap =
          await _methodChannel.invokeMethod('recognizeImage', {
        'path': imageFile.path,
      });
      if (gestureResultMap != null) {
        return GestureResult.fromMap(gestureResultMap);
      }
    } catch (e) {
      print("❌ 单帧手势检测失败: $e");
    }
    return null;
  }

  String getDebugInfo() {
    final status = getServiceStatus();
    return '''
手势识别服务状态:
- 已初始化: ${status['isInitialized']}
- 正在处理图像: ${status['isProcessingImage']}
- 摄像头: ${status['cameraName'] ?? '未知'}
- 预览尺寸: ${status['previewSize'] ?? '未知'}
''';
  }
}
