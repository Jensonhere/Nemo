import 'dart:math' as math;
import 'dart:typed_data';

import 'package:voicegpt/core/models/owner_voiceprint_verify_result.dart';
import 'package:voicegpt/core/services/sherpa_speaker_embedding_service.dart';
import 'package:voicegpt/core/services/speaker_enrollment_store.dart';

/// 主人声纹比对（主线程 Sherpa embedding + 余弦相似度，与注册共用已加载模型）。
class OwnerVoiceprintVerifier {
  OwnerVoiceprintVerifier._();
  static final OwnerVoiceprintVerifier instance = OwnerVoiceprintVerifier._();

  static const double similarityThreshold = 0.46;

  /// 打断场景可略低于安静注册（0.25s @16kHz）。
  static const int minSamplesForVerify = 3200;

  static const int tailWindow1s = 16000;

  /// 聆听定稿最多取近 3s；打断仅近 2s 环缓冲。
  static const int maxListenVerifySamples = 48000;
  static const int maxBargeInVerifySamples = 32000;

  /// [fastBargeIn]：TTS 打断快路径（1 窗、少算力、帧间 yield，避免卡 UI）。
  Future<OwnerVoiceprintVerifyResult> verifyOwnerDetailed(
    Float32List samples, {
    bool fastBargeIn = false,
  }) async {
    final refs = SpeakerEnrollmentStore.instance.allEmbeddingsForVerify;
    if (refs.isEmpty) {
      return const OwnerVoiceprintVerifyResult(
        bestScore: null,
        pass: false,
        valid: false,
        reason: '未录入主人声纹',
      );
    }

    final cap = fastBargeIn ? maxBargeInVerifySamples : maxListenVerifySamples;
    final capped = _capTail(samples, cap);
    if (capped.length < minSamplesForVerify) {
      return OwnerVoiceprintVerifyResult(
        bestScore: null,
        pass: false,
        valid: false,
        reason: '音频过短(${capped.length}<$minSamplesForVerify)',
      );
    }

    if (!await SherpaSpeakerEmbeddingService.instance.ensureReady()) {
      return const OwnerVoiceprintVerifyResult(
        bestScore: null,
        pass: false,
        valid: false,
        reason: '声纹模型未就绪',
      );
    }

    final windows =
        fastBargeIn ? _bargeInWindows(capped) : _listenWindows(capped);
    if (windows.isEmpty) {
      return const OwnerVoiceprintVerifyResult(
        bestScore: null,
        pass: false,
        valid: false,
        reason: '无法切分有效音频窗',
      );
    }

    double? best;
    var matchedRef = -1;
    for (final w in windows) {
      await Future<void>.delayed(Duration.zero);
      final probe =
          SherpaSpeakerEmbeddingService.instance.computeFromSamples(w);
      if (probe == null) continue;

      for (var ri = 0; ri < refs.length; ri++) {
        final ref = refs[ri];
        if (probe.length != ref.length) continue;
        final s = _cosineSimilarity(probe, ref);
        if (s >= similarityThreshold) {
          print(
            '🔐 [Speaker] 主人比对 earlyPass=${s.toStringAsFixed(3)} '
            'fast=$fastBargeIn refIdx=$ri pcm=${capped.length}',
          );
          return OwnerVoiceprintVerifyResult(
            bestScore: s,
            pass: true,
            valid: true,
            reason: 'match',
          );
        }
        if (best == null || s > best) {
          best = s;
          matchedRef = ri;
        }
      }
    }

    if (best == null) {
      return const OwnerVoiceprintVerifyResult(
        bestScore: null,
        pass: false,
        valid: false,
        reason: '无法提取 embedding',
      );
    }

    final pass = best >= similarityThreshold;
    print(
      '🔐 [Speaker] 主人比对 best=${best.toStringAsFixed(3)} '
      'threshold=$similarityThreshold pass=$pass '
      'refs=${refs.length} refIdx=$matchedRef windows=${windows.length} '
      'fast=$fastBargeIn pcm=${capped.length}',
    );
    return OwnerVoiceprintVerifyResult(
      bestScore: best,
      pass: pass,
      valid: true,
      reason: pass ? 'match' : 'mismatch',
    );
  }

  Future<bool> verifyOwner(Float32List samples,
      {bool fastBargeIn = false}) async {
    final r = await verifyOwnerDetailed(samples, fastBargeIn: fastBargeIn);
    return r.pass;
  }

  static Float32List _capTail(Float32List s, int maxSamples) {
    if (s.length <= maxSamples) return s;
    return Float32List.sublistView(s, s.length - maxSamples);
  }

  static List<Float32List> _bargeInWindows(Float32List samples) {
    final tail1 = _tail(samples, tailWindow1s);
    final hi = _highestEnergySegment(tail1, windowSamples: tailWindow1s);
    if (hi.length >= minSamplesForVerify) return [hi];
    if (tail1.length >= minSamplesForVerify) return [tail1];
    return [];
  }

  static List<Float32List> _listenWindows(Float32List samples) {
    final tail1 = _tail(samples, tailWindow1s);
    final hi = _highestEnergySegment(samples, windowSamples: tailWindow1s);
    final out = <Float32List>[];
    for (final w in [hi, tail1]) {
      if (w.length >= minSamplesForVerify && !out.any((x) => identical(x, w))) {
        out.add(w);
      }
    }
    return out;
  }

  static Float32List _tail(Float32List s, int n) {
    if (s.length <= n) return s;
    return Float32List.sublistView(s, s.length - n);
  }

  static Float32List _highestEnergySegment(Float32List s,
      {required int windowSamples}) {
    if (s.length <= windowSamples) return s;
    var bestStart = s.length - windowSamples;
    var bestEnergy = -1.0;
    const hop = 1600;
    for (var start = 0; start <= s.length - windowSamples; start += hop) {
      var e = 0.0;
      final end = start + windowSamples;
      for (var i = start; i < end; i++) {
        e += s[i] * s[i];
      }
      if (e > bestEnergy) {
        bestEnergy = e;
        bestStart = start;
      }
    }
    return Float32List.sublistView(s, bestStart, bestStart + windowSamples);
  }

  static double _cosineSimilarity(Float32List a, Float32List b) {
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na <= 1e-12 || nb <= 1e-12) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}
