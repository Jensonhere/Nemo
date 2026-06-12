import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:io';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/services/camera_resource_manager.dart'
    show CameraResourceManager, CameraTaskPriority;
import 'package:path_provider/path_provider.dart';

/// 图片分析/环境监测模块使用的相机流订阅者 ID（统一由 CameraResourceManager 管理）
const String _kCameraServiceStreamSubscriberId = 'camera_service';
const String _kVaPrebufferStreamSubscriberId = 'va_prebuffer';
const String _kMediaPipePlatformChannel =
    'com.example.gesture_recognizer_app/mediapipe';

class HumanObservation {
  const HumanObservation({
    required this.hasHuman,
    this.confidence = 0,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.areaRatio = 0,
    this.isCentered = false,
    this.widthRatio = 0,
    this.heightRatio = 0,
    this.observedAt,
  });

  final bool hasHuman;
  final double confidence;
  final double centerX;
  final double centerY;
  final double areaRatio;
  final bool isCentered;
  final double widthRatio;
  final double heightRatio;
  final DateTime? observedAt;
}

class FaceObservation {
  const FaceObservation({
    required this.hasFace,
    this.confidence = 0,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.bboxX = 0,
    this.bboxY = 0,
    this.bboxW = 0,
    this.bboxH = 0,
    this.areaRatio = 0,
    this.observedAt,
  });

  final bool hasFace;
  final double confidence;
  final double centerX;
  final double centerY;
  final double bboxX;
  final double bboxY;
  final double bboxW;
  final double bboxH;
  final double areaRatio;
  final DateTime? observedAt;
}

class CameraService {
  final CameraResourceManager _cameraManager = CameraResourceManager();
  static const MethodChannel _mediaPipeMethodChannel =
      MethodChannel(_kMediaPipePlatformChannel);

  Interpreter? _interpreter;
  bool _isReady = false;
  bool _isCameraReady = false;
  Future<void>? _initializeFuture;
  Future<void>? _cameraReadyFuture;
  Future<void>? _modelReadyFuture;
  bool _isModelReady = false;
  List<String> _labels = [];
  String imagePath = '';

  StreamController<List<dynamic>> _detectionStreamController =
      StreamController<List<dynamic>>.broadcast();
  bool _isStreaming = false;
  StreamSubscription<CameraImage>? _imageStreamSubscription;

  Function(bool)? _onHumanDetectedCallback;

  DateTime _lastInferenceTime = DateTime.now();
  int _inferenceIntervalMs = 500;
  bool _lastHumanDetectionState = false;

  static const double HUMAN_THRESHOLD = 0.5;
  static const int INPUT_SIZE = 300;
  static const String MODEL_PATH = 'assets/models/mobilenet_ssd.tflite';
  static const String LABELS_PATH = 'assets/models/label.txt';
  static const double _centeredHorizontalDeadZone = 0.075;
  static const double _centeredMinCenterY = 0.22;
  static const double _centeredMaxCenterY = 0.80;

  final OpenAI _openAI = OpenAI();

  /// 初始化：仅确保相机可用。模型改为按需懒加载，避免 VA 拍图依赖检测模型资源。
  Future<void> initialize() async {
    if (_isReady) return;
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      try {
        await _ensureCameraReady();
        _isReady = true;
        print('✅ CameraService 相机初始化成功');
      } catch (e) {
        print('❌ 初始化失败: $e');
        rethrow;
      }
    }();

    _initializeFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initializeFuture, future)) {
        _initializeFuture = null;
      }
    }
  }

  Future<void> _ensureModelReady() async {
    if (_isModelReady) return;
    final inFlight = _modelReadyFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      _interpreter = await Interpreter.fromAsset(MODEL_PATH);
      final labelData = await rootBundle.loadString(LABELS_PATH);
      _labels = labelData.split('\n').map((label) => label.trim()).toList();
      _isModelReady = true;
      print('✅ CameraService 检测模型已就绪');
    }();

    _modelReadyFuture = future;
    try {
      await future;
    } finally {
      if (identical(_modelReadyFuture, future)) {
        _modelReadyFuture = null;
      }
    }
  }

  Future<void> _ensureCameraReady() async {
    if (_isCameraReady) return;
    final inFlight = _cameraReadyFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _cameraManager
        .initialize(
      preferredLens: CameraLensDirection.front,
      resolutionPreset: ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.yuv420,
    )
        .then((_) {
      _isCameraReady = true;
      print('✅ CameraService 相机资源已就绪');
    });
    _cameraReadyFuture = future;
    try {
      await future;
    } finally {
      if (identical(_cameraReadyFuture, future)) {
        _cameraReadyFuture = null;
      }
    }
  }

  void setOnHumanDetectedCallback(Function(bool) callback) {
    _onHumanDetectedCallback = callback;
    print('✅ 设置人类检测回调函数');
  }

  /// 人类检测：通过 CameraResourceManager 拍单帧再推理（环境监测等后台路径，默认低优先级）
  Future<bool> detectHuman({
    CameraTaskPriority priority = CameraTaskPriority.low,
    Duration timeout = const Duration(seconds: 3),
    bool keepStreamOn = true,
  }) async {
    await initialize();
    await _ensureModelReady();

    try {
      final imageFile = await _cameraManager.takePicture(
        priority: priority,
        timeout: timeout,
        keepStreamOn: keepStreamOn,
      );
      final imageBytes = await imageFile.readAsBytes();

      final directory = await getApplicationDocumentsDirectory();
      imagePath =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final imageFileObj = File(imagePath);
      await imageFileObj.writeAsBytes(imageBytes);

      print('✅ 照片拍摄成功');

      final input = await _preprocessImage(imageBytes);
      final recognitions = await _runInference(input);
      final hasHuman = _parseResults(recognitions);

      print('👤 检测结果: $hasHuman');
      return hasHuman;
    } catch (e) {
      print('❌ 人类检测失败: $e');
      return false;
    }
  }

  Future<HumanObservation> detectHumanObservation({
    CameraTaskPriority priority = CameraTaskPriority.low,
    Duration timeout = const Duration(seconds: 3),
    bool keepStreamOn = true,
  }) async {
    await initialize();
    await _ensureModelReady();

    try {
      final imageFile = await _cameraManager.takePicture(
        priority: priority,
        timeout: timeout,
        keepStreamOn: keepStreamOn,
      );
      final imageBytes = await imageFile.readAsBytes();

      final directory = await getApplicationDocumentsDirectory();
      imagePath =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final imageFileObj = File(imagePath);
      await imageFileObj.writeAsBytes(imageBytes);

      final input = await _preprocessImage(imageBytes);
      final recognitions = await _runInference(input);
      return _extractBestHumanObservation(recognitions);
    } catch (e) {
      print('❌ 人体 observation 检测失败: $e');
      return const HumanObservation(hasHuman: false);
    }
  }

  Future<HumanObservation> detectHumanObservationFromImagePath(
    String imagePath,
  ) async {
    await _ensureModelReady();

    try {
      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final input = await _preprocessImage(imageBytes);
      final recognitions = await _runInference(input);
      return _extractBestHumanObservation(recognitions);
    } catch (e) {
      print('❌ 静态图人体 observation 检测失败: $e');
      return const HumanObservation(hasHuman: false);
    }
  }

  Future<FaceObservation> detectFaceObservationFromImagePath(
    String imagePath,
  ) async {
    try {
      final rawResult = await _mediaPipeMethodChannel.invokeMethod(
        'detectFaceInImage',
        {'path': imagePath},
      );
      if (rawResult is! Map || rawResult['hasFace'] != true) {
        return const FaceObservation(hasFace: false);
      }

      final bboxW = (rawResult['bboxW'] as num?)?.toDouble() ?? 0;
      final bboxH = (rawResult['bboxH'] as num?)?.toDouble() ?? 0;
      return FaceObservation(
        hasFace: true,
        confidence: (rawResult['confidence'] as num?)?.toDouble() ?? 0,
        centerX: (rawResult['centerX'] as num?)?.toDouble() ?? 0.5,
        centerY: (rawResult['centerY'] as num?)?.toDouble() ?? 0.5,
        bboxX: (rawResult['bboxX'] as num?)?.toDouble() ?? 0,
        bboxY: (rawResult['bboxY'] as num?)?.toDouble() ?? 0,
        bboxW: bboxW,
        bboxH: bboxH,
        areaRatio: bboxW * bboxH,
        observedAt: DateTime.now(),
      );
    } on PlatformException catch (e) {
      print('❌ 静态图人脸检测平台调用失败: ${e.message}');
      return const FaceObservation(hasFace: false);
    } catch (e) {
      print('❌ 静态图人脸检测失败: $e');
      return const FaceObservation(hasFace: false);
    }
  }

  Future<Uint8List> _preprocessImage(Uint8List bytes) async {
    try {
      final codec = await instantiateImageCodec(
        bytes,
        targetWidth: INPUT_SIZE,
        targetHeight: INPUT_SIZE,
      );
      final frame = await codec.getNextFrame();
      final rawImage = frame.image;

      final rgbaData = await rawImage.toByteData();
      if (rgbaData == null) throw Exception('无法获取图像数据');
      final pixels = rgbaData.buffer.asUint8List();

      final input = Uint8List(1 * INPUT_SIZE * INPUT_SIZE * 3);

      int index = 0;
      for (int i = 0; i < pixels.length; i += 4) {
        input[index++] = pixels[i];
        input[index++] = pixels[i + 1];
        input[index++] = pixels[i + 2];
      }
      return input;
    } catch (e) {
      throw Exception('图像预处理失败: $e');
    }
  }

  bool _parseResults(List<dynamic> results) {
    for (final recognition in results) {
      if (recognition['detectedClass'] == 'person' &&
          recognition['confidenceInClass'] > HUMAN_THRESHOLD) {
        return true;
      }
    }
    return false;
  }

  HumanObservation _extractBestHumanObservation(List<dynamic> results) {
    Map<dynamic, dynamic>? bestRecognition;
    double bestScore = 0;

    for (final recognition in results) {
      if (recognition is! Map) continue;
      if (recognition['detectedClass'] != 'person') continue;

      final confidence =
          (recognition['confidenceInClass'] as num?)?.toDouble() ?? 0;
      if (confidence <= HUMAN_THRESHOLD) continue;

      final rect = recognition['rect'];
      if (rect is! Map) continue;
      final width = (rect['w'] as num?)?.toDouble() ?? 0;
      final height = (rect['h'] as num?)?.toDouble() ?? 0;
      final area = width * height;
      final score = confidence * area;
      if (score > bestScore) {
        bestScore = score;
        bestRecognition = recognition;
      }
    }

    if (bestRecognition == null) {
      return const HumanObservation(hasHuman: false);
    }

    final rect = bestRecognition['rect'] as Map<dynamic, dynamic>;
    final x = (rect['x'] as num?)?.toDouble() ?? 0;
    final y = (rect['y'] as num?)?.toDouble() ?? 0;
    final width = (rect['w'] as num?)?.toDouble() ?? 0;
    final height = (rect['h'] as num?)?.toDouble() ?? 0;
    final centerX = x + width / 2;
    final centerY = y + height / 2;

    return HumanObservation(
      hasHuman: true,
      confidence:
          (bestRecognition['confidenceInClass'] as num?)?.toDouble() ?? 0,
      centerX: centerX,
      centerY: centerY,
      areaRatio: width * height,
      isCentered: (centerX - 0.5).abs() <= _centeredHorizontalDeadZone &&
          centerY >= _centeredMinCenterY &&
          centerY <= _centeredMaxCenterY,
      widthRatio: width,
      heightRatio: height,
      observedAt: DateTime.now(),
    );
  }

  Future<List<dynamic>> _runInference(Uint8List input) async {
    try {
      await _ensureModelReady();
      final inputTensor = input.reshape([1, INPUT_SIZE, INPUT_SIZE, 3]);

      final outputLocations = Float32List(1 * 10 * 4).reshape([1, 10, 4]);
      final outputClasses = Float32List(1 * 10).reshape([1, 10]);
      final outputScores = Float32List(1 * 10).reshape([1, 10]);
      final outputCount = Float32List(1).reshape([1]);

      _interpreter!.runForMultipleInputs(
        [inputTensor],
        {0: outputLocations, 1: outputClasses, 2: outputScores, 3: outputCount},
      );

      List<dynamic> recognitions = [];

      for (int i = 0; i < 10; i++) {
        double confidence = outputScores[0][i];
        if (confidence < 0.1) continue;

        int classIndex = outputClasses[0][i].toInt();
        if (classIndex < 0 || classIndex >= _labels.length) continue;

        List<double> location = outputLocations[0][i].cast<double>();
        double ymin = location[0];
        double xmin = location[1];
        double ymax = location[2];
        double xmax = location[3];

        double x = xmin;
        double y = ymin;
        double width = xmax - xmin;
        double height = ymax - ymin;

        recognitions.add({
          "rect": {"x": x, "y": y, "w": width, "h": height},
          "detectedClass": _labels[classIndex],
          "confidenceInClass": confidence,
        });
      }
      return recognitions;
    } catch (e) {
      throw Exception('推理失败: $e');
    }
  }

  /// 开始实时检测：订阅 CameraResourceManager 的图像流，在回调中做推理并推流
  Future<Stream<List<dynamic>>> startRealTimeDetection() async {
    await initialize();
    await _ensureModelReady();

    if (_isStreaming && _imageStreamSubscription != null) {
      return _detectionStreamController.stream;
    }

    _isStreaming = true;

    final imageStream =
        _cameraManager.subscribeImageStream(_kCameraServiceStreamSubscriberId);
    _imageStreamSubscription = imageStream.listen((CameraImage image) async {
      if (!_isStreaming) return;

      final now = DateTime.now();
      final elapsedMs = now.difference(_lastInferenceTime).inMilliseconds;
      if (elapsedMs < _inferenceIntervalMs) return;
      _lastInferenceTime = now;

      try {
        if (image.format.group != ImageFormatGroup.yuv420) {
          throw Exception('不支持的图像格式，期望 YUV420');
        }
        final input = await _convertYUV420ToRGB(image);
        final recognitions = await _runInference(input);

        _detectionStreamController.add(recognitions);

        final hasHuman = isUserCentered(recognitions);
        if (hasHuman != _lastHumanDetectionState &&
            _onHumanDetectedCallback != null) {
          _lastHumanDetectionState = hasHuman;
          _onHumanDetectedCallback!(hasHuman);
        }
      } catch (e) {
        print('❌ 实时检测错误: $e');
      }
    });

    return _detectionStreamController.stream;
  }

  void stopRealTimeDetection() {
    _isStreaming = false;
    _imageStreamSubscription?.cancel();
    _imageStreamSubscription = null;
    _cameraManager.unsubscribeImageStream(_kCameraServiceStreamSubscriberId);
    _lastHumanDetectionState = false;
  }

  Future<Uint8List> _convertYUV420ToRGB(CameraImage image) async {
    return await compute(_convertYUV420ToModelInputIsolate, {
      'yData': image.planes[0].bytes,
      'uData': image.planes[1].bytes,
      'vData': image.planes[2].bytes,
      'width': image.width,
      'height': image.height,
      'yStride': image.planes[0].bytesPerRow,
      'uStride': image.planes[1].bytesPerRow,
      'vStride': image.planes[2].bytesPerRow,
      'targetSize': INPUT_SIZE,
    });
  }

  static Uint8List _convertYUV420ToModelInputIsolate(
      Map<String, dynamic> params) {
    final yData = params['yData'] as Uint8List;
    final uData = params['uData'] as Uint8List;
    final vData = params['vData'] as Uint8List;
    final width = params['width'] as int;
    final height = params['height'] as int;
    final yStride = params['yStride'] as int;
    final uStride = params['uStride'] as int;
    final vStride = params['vStride'] as int;
    final targetSize = params['targetSize'] as int;

    final rgbBytes = Uint8List(targetSize * targetSize * 3);
    final scaleX = width / targetSize;
    final scaleY = height / targetSize;
    int rgbIndex = 0;

    for (int y = 0; y < targetSize; y++) {
      for (int x = 0; x < targetSize; x++) {
        final srcX = (x * scaleX).toInt().clamp(0, width - 1);
        final srcY = (y * scaleY).toInt().clamp(0, height - 1);
        final yValue = yData[srcY * yStride + srcX];
        final uIndex = (srcY ~/ 2) * uStride + (srcX ~/ 2);
        final vIndex = (srcY ~/ 2) * vStride + (srcX ~/ 2);
        final uValue = uData[uIndex];
        final vValue = vData[vIndex];
        int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
        int g = (yValue - 0.344 * (uValue - 128) - 0.714 * (vValue - 128))
            .round()
            .clamp(0, 255);
        int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);
        rgbBytes[rgbIndex++] = r;
        rgbBytes[rgbIndex++] = g;
        rgbBytes[rgbIndex++] = b;
      }
    }
    return rgbBytes;
  }

  bool isUserCentered(List<dynamic> recognitions) {
    for (final recognition in recognitions) {
      if (recognition['detectedClass'] == 'person' &&
          recognition['confidenceInClass'] > HUMAN_THRESHOLD) {
        final rect = recognition['rect'];
        double x = rect['x'];
        double y = rect['y'];
        double w = rect['w'];
        double h = rect['h'];
        double centerX = x + w / 2;
        double centerY = y + h / 2;
        const double centerThreshold = 0.7;
        double minX = 0.5 - centerThreshold / 2;
        double maxX = 0.5 + centerThreshold / 2;
        double minY = 0.5 - centerThreshold / 2;
        double maxY = 0.5 + centerThreshold / 2;
        if (centerX >= minX &&
            centerX <= maxX &&
            centerY >= minY &&
            centerY <= maxY) {
          return true;
        }
      }
    }
    return false;
  }

  /// 拍照并保存到 imagePath：通过 CameraResourceManager 拍单帧
  Future<String> captureImage({
    CameraTaskPriority priority = CameraTaskPriority.normal,
    Duration timeout = const Duration(seconds: 3),
    bool keepStreamOn = true,
  }) async {
    await _ensureCameraReady();
    try {
      final imageFile = await _cameraManager.takePicture(
        priority: priority,
        timeout: timeout,
        keepStreamOn: keepStreamOn,
      );
      final bytes = await imageFile.readAsBytes();

      final directory = await getApplicationDocumentsDirectory();
      imagePath =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = File(imagePath);
      await file.writeAsBytes(bytes);

      print('📸 拍照完成: $imagePath');
      return imagePath;
    } catch (e) {
      throw Exception('拍照失败: $e');
    }
  }

  /// 供 VA 上传使用：直接返回 JPEG 字节，避免重复落盘增加延时。
  Future<Uint8List> captureImageBytes({
    CameraTaskPriority priority = CameraTaskPriority.normal,
    Duration timeout = const Duration(seconds: 2),
    bool keepStreamOn = true,
  }) async {
    await _ensureCameraReady();
    try {
      final imageFile = await _cameraManager.takePicture(
        priority: priority,
        timeout: timeout,
        keepStreamOn: keepStreamOn,
      );
      final bytes = await imageFile.readAsBytes();
      imagePath = imageFile.path;
      print('📸 [VA] 捕获图像字节成功 bytes=${bytes.length}');
      return bytes;
    } catch (e) {
      throw Exception('拍照字节获取失败: $e');
    }
  }

  Uint8List? getLatestStreamFrameJpegBytes({
    Duration maxAge = const Duration(milliseconds: 450),
  }) {
    return _cameraManager.getLatestFrameJpegBytes(maxAge: maxAge);
  }

  Future<Stream<CameraImage>> subscribeVaPrebufferStream() async {
    await _ensureCameraReady();
    return _cameraManager.subscribeImageStream(_kVaPrebufferStreamSubscriberId);
  }

  Future<void> unsubscribeVaPrebufferStream() async {
    await _cameraManager
        .unsubscribeImageStream(_kVaPrebufferStreamSubscriberId);
  }

  Future<bool> detectGestureByVisionModel() async {
    if (imagePath.isEmpty) {
      throw Exception('没有可用的图片，请先调用 captureImage()');
    }
    try {
      final prompt = '''
请判断图片中是否存在明显的人体手势（如张开手掌、握拳、点赞、OK、比V/胜利、数字手势等）。
只输出JSON，格式如下：{"has_gesture": true|false, "gesture": "标签或unknown"}。不要输出其它内容。
''';

      final resp = await _openAI.generateImageText(prompt, imagePath);
      final text = resp['choices'][0]['message']['content'].toString();
      print('🧠 视觉判断手势响应: $text');

      bool hasGesture = false;
      try {
        final json = jsonDecode(text);
        if (json is Map && json.containsKey('has_gesture')) {
          final v = json['has_gesture'];
          hasGesture = v == true ||
              (v is String && (v.toLowerCase() == 'true' || v == '1'));
        }
      } catch (_) {
        final lower = text.toLowerCase();
        if (lower.contains('手势') ||
            lower.contains('gesture') ||
            lower.contains('手掌') ||
            lower.contains('握拳') ||
            lower.contains('点赞') ||
            lower.contains('ok') ||
            lower.contains('胜利') ||
            lower.contains('比v') ||
            lower.contains('open_palm') ||
            lower.contains('fist') ||
            lower.contains('thumb') ||
            lower.contains('victory')) {
          hasGesture = true;
        }
      }

      print('🤚 视觉判断是否有手势: $hasGesture');
      return hasGesture;
    } catch (e) {
      throw Exception('视觉手势判断失败: $e');
    }
  }

  Future<String> detectFaceEmotion() async {
    try {
      final prompt = '''
        请识别图片中人类的面部表情，分析其最可能的情绪特征，并从下面的情绪标签中选择对应的一个返回。
        情绪标签：['开心','难过','惊讶','愤怒','平常']，
        若没有对应的情绪标签，请返回'其他'。
      ''';
      final labels = ['开心', '难过', '惊讶', '愤怒', '平常', '其他'];
      await captureImage();
      final response = await _openAI.generateImageText(
        prompt,
        imagePath,
      );
      final responseText =
          response['choices'][0]['message']['content'].toString();

      for (var label in labels) {
        if (responseText.contains(label)) {
          print('😊 面部表情检测结果: $label');
          return label;
        }
      }
      return '其他';
    } catch (e) {
      throw Exception('❌ 人脸表情检测失败: $e');
    }
  }

  /// 释放本模块资源：取消流订阅、关闭解释器；不释放相机（由 CameraResourceManager 统一管理）
  Future<void> dispose() async {
    try {
      if (_isStreaming) {
        stopRealTimeDetection();
      }
      if (_interpreter != null) {
        _interpreter!.close();
        _interpreter = null;
      }
      _isReady = false;
      _isCameraReady = false;
      _isModelReady = false;
      _modelReadyFuture = null;
      _onHumanDetectedCallback = null;
    } catch (e) {
      print('CameraService dispose error: $e');
    }
  }
}
