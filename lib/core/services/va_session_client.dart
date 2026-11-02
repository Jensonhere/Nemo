import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:voicegpt/core/services/va_service_config.dart';

/// VA 会话客户端，封装实时情绪识别服务的基础接口。
///
/// 当前阶段只先把骨架接入仓库，后续再由会话管理器和语音链路调用。
class VaSessionClient {
  VaSessionClient({String? baseUrl, String? apiKey})
      : baseUrl =
            (baseUrl ?? VaServiceConfig.baseUrl).replaceAll(RegExp(r'/$'), ''),
        apiKey = (apiKey ?? VaServiceConfig.apiKey).trim();

  final String baseUrl;
  final String apiKey;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  String _shortBody(String body, {int max = 240}) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= max) return normalized;
    return '${normalized.substring(0, max)}...';
  }

  void _logRequest(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? note,
  }) {
    final maskedHeaders = <String, String>{...?headers};
    if (maskedHeaders.containsKey('X-API-Key')) {
      maskedHeaders['X-API-Key'] = '***';
    }
    print(
      '🌐 [VA][HTTP] $method $uri'
      '${note == null ? '' : ' note=$note'}'
      ' headers=$maskedHeaders',
    );
  }

  void _logResponse(
    String method,
    Uri uri,
    http.Response response,
  ) {
    final body = _shortBody(_bodyUtf8(response));
    print(
      '🌐 [VA][HTTP] $method $uri -> ${response.statusCode} '
      'contentType=${response.headers['content-type'] ?? '-'} body=$body',
    );
  }

  Map<String, String> _headers([Map<String, String>? extra]) {
    final headers = <String, String>{};
    if (apiKey.isNotEmpty) {
      headers['X-API-Key'] = apiKey;
    }
    if (extra != null) {
      headers.addAll(extra);
    }
    return headers;
  }

  Map<String, dynamic> _decodeJsonUtf8(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw StateError('VA 返回不是 JSON 对象: $text');
  }

  String _bodyUtf8(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  Never _throwNetworkContext(
    String op,
    Object error, {
    StackTrace? stackTrace,
  }) {
    final host = Uri.parse(baseUrl).host;
    final port = Uri.parse(baseUrl).hasPort ? Uri.parse(baseUrl).port : null;
    if (error is TimeoutException) {
      throw StateError('VA $op 超时: host=$host port=${port ?? "-"} error=$error');
    }
    if (error is SocketException) {
      final msg = error.message;
      final lowered = msg.toLowerCase();
      if (lowered.contains('failed host lookup') ||
          lowered.contains('name or service not known') ||
          lowered.contains('nodename nor servname provided')) {
        throw StateError('VA $op DNS解析失败: host=$host port=${port ?? "-"} error=$msg');
      }
      if (lowered.contains('connection refused')) {
        throw StateError('VA $op 连接被拒绝: host=$host port=${port ?? "-"} error=$msg');
      }
      throw StateError('VA $op 网络错误: host=$host port=${port ?? "-"} error=$msg');
    }
    Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current);
  }

  Future<bool> health({Duration timeout = const Duration(seconds: 5)}) async {
    final uri = _u('/health');
    try {
      _logRequest('GET', uri, headers: _headers());
      final response = await http
          .get(uri, headers: _headers())
          .timeout(timeout);
      _logResponse('GET', uri, response);
      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    }
  }

  Future<Map<String, dynamic>> startSession({
    Duration timeout = const Duration(seconds: 8),
    Duration retryTimeout = const Duration(seconds: 12),
  }) async {
    final uri = _u('/utterance/start');
    final headers = _headers();
    Future<http.Response> sendOnce(Duration currentTimeout) async {
      _logRequest(
        'POST',
        uri,
        headers: headers,
        note: 'timeout=${currentTimeout.inMilliseconds}ms',
      );
      return http.post(uri, headers: headers).timeout(currentTimeout);
    }

    late final http.Response response;
    try {
      response = await sendOnce(timeout);
    } on TimeoutException {
      print(
        '⚠️ [VA][HTTP] POST $uri 首次超时，准备重试 '
        'retryTimeout=${retryTimeout.inMilliseconds}ms',
      );
      try {
        response = await sendOnce(retryTimeout);
      } catch (e, st) {
        _throwNetworkContext('/utterance/start', e, stackTrace: st);
      }
    } catch (e, st) {
      _throwNetworkContext('/utterance/start', e, stackTrace: st);
    }

    _logResponse('POST', uri, response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'VA /utterance/start HTTP ${response.statusCode}: ${_bodyUtf8(response)}',
      );
    }
    return _decodeJsonUtf8(response);
  }

  Future<Map<String, dynamic>> getSession(
    String sessionId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final uri = _u('/utterance/$sessionId');
    final headers = _headers();
    late final http.Response response;
    try {
      _logRequest('GET', uri, headers: headers);
      response = await http
          .get(uri, headers: headers)
          .timeout(timeout);
    } catch (e, st) {
      _throwNetworkContext('/utterance/$sessionId', e, stackTrace: st);
    }
    _logResponse('GET', uri, response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'VA /utterance/$sessionId HTTP ${response.statusCode}: ${_bodyUtf8(response)}',
      );
    }
    return _decodeJsonUtf8(response);
  }

  Future<Map<String, dynamic>> sendAudioChunk(
    String sessionId,
    Uint8List audioBytes, {
    String filename = 'chunk.pcm',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = _u('/utterance/$sessionId/audio');
    final request = http.MultipartRequest(
      'POST',
      uri,
    );
    request.headers.addAll(_headers());
    _logRequest(
      'POST',
      uri,
      headers: request.headers,
      note: 'multipart file=$filename bytes=${audioBytes.length}',
    );
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        audioBytes,
        filename: filename,
      ),
    );
    late final http.StreamedResponse streamed;
    late final http.Response response;
    try {
      streamed = await request.send().timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } catch (e, st) {
      _throwNetworkContext('/utterance/$sessionId/audio', e, stackTrace: st);
    }
    _logResponse('POST', uri, response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'VA /utterance/$sessionId/audio HTTP ${response.statusCode}: ${_bodyUtf8(response)}',
      );
    }
    return _decodeJsonUtf8(response);
  }

  Future<Map<String, dynamic>> sendImageFrame(
    String sessionId,
    Uint8List imageBytes, {
    String filename = 'frame.jpg',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = _u('/utterance/$sessionId/image');
    final request = http.MultipartRequest(
      'POST',
      uri,
    );
    request.headers.addAll(_headers());
    _logRequest(
      'POST',
      uri,
      headers: request.headers,
      note: 'multipart file=$filename bytes=${imageBytes.length}',
    );
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        imageBytes,
        filename: filename,
      ),
    );
    late final http.StreamedResponse streamed;
    late final http.Response response;
    try {
      streamed = await request.send().timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } catch (e, st) {
      _throwNetworkContext('/utterance/$sessionId/image', e, stackTrace: st);
    }
    _logResponse('POST', uri, response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'VA /utterance/$sessionId/image HTTP ${response.statusCode}: ${_bodyUtf8(response)}',
      );
    }
    return _decodeJsonUtf8(response);
  }

  Future<Map<String, dynamic>> finishSession(
    String sessionId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = _u('/utterance/$sessionId/finish');
    final headers = _headers();
    late final http.Response response;
    try {
      _logRequest('POST', uri, headers: headers);
      response = await http
          .post(
            uri,
            headers: headers,
          )
          .timeout(timeout);
    } catch (e, st) {
      _throwNetworkContext('/utterance/$sessionId/finish', e, stackTrace: st);
    }
    _logResponse('POST', uri, response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'VA /utterance/$sessionId/finish HTTP ${response.statusCode}: ${_bodyUtf8(response)}',
      );
    }
    return _decodeJsonUtf8(response);
  }
}
