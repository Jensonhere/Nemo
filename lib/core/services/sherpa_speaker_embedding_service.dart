import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 使用 Sherpa-ONNX 从 PCM 提取说话人 embedding。
class SherpaSpeakerEmbeddingService {
  SherpaSpeakerEmbeddingService._();
  static final SherpaSpeakerEmbeddingService instance =
      SherpaSpeakerEmbeddingService._();

  static const String assetDir = 'assets/sherpa_speaker/';
  static const String modelFile =
      '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx';

  sherpa.SpeakerEmbeddingExtractor? _extractor;
  String? _modelPath;

  bool get isModelReady => _extractor != null;

  int get embeddingDim => _extractor?.dim ?? 0;

  Future<bool> ensureReady() async {
    if (_extractor != null) return true;
    try {
      final dir = await _copyAssetsIfNeeded();
      final modelPath = '$dir/$modelFile';
      if (!File(modelPath).existsSync()) {
        print(
          '⚠️ [Speaker] 缺少模型文件: $modelPath\n'
          '   见 assets/sherpa_speaker/README.md',
        );
        return false;
      }
      _modelPath = modelPath;
      _extractor = sherpa.SpeakerEmbeddingExtractor(
        config: sherpa.SpeakerEmbeddingExtractorConfig(
          model: modelPath,
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
      );
      print('✅ [Speaker] embedding 提取器已加载 dim=${_extractor!.dim}');
      return true;
    } catch (e, st) {
      print('❌ [Speaker] 初始化失败: $e\n$st');
      _extractor = null;
      return false;
    }
  }

  /// 从 16kHz 单声道 float PCM 提取 embedding。
  Float32List? computeFromSamples(Float32List samples,
      {int sampleRate = 16000}) {
    final ext = _extractor;
    if (ext == null || samples.isEmpty) return null;

    final stream = ext.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      stream.inputFinished();
      var spins = 0;
      while (!ext.isReady(stream) && spins < 5000) {
        spins++;
      }
      final emb = ext.compute(stream);
      if (emb.isEmpty) return null;
      return emb;
    } finally {
      stream.free();
    }
  }

  Future<String?> _copyAssetsIfNeeded() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory('${doc.path}/sherpa_speaker');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final manifestMap = json.decode(manifestContent) as Map<String, dynamic>;

    for (final key in manifestMap.keys) {
      if (!key.startsWith(assetDir)) continue;
      final relative = key.substring(assetDir.length);
      if (relative.isEmpty) continue;
      final target = File('${dir.path}/$relative');
      if (await target.exists()) continue;
      await target.parent.create(recursive: true);
      final data = await rootBundle.load(key);
      await target.writeAsBytes(data.buffer.asUint8List());
    }

    return dir.path;
  }

  void dispose() {
    _extractor?.free();
    _extractor = null;
  }
}
