import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class DetectedDesktopObject {
  const DetectedDesktopObject({
    required this.label,
    required this.confidence,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
    required this.areaRatio,
  });

  final String label;
  final double confidence;
  final double centerX;
  final double centerY;
  final double width;
  final double height;
  final double areaRatio;

  Map<String, dynamic> toJson() {
    return {
      'label': label,
      'confidence': confidence,
      'centerX': centerX,
      'centerY': centerY,
      'width': width,
      'height': height,
      'areaRatio': areaRatio,
    };
  }
}

class ObjectDetectionSnapshotResult {
  const ObjectDetectionSnapshotResult({
    required this.hasObject,
    required this.objects,
    this.imagePath,
    this.rawDetectionCount = 0,
    this.reason = '',
    this.observedAt,
  });

  final bool hasObject;
  final List<DetectedDesktopObject> objects;
  final String? imagePath;
  final int rawDetectionCount;
  final String reason;
  final DateTime? observedAt;

  Map<String, dynamic> toJson() {
    return {
      'hasObject': hasObject,
      'objects': objects.map((object) => object.toJson()).toList(),
      'imagePath': imagePath,
      'rawDetectionCount': rawDetectionCount,
      'reason': reason,
      'observedAt': observedAt?.toIso8601String(),
    };
  }
}

class DesktopObjectDetector {
  DesktopObjectDetector({
    this.modelPath = defaultModelPath,
    this.labelsPath = defaultLabelsPath,
    this.minConfidence = defaultMinConfidence,
    this.minAreaRatio = defaultMinAreaRatio,
    this.maxAreaRatio = defaultMaxAreaRatio,
    this.topK = defaultTopK,
    this.filterPerson = true,
  });

  static const String defaultModelPath =
      'assets/models/efficientdet_lite0.tflite';
  static const String defaultLabelsPath =
      'assets/models/efficientdet_coco_labels.txt';

  static const double defaultMinConfidence = 0.30;
  static const double defaultMinAreaRatio = 0.01;
  static const double defaultMaxAreaRatio = 0.45;
  static const int defaultTopK = 3;

  final String modelPath;
  final String labelsPath;
  final double minConfidence;
  final double minAreaRatio;
  final double maxAreaRatio;
  final int topK;
  final bool filterPerson;

  Interpreter? _interpreter;
  Future<void>? _initializeFuture;
  List<String> _labels = const [];
  List<int>? _inputShape;
  String? _inputType;

  bool get isReady => _interpreter != null && _labels.isNotEmpty;

  Future<void> initialize() async {
    if (isReady) {
      return;
    }
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      _interpreter = await Interpreter.fromAsset(modelPath);
      final labelsRaw = await rootBundle.loadString(labelsPath);
      _labels = labelsRaw
          .split('\n')
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toList(growable: false);

      final inputTensor = _interpreter!.getInputTensor(0);
      _inputShape = inputTensor.shape;
      _inputType = inputTensor.type.toString();
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

  Future<ObjectDetectionSnapshotResult> detectDesktopObjectsFromImagePath(
    String imagePath, {
    double? minConfidence,
    double? minAreaRatio,
    double? maxAreaRatio,
    int? topK,
    bool? filterPerson,
  }) async {
    final imageFile = File(imagePath);
    if (!await imageFile.exists()) {
      return ObjectDetectionSnapshotResult(
        hasObject: false,
        objects: const [],
        imagePath: imagePath,
        reason: 'image_not_found',
        observedAt: DateTime.now(),
      );
    }

    try {
      final imageBytes = await imageFile.readAsBytes();
      final detections = await _detectFromBytes(imageBytes);
      final effectiveTopK = _effectiveTopK(topK ?? this.topK);
      final effectiveMinConfidence = minConfidence ?? this.minConfidence;
      final effectiveMinAreaRatio = minAreaRatio ?? this.minAreaRatio;
      final effectiveMaxAreaRatio = maxAreaRatio ?? this.maxAreaRatio;
      final shouldFilterPerson = filterPerson ?? this.filterPerson;

      final objects = detections
          .where((detection) {
            if (detection.confidence < effectiveMinConfidence) {
              return false;
            }
            if (detection.areaRatio < effectiveMinAreaRatio) {
              return false;
            }
            if (detection.areaRatio > effectiveMaxAreaRatio) {
              return false;
            }
            if (shouldFilterPerson &&
                detection.label.toLowerCase().trim() == 'person') {
              return false;
            }
            return true;
          })
          .map((detection) => DetectedDesktopObject(
                label: detection.label,
                confidence: detection.confidence,
                centerX: detection.centerX,
                centerY: detection.centerY,
                width: detection.width,
                height: detection.height,
                areaRatio: detection.areaRatio,
              ))
          .toList()
        ..sort((a, b) {
          final confidenceOrder = b.confidence.compareTo(a.confidence);
          if (confidenceOrder != 0) {
            return confidenceOrder;
          }
          return b.areaRatio.compareTo(a.areaRatio);
        });

      final topObjects = objects.take(effectiveTopK).toList(growable: false);
      return ObjectDetectionSnapshotResult(
        hasObject: topObjects.isNotEmpty,
        objects: topObjects,
        imagePath: imagePath,
        rawDetectionCount: detections.length,
        reason: topObjects.isEmpty ? 'no_valid_object' : 'detected',
        observedAt: DateTime.now(),
      );
    } catch (e) {
      return ObjectDetectionSnapshotResult(
        hasObject: false,
        objects: const [],
        imagePath: imagePath,
        reason: 'detection_exception:$e',
        observedAt: DateTime.now(),
      );
    }
  }

  Future<void> close() async {
    _interpreter?.close();
    _interpreter = null;
    _inputShape = null;
    _inputType = null;
  }

  int _effectiveTopK(int requestedTopK) {
    if (requestedTopK < 1) {
      return 1;
    }
    if (requestedTopK > defaultTopK) {
      return defaultTopK;
    }
    return requestedTopK;
  }

  Future<List<_EfficientDetDetection>> _detectFromBytes(
    Uint8List imageBytes,
  ) async {
    await initialize();
    final interpreter = _interpreter;
    if (interpreter == null || _labels.isEmpty) {
      return const [];
    }

    final inputShape = _inputShape ?? interpreter.getInputTensor(0).shape;
    if (inputShape.length != 4) {
      throw StateError('Unexpected EfficientDet input shape: $inputShape');
    }

    final inputHeight = inputShape[1];
    final inputWidth = inputShape[2];
    final inputType =
        _inputType ?? interpreter.getInputTensor(0).type.toString();
    final input = inputType.contains('uint8')
        ? (await _preprocessImageToUint8(
            imageBytes,
            targetWidth: inputWidth,
            targetHeight: inputHeight,
          ))
            .reshape([1, inputHeight, inputWidth, 3])
        : (await _preprocessImageToFloat32(
            imageBytes,
            targetWidth: inputWidth,
            targetHeight: inputHeight,
          ))
            .reshape([1, inputHeight, inputWidth, 3]);

    final outputTensors = interpreter.getOutputTensors();
    if (outputTensors.length < 4) {
      throw StateError(
        'Unexpected EfficientDet output tensor count: ${outputTensors.length}',
      );
    }

    final boxesShape = outputTensors[0].shape;
    final classesShape = outputTensors[1].shape;
    final scoresShape = outputTensors[2].shape;
    final countShape = outputTensors[3].shape;

    final outputBoxes =
        Float32List(_shapeElementCount(boxesShape)).reshape(boxesShape);
    final outputClasses =
        Float32List(_shapeElementCount(classesShape)).reshape(classesShape);
    final outputScores =
        Float32List(_shapeElementCount(scoresShape)).reshape(scoresShape);
    final outputCount =
        Float32List(_shapeElementCount(countShape)).reshape(countShape);

    interpreter.runForMultipleInputs(
      [input],
      {
        0: outputBoxes,
        1: outputClasses,
        2: outputScores,
        3: outputCount,
      },
    );

    final boxes2d = _as2D(outputBoxes);
    final classes1d = _as1D(outputClasses);
    final scores1d = _as1D(outputScores);
    final numDetections =
        _readScalar(outputCount).round().clamp(0, scores1d.length).toInt();

    final detections = <_EfficientDetDetection>[];
    for (int i = 0; i < numDetections; i++) {
      final score = scores1d[i].toDouble();
      final classId = classes1d[i].round();
      if (classId < 0 || classId >= _labels.length) {
        continue;
      }

      final box = boxes2d[i];
      if (box.length < 4) {
        continue;
      }

      final ymin = box[0].toDouble().clamp(0.0, 1.0).toDouble();
      final xmin = box[1].toDouble().clamp(0.0, 1.0).toDouble();
      final ymax = box[2].toDouble().clamp(0.0, 1.0).toDouble();
      final xmax = box[3].toDouble().clamp(0.0, 1.0).toDouble();
      final width = (xmax - xmin).clamp(0.0, 1.0).toDouble();
      final height = (ymax - ymin).clamp(0.0, 1.0).toDouble();
      if (width <= 0 || height <= 0) {
        continue;
      }

      detections.add(
        _EfficientDetDetection(
          label: _labels[classId],
          confidence: score,
          x: xmin,
          y: ymin,
          width: width,
          height: height,
        ),
      );
    }

    return detections;
  }

  Future<Uint8List> _preprocessImageToUint8(
    Uint8List imageBytes, {
    required int targetWidth,
    required int targetHeight,
  }) async {
    final codec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    final rgbaData = await frame.image.toByteData();
    if (rgbaData == null) {
      throw StateError('Unable to decode image bytes for EfficientDet input.');
    }

    final pixels = rgbaData.buffer.asUint8List();
    final input = Uint8List(targetWidth * targetHeight * 3);
    int index = 0;
    for (int i = 0; i < pixels.length; i += 4) {
      input[index++] = pixels[i];
      input[index++] = pixels[i + 1];
      input[index++] = pixels[i + 2];
    }
    return input;
  }

  Future<Float32List> _preprocessImageToFloat32(
    Uint8List imageBytes, {
    required int targetWidth,
    required int targetHeight,
  }) async {
    final codec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    final rgbaData = await frame.image.toByteData();
    if (rgbaData == null) {
      throw StateError('Unable to decode image bytes for EfficientDet input.');
    }

    final pixels = rgbaData.buffer.asUint8List();
    final input = Float32List(targetWidth * targetHeight * 3);
    int index = 0;
    for (int i = 0; i < pixels.length; i += 4) {
      input[index++] = pixels[i] / 255.0;
      input[index++] = pixels[i + 1] / 255.0;
      input[index++] = pixels[i + 2] / 255.0;
    }
    return input;
  }

  int _shapeElementCount(List<int> shape) {
    var count = 1;
    for (final dimension in shape) {
      count *= dimension;
    }
    return count;
  }

  double _readScalar(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is List && value.isNotEmpty) {
      return _readScalar(value[0]);
    }
    throw StateError('Cannot read scalar from ${value.runtimeType}.');
  }

  List<List<num>> _as2D(dynamic tensor) {
    if (tensor is List && tensor.isNotEmpty && tensor[0] is List) {
      if (tensor.length == 1 && tensor[0] is List) {
        return (tensor[0] as List)
            .map((entry) => List<num>.from((entry as List).cast<num>()))
            .toList();
      }
      return tensor
          .map((entry) => List<num>.from((entry as List).cast<num>()))
          .toList();
    }
    throw StateError('Unexpected EfficientDet tensor format for boxes.');
  }

  List<num> _as1D(dynamic tensor) {
    if (tensor is List && tensor.isNotEmpty) {
      if (tensor.length == 1 && tensor[0] is List) {
        return List<num>.from((tensor[0] as List).cast<num>());
      }
      return List<num>.from(tensor.cast<num>());
    }
    throw StateError(
        'Unexpected EfficientDet tensor format for vector output.');
  }
}

class _EfficientDetDetection {
  const _EfficientDetDetection({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String label;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;
  double get areaRatio => width * height;
}
