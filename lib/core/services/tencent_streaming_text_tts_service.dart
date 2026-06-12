import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:voicegpt/core/services/voice_tts_service.dart';

/// 腾讯云「流式文本语音合成」WebSocket 实现：
/// https://cloud.tencent.com/document/product/1073/108595
class TencentStreamingTextTtsService extends VoiceTtsService {
  TencentStreamingTextTtsService({
    required this.secretId,
    required this.secretKey,
    required this.appId,
    this.voiceType = 101028,
    this.speed = 0,
    this.volume = 0,
    this.codec = 'mp3',
    this.sampleRate = 16000,
  });

  final String secretId;
  final String secretKey;
  final int appId;
  final int voiceType;
  final double speed;
  final double volume;
  final String codec;
  final int sampleRate;

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  AudioContext? _androidVoicePlaybackContext;

  WebSocket? _ws;
  StreamSubscription? _wsSub;
  Completer<void>? _sessionDone;
  Completer<void>? _playingDone;
  final ListQueue<Uint8List> _audioQueue = ListQueue<Uint8List>();
  bool _isDequeuing = false;
  bool _receivedFinal = false;
  bool _ready = false;
  bool _completeSent = false;
  VoidCallback? _onPlaybackStartedOnce;
  String? _sessionId;
  final BytesBuilder _chunkBuffer = BytesBuilder(copy: false);
  bool _hasPlayedAnyChunk = false;

  DateTime? _streamSessionTtsStart;
  int _lastWsConnectMs = 0;
  int _lastReadyWaitMs = 0;

  @override
  bool get isLocalBackend => false;

  @override
  bool get supportsInputStreaming => true;

  @override
  VoidCallback? onCompleted;

  @override
  Future<void> prepare() async {
    if (Platform.isAndroid) {
      _androidVoicePlaybackContext = AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          defaultToSpeaker: true,
          category: AVAudioSessionCategory.playback,
          options: const [],
        ),
      );
      await _player.setAudioContext(_androidVoicePlaybackContext!);
    }
    _stateSub ??= _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.playing) {
        final once = _onPlaybackStartedOnce;
        if (once != null) {
          _onPlaybackStartedOnce = null;
          once();
        }
      }
      if ((state == PlayerState.completed || state == PlayerState.stopped) &&
          _playingDone != null &&
          !_playingDone!.isCompleted) {
        _playingDone!.complete();
      }
    });
  }

  @override
  Future<void> speak(String text, {VoidCallback? onPlaybackStarted}) async {
    await startInputStream(onPlaybackStarted: onPlaybackStarted);
    await pushInputText(text);
    await finishInputStream();
  }

  @override
  Future<void> startInputStream({VoidCallback? onPlaybackStarted}) async {
    await prepare();
    await stop();
    _onPlaybackStartedOnce = onPlaybackStarted;
    _sessionDone = Completer<void>();
    _ready = false;
    _receivedFinal = false;
    _completeSent = false;
    _sessionId = _buildSessionId();
    _audioQueue.clear();
    _chunkBuffer.clear();
    _hasPlayedAnyChunk = false;

    if (Platform.isAndroid && _androidVoicePlaybackContext != null) {
      await _player.setAudioContext(_androidVoicePlaybackContext!);
    }

    final wsUrl = _buildSignedUrl(sessionId: _sessionId!);
    final swWs = Stopwatch()..start();
    _ws = await WebSocket.connect(wsUrl);
    swWs.stop();
    _lastWsConnectMs = swWs.elapsedMilliseconds;
    print(
      '⏱️ [ConvStage][腾讯流式TTS] WebSocket.connect ${_lastWsConnectMs}ms',
    );
    _wsSub = _ws!.listen(
      _onWsEvent,
      onError: (Object e, StackTrace st) {
        print('❌ [TencentStreamTTS] ws error: $e\n$st');
        _completeSessionIfNeeded();
      },
      onDone: () {
        if (!_receivedFinal) {
          print('⚠️ [TencentStreamTTS] ws closed before FINAL');
        }
        _completeSessionIfNeeded();
      },
      cancelOnError: false,
    );

    // 等 READY 事件
    final sw = Stopwatch()..start();
    while (!_ready && sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    sw.stop();
    _lastReadyWaitMs = sw.elapsedMilliseconds;
    if (!_ready) {
      throw StateError('Tencent stream TTS READY timeout');
    }
    print(
      '⏱️ [ConvStage][腾讯流式TTS] 等 READY ${_lastReadyWaitMs}ms',
    );
    _streamSessionTtsStart = DateTime.now();
  }

  @override
  Future<void> pushInputText(String text) async {
    final ws = _ws;
    if (ws == null || !_ready) return;
    final data = text.trim();
    if (data.isEmpty) return;
    ws.add(jsonEncode({
      'session_id': _sessionId,
      'message_id': _buildMessageId(),
      'action': 'ACTION_SYNTHESIS',
      'data': data,
    }));
  }

  @override
  Future<void> finishInputStream() async {
    final ws = _ws;
    if (ws == null) return;
    if (!_completeSent) {
      _completeSent = true;
      ws.add(jsonEncode({
        'session_id': _sessionId,
        'message_id': _buildMessageId(),
        'action': 'ACTION_COMPLETE',
        'data': '',
      }));
    }
    await _sessionDone?.future;
    if (_audioQueue.isNotEmpty) {
      await _drainAudioQueue();
    }
    if (_streamSessionTtsStart != null) {
      final wall =
          DateTime.now().difference(_streamSessionTtsStart!).inMilliseconds;
      print(
        '⏱️ [ConvStage][腾讯流式TTS·本轮] 自 READY 至收尾 wall=${wall}ms '
        'connect=${_lastWsConnectMs}ms readyWait=${_lastReadyWaitMs}ms',
      );
      _streamSessionTtsStart = null;
    }
    onCompleted?.call();
  }

  void _onWsEvent(dynamic event) {
    if (event is String) {
      try {
        final obj = jsonDecode(event) as Map<String, dynamic>;
        final code = obj['code'] as int? ?? -1;
        if (code != 0) {
          print('❌ [TencentStreamTTS] code=$code message=${obj['message']}');
          _completeSessionIfNeeded();
          return;
        }
        if (obj['ready'] == 1) {
          _ready = true;
        }
        if (obj['final'] == 1) {
          _receivedFinal = true;
          _flushChunkBufferToQueue();
          _completeSessionIfNeeded();
        }
      } catch (_) {}
      return;
    }
    if (event is List<int>) {
      _chunkBuffer.add(event);
      // 首包尽快播，后续再提高块大小减少句中缝隙。
      final targetBytes = _hasPlayedAnyChunk ? 48 * 1024 : 8 * 1024;
      if (_chunkBuffer.length >= targetBytes) {
        _flushChunkBufferToQueue();
      }
      return;
    }
  }

  void _flushChunkBufferToQueue() {
    if (_chunkBuffer.length == 0) return;
    _audioQueue.add(_chunkBuffer.takeBytes());
    unawaited(_drainAudioQueue());
  }

  Future<void> _drainAudioQueue() async {
    if (_isDequeuing) return;
    _isDequeuing = true;
    try {
      while (_audioQueue.isNotEmpty) {
        final chunk = _audioQueue.removeFirst();
        _playingDone = Completer<void>();
        try {
          await _player.play(BytesSource(chunk));
          await _playingDone!.future;
          _hasPlayedAnyChunk = true;
        } catch (e) {
          print('❌ [TencentStreamTTS] chunk play error: $e');
        } finally {
          _playingDone = null;
        }
      }
    } finally {
      _isDequeuing = false;
    }
  }

  @override
  Future<void> stop() async {
    _onPlaybackStartedOnce = null;
    _completeSessionIfNeeded();
    try {
      await _wsSub?.cancel();
    } catch (_) {}
    _wsSub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _ready = false;
    _completeSent = false;
    _receivedFinal = false;
    _streamSessionTtsStart = null;
    _audioQueue.clear();
    _chunkBuffer.clear();
    if (_playingDone != null && !_playingDone!.isCompleted) {
      _playingDone!.complete();
    }
    _playingDone = null;
    await _player.stop();
  }

  @override
  Future<void> release() async {
    await stop();
    await _stateSub?.cancel();
    _stateSub = null;
    await _player.dispose();
  }

  void _completeSessionIfNeeded() {
    if (_sessionDone != null && !_sessionDone!.isCompleted) {
      _sessionDone!.complete();
    }
  }

  String _buildSignedUrl({required String sessionId}) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = ts + 600;
    final params = <String, String>{
      'Action': 'TextToStreamAudioWSv2',
      'AppId': appId.toString(),
      'SecretId': secretId,
      'Timestamp': ts.toString(),
      'Expired': expired.toString(),
      'SessionId': sessionId,
      'VoiceType': voiceType.toString(),
      'Volume': volume.toString(),
      'Speed': speed.toString(),
      'SampleRate': sampleRate.toString(),
      'Codec': codec,
      'EnableSubtitle': 'false',
    };
    final keys = params.keys.toList()..sort();
    final canonical = keys.map((k) => '$k=${params[k]}').join('&');
    final signRaw = 'GETtts.cloud.tencent.com/stream_wsv2?$canonical';
    final sig = base64Encode(
        Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(signRaw)).bytes);
    final query =
        keys.map((k) => '$k=${Uri.encodeQueryComponent(params[k]!)}').join('&');
    return 'wss://tts.cloud.tencent.com/stream_wsv2?$query&Signature=${Uri.encodeQueryComponent(sig)}';
  }

  String _buildSessionId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final r = Random().nextInt(1 << 30);
    return 'sess_${now}_$r';
  }

  String _buildMessageId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final r = Random().nextInt(1 << 20);
    return 'msg_${now}_$r';
  }
}
