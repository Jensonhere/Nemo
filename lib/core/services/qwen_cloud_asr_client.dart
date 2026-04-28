import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:voicegpt/core/services/qwen_asr_config.dart';

/// Qwen ASR HTTP 客户端（/api/start、/api/chunk、/api/finish）
class QwenCloudAsrClient {
  QwenCloudAsrClient({String? baseUrl})
      : baseUrl = (baseUrl ?? QwenAsrConfig.baseUrl).replaceAll(RegExp(r'/$'), '');

  final String baseUrl;

  Uri _u(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// 接口返回多为 UTF-8 JSON，但 [http.Response.body] 在缺少 charset 时按 **Latin-1** 解码，
  /// 会导致中文识别结果变成 `æçæä¸...` 类乱码，故统一用 UTF-8 解 [bodyBytes]。
  Map<String, dynamic> _decodeJsonUtf8(http.Response r) {
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  String _bodyUtf8(http.Response r) =>
      utf8.decode(r.bodyBytes, allowMalformed: true);

  Future<bool> healthz({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final r = await http.get(_u('/healthz')).timeout(timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> startSession({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final r = await http
        .post(
          _u('/api/start'),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'language': '',
            'context': '',
            'sample_rate': 16000,
            'audio_format': 'pcm_s16le',
          }),
        )
        .timeout(timeout);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw StateError(
        'Qwen ASR /api/start HTTP ${r.statusCode}: ${_bodyUtf8(r)}',
      );
    }
    final map = _decodeJsonUtf8(r);
    final sid = map['session_id']?.toString();
    if (sid == null || sid.isEmpty) {
      throw StateError('Qwen ASR /api/start 无 session_id: ${r.body}');
    }
    return sid;
  }

  Future<Map<String, dynamic>> sendChunk(
    String sessionId,
    Uint8List pcmBytes, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final r = await http
        .post(
          _u('/api/chunk', {'session_id': sessionId}),
          headers: {'Content-Type': 'application/octet-stream'},
          body: pcmBytes,
        )
        .timeout(timeout);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw StateError(
        'Qwen ASR /api/chunk HTTP ${r.statusCode}: ${_bodyUtf8(r)}',
      );
    }
    return _decodeJsonUtf8(r);
  }

  Future<Map<String, dynamic>> finishSession(
    String sessionId, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final r = await http
        .post(_u('/api/finish', {'session_id': sessionId}))
        .timeout(timeout);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw StateError(
        'Qwen ASR /api/finish HTTP ${r.statusCode}: ${_bodyUtf8(r)}',
      );
    }
    return _decodeJsonUtf8(r);
  }
}
