import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicegpt/core/models/owner_voiceprint_sample.dart';
import 'package:voicegpt/core/services/speaker_enrollment_wav.dart';

/// 本地主人声纹库：最多 3 条，含 embedding + WAV 试听文件。
class SpeakerEnrollmentStore {
  SpeakerEnrollmentStore._();
  static final SpeakerEnrollmentStore instance = SpeakerEnrollmentStore._();

  static const int maxSamples = 3;

  static const _keySamplesJson = 'owner_speaker_samples_v2';
  static const _keyActiveId = 'owner_speaker_active_sample_id';
  static const _legacyEmbeddingB64 = 'owner_speaker_embedding_b64';

  final List<_StoredSample> _samples = <_StoredSample>[];
  String? _activeId;
  Float32List? _cachedActiveEmbedding;
  String? _voiceprintsDir;

  bool get hasEnrollment =>
      _activeId != null &&
      _cachedActiveEmbedding != null &&
      _cachedActiveEmbedding!.isNotEmpty;

  int get sampleCount => _samples.length;

  Float32List? get cachedEmbedding => _cachedActiveEmbedding;

  /// 声纹库内全部 embedding（比对时取最高分，降低单条参考不稳定）。
  List<Float32List> get allEmbeddingsForVerify {
    final out = <Float32List>[];
    for (final s in _samples) {
      try {
        final e = _decodeEmbedding(s.embeddingB64);
        if (e.isNotEmpty) out.add(e);
      } catch (_) {}
    }
    return out;
  }

  String? get activeSampleId => _activeId;

  List<OwnerVoiceprintSample> get samplesForUi {
    return _samples
        .map(
          (s) => OwnerVoiceprintSample(
            id: s.id,
            label: s.label,
            durationMs: s.durationMs,
            createdAtMs: s.createdAtMs,
            hasAudio: s.wavRelativePath != null,
            isActive: s.id == _activeId,
          ),
        )
        .toList(growable: false);
  }

  Future<bool> load() async {
    final doc = await getApplicationDocumentsDirectory();
    _voiceprintsDir = '${doc.path}/owner_voiceprints';
    await Directory(_voiceprintsDir!).create(recursive: true);

    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyIfNeeded(prefs);

    _samples.clear();
    _activeId = prefs.getString(_keyActiveId);
    final raw = prefs.getString(_keySamplesJson);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            _samples.add(_StoredSample.fromJson(item));
          }
        }
      } catch (e) {
        print('⚠️ [SpeakerStore] 解析声纹库失败: $e');
        _samples.clear();
      }
    }

    _reconcileActiveId();
    _refreshActiveCache();
    return hasEnrollment;
  }

  Future<void> _migrateLegacyIfNeeded(SharedPreferences prefs) async {
    if (prefs.containsKey(_keySamplesJson)) return;
    final b64 = prefs.getString(_legacyEmbeddingB64);
    if (b64 == null || b64.isEmpty) return;

    try {
      final id = 'legacy_${DateTime.now().millisecondsSinceEpoch}';
      final sample = _StoredSample(
        id: id,
        label: '声纹 1',
        embeddingB64: b64,
        wavRelativePath: null,
        durationMs: 0,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(
        _keySamplesJson,
        jsonEncode([sample.toJson()]),
      );
      await prefs.setString(_keyActiveId, id);
      await prefs.remove(_legacyEmbeddingB64);
      await prefs.remove('owner_speaker_embedding_updated_at');
      print('✅ [SpeakerStore] 已迁移旧版单条声纹到声纹库');
    } catch (e) {
      print('⚠️ [SpeakerStore] 迁移旧声纹失败: $e');
    }
  }

  void _reconcileActiveId() {
    if (_samples.isEmpty) {
      _activeId = null;
      return;
    }
    if (_activeId == null || !_samples.any((s) => s.id == _activeId)) {
      _activeId = _samples.first.id;
    }
  }

  void _refreshActiveCache() {
    if (_activeId == null) {
      _cachedActiveEmbedding = null;
      return;
    }
    _StoredSample? found;
    for (final s in _samples) {
      if (s.id == _activeId) {
        found = s;
        break;
      }
    }
    if (found == null) {
      _cachedActiveEmbedding = null;
      return;
    }
    try {
      _cachedActiveEmbedding = _decodeEmbedding(found.embeddingB64);
    } catch (_) {
      _cachedActiveEmbedding = null;
    }
  }

  Future<String?> wavAbsolutePath(String sampleId) async {
    final s = _find(sampleId);
    if (s?.wavRelativePath == null || _voiceprintsDir == null) return null;
    final path = '$_voiceprintsDir/${s!.wavRelativePath}';
    if (!File(path).existsSync()) return null;
    return path;
  }

  /// 新增一条（最多 3 条）；返回新 id。
  Future<String?> addSample({
    required Float32List embedding,
    required Float32List pcmSamples,
    required int durationMs,
  }) async {
    if (_samples.length >= maxSamples) return null;
    await load();

    final id = 'vp_${DateTime.now().millisecondsSinceEpoch}';
    final label = '声纹 ${_samples.length + 1}';
    final wavName = '$id.wav';
    final wavFile = File('$_voiceprintsDir/$wavName');
    await wavFile.writeAsBytes(
      SpeakerEnrollmentWav.encodeFloat32Mono(pcmSamples),
      flush: true,
    );

    final sample = _StoredSample(
      id: id,
      label: label,
      embeddingB64: _encodeEmbedding(embedding),
      wavRelativePath: wavName,
      durationMs: durationMs,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _samples.add(sample);
    _activeId = id;
    await _persist();
    _refreshActiveCache();
    return id;
  }

  Future<bool> setActiveSample(String id) async {
    if (!_samples.any((s) => s.id == id)) return false;
    _activeId = id;
    await _persist();
    _refreshActiveCache();
    return true;
  }

  Future<bool> deleteSample(String id) async {
    final idx = _samples.indexWhere((s) => s.id == id);
    if (idx < 0) return false;

    final s = _samples[idx];
    if (s.wavRelativePath != null && _voiceprintsDir != null) {
      final f = File('$_voiceprintsDir/${s.wavRelativePath}');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    _samples.removeAt(idx);

    for (var i = 0; i < _samples.length; i++) {
      _samples[i] = _samples[i].copyWith(label: '声纹 ${i + 1}');
    }

    if (_activeId == id) {
      _activeId = _samples.isEmpty ? null : _samples.first.id;
    }
    await _persist();
    _refreshActiveCache();
    return true;
  }

  Future<void> clear() async {
    for (final s in List<_StoredSample>.from(_samples)) {
      if (s.wavRelativePath != null && _voiceprintsDir != null) {
        final f = File('$_voiceprintsDir/${s.wavRelativePath}');
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
    _samples.clear();
    _activeId = null;
    _cachedActiveEmbedding = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySamplesJson);
    await prefs.remove(_keyActiveId);
  }

  _StoredSample? _find(String id) {
    for (final s in _samples) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keySamplesJson,
      jsonEncode(_samples.map((e) => e.toJson()).toList()),
    );
    if (_activeId != null) {
      await prefs.setString(_keyActiveId, _activeId!);
    } else {
      await prefs.remove(_keyActiveId);
    }
  }

  static String _encodeEmbedding(Float32List e) {
    final bytes = e.buffer.asUint8List(e.offsetInBytes, e.lengthInBytes);
    return base64Encode(bytes);
  }

  static Float32List _decodeEmbedding(String b64) {
    final bytes = base64Decode(b64);
    if (bytes.length % 4 != 0) {
      throw const FormatException('invalid embedding length');
    }
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.length ~/ 4,
    );
  }
}

class _StoredSample {
  const _StoredSample({
    required this.id,
    required this.label,
    required this.embeddingB64,
    required this.wavRelativePath,
    required this.durationMs,
    required this.createdAtMs,
  });

  final String id;
  final String label;
  final String embeddingB64;
  final String? wavRelativePath;
  final int durationMs;
  final int createdAtMs;

  _StoredSample copyWith({
    String? label,
  }) {
    return _StoredSample(
      id: id,
      label: label ?? this.label,
      embeddingB64: embeddingB64,
      wavRelativePath: wavRelativePath,
      durationMs: durationMs,
      createdAtMs: createdAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'embeddingB64': embeddingB64,
        'wavRelativePath': wavRelativePath,
        'durationMs': durationMs,
        'createdAtMs': createdAtMs,
      };

  factory _StoredSample.fromJson(Map<String, dynamic> json) {
    return _StoredSample(
      id: json['id'] as String,
      label: json['label'] as String? ?? '声纹',
      embeddingB64: json['embeddingB64'] as String,
      wavRelativePath: json['wavRelativePath'] as String?,
      durationMs: json['durationMs'] as int? ?? 0,
      createdAtMs: json['createdAtMs'] as int? ?? 0,
    );
  }
}
