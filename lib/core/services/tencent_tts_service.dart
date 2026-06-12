// tencent_tts_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
//import 'dart:html';
import 'package:audioplayers/audioplayers.dart';
import 'package:tts_plugin/tts_plugin.dart';
import 'package:voicegpt/core/services/in_app_log_console.dart';

final TencentTtsService tencentTts = TencentTtsService();

void _ttsLog(String message) {
  print(message);
  InAppLogConsole.instance.add(message);
}

class TencentTtsService {
  final TTSController _controller = TTSController.instance;
  final AudioPlayer _player = AudioPlayer();
  Completer<void>? _currentCompleter;

  /// Android：下行 TTS 走 voiceCommunication，便于与 VOICE_COMMUNICATION 录音在同一 VoIP 链路上做 AEC。
  AudioContext? _androidVoicePlaybackContext;

  /// 本段播报在 [AudioPlayer] 进入 `playing` 时触发一次（尽量贴近首帧出声，而非仅合成完成）。
  VoidCallback? _onPlaybackStartedOnce;

  // 添加播放完成回调函数
  VoidCallback? onCompleted;

  void init({
    required String secretId,
    required String secretKey,
    int voiceType = 501003,
    int voiceLanguage = 1,
    double voiceSpeed = 0,
    double voiceVolume = 0,
    String codec = "mp3",
  }) {
    _controller.config = TTSControllerConfig()
      ..secretId = secretId
      ..secretKey = secretKey
      ..voiceType = voiceType
      ..voiceLanguage = voiceLanguage
      ..voiceSpeed = voiceSpeed
      ..voiceVolume = voiceVolume
      ..codec = codec;

    _controller.listener.listen((ttsData) async {
      try {
        await _player.play(BytesSource(ttsData.data));
        _ttsLog("🎵 TTS音频播放开始");
      } catch (e) {
        _ttsLog("❌ TTS音频播放失败: $e");
        _onPlaybackStartedOnce = null;
        // 播放失败时也完成Completer
        if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
          _currentCompleter!.complete();
        }
      }
    }, onError: (err) {
      if (err is TTSError) {
        _ttsLog(
          '❌ 腾讯 TTS 合成错误: code=${err.code} msg=${err.message} '
          'server=${err.serverMessage}',
        );
      } else {
        _ttsLog("❌ 腾讯 TTS 合成错误: $err");
      }
      _onPlaybackStartedOnce = null;
      // 合成错误时完成Completer
      if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
        _currentCompleter!.complete();
      }
    });

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
      _player.setAudioContext(_androidVoicePlaybackContext!).then((_) {
        _ttsLog('🎚️ [TTS] AudioPlayer setAudioContext(voiceCommunication) ok');
      }).catchError((Object e) {
        _ttsLog('🎚️ [TTS] setAudioContext failed: $e');
      });
    }

    _player.onPlayerStateChanged.listen((state) {
      _ttsLog("🎵 TTS播放器状态变化: $state");
      if (state == PlayerState.playing) {
        final once = _onPlaybackStartedOnce;
        if (once != null) {
          _onPlaybackStartedOnce = null;
          _ttsLog("🎵 [TTS] PlayerState.playing → 首帧播放回调（表情对齐）");
          once();
        }
      }
      if (state == PlayerState.completed &&
          _currentCompleter != null &&
          !_currentCompleter!.isCompleted) {
        _ttsLog("✅ TTS播放完成，正常结束");
        _currentCompleter!.complete();
        onCompleted?.call(); // 触发完成回调
      } else if (state == PlayerState.stopped &&
          _currentCompleter != null &&
          !_currentCompleter!.isCompleted) {
        _ttsLog("🛑 TTS播放被停止");
        _currentCompleter!.complete();
      }
    });
  }

  /// [onPlaybackStarted] 在底层播放器进入 `playing` 时调用一次（与首包解码更接近）。
  Future<void> speak(String text, {VoidCallback? onPlaybackStarted}) async {
    /*await stop();
    _controller.synthesize(text, "utterance_1");*/

    // === 新增：文本预处理，确保TTS能正常播报 ===
    String cleanedText = _preprocessTextForTts(text);
    _ttsLog("🎤 TTS输入文本: '$text' -> '$cleanedText'");

    await stop();
    _currentCompleter = Completer<void>();
    _onPlaybackStartedOnce = onPlaybackStarted;

    if (Platform.isAndroid && _androidVoicePlaybackContext != null) {
      try {
        await _player.setAudioContext(_androidVoicePlaybackContext!);
        _ttsLog(
            '🎚️ [TTS] speak(): refreshed AudioContext(voiceCommunication)');
      } catch (e) {
        _ttsLog('🎚️ [TTS] speak() setAudioContext: $e');
      }
    }

    // === 新增：添加超时保护和重试机制 ===
    try {
      // 使用简单的字符串作为utteranceId，避免数字被误播报
      _controller.synthesize(cleanedText, "tts_speech");

      // 修改：优化超时处理机制，允许更长的合成时间
      Timer? timeoutTimer;
      timeoutTimer = Timer(const Duration(seconds: 120), () {
        if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
          _ttsLog("⏰ TTS合成超时（120秒），强制停止播放并完成");
          // 先停止播放，再完成
          _player.stop();
          _currentCompleter!.complete();
          timeoutTimer?.cancel();
        }
      });

      // 当TTS正常完成时，取消超时计时器
      _currentCompleter!.future.then((_) {
        timeoutTimer?.cancel();
      });

      return _currentCompleter!.future;
    } catch (e) {
      _ttsLog("❌ TTS合成失败: $e");
      if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
        _currentCompleter!.complete();
      }
      rethrow;
    }
  }

  /// 视觉/长文等场景下模型常带 Markdown；腾讯云对超长 UTF-8 或特殊片段易返回 -104。
  String _stripMarkdownAndMultimodalArtifacts(String s) {
    var t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    t = t.replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1');
    t = t.replaceAll(RegExp(r'__([^_]+)__'), r'$1');
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');
    t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'\n{2,}'), '\n');
    t = t.replaceAll('\n', '。');
    t = t.replaceAll(RegExp(r'[*_`#>|\\]+'), ' ');
    return t;
  }

  /// 腾讯云单次合成常见 UTF-8 上限附近；超长易触发 Server response error（-104）。
  String _truncateToUtf8ByteLength(String s, int maxBytes) {
    final encoded = utf8.encode(s);
    if (encoded.length <= maxBytes) return s;
    var low = 0;
    var high = s.length;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (utf8.encode(s.substring(0, mid)).length <= maxBytes) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    if (low <= 0) return '内容较长，请听我简要说明。';
    return '${s.substring(0, low)}……';
  }

  /// 预处理文本，确保TTS播报质量
  String _preprocessTextForTts(String text) {
    String processed = text.trim();
    processed = _stripMarkdownAndMultimodalArtifacts(processed);
    processed = processed.replaceAll(
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\u200b-\u200f\ufeff]'), '');

    // 确保文本不为空
    if (processed.isEmpty) {
      return "我在这里";
    }

    // 检查是否包含大量数字（可能是错误的调试信息）
    if (RegExp(r'^\d{10,}$').hasMatch(processed)) {
      _ttsLog("⚠️ 检测到纯数字文本，可能是错误的调试信息: $processed");
      return "抱歉，出现了一些问题";
    }

    // 移除可能的时间戳数字（13位毫秒时间戳）
    processed = processed.replaceAll(RegExp(r'\b\d{13}\b'), '');

    // 移除可能的日志前缀和特殊字符
    processed = processed.replaceAll(RegExp(r'^[🎤🔊✅❌⚠️💬🧠🎙️]+\s*'), '');

    // 仅当整段疑似 OpenAI 类 JSON 泄漏时替换（不误伤中英混读）
    final tl = processed.trimLeft();
    if (tl.startsWith('{') &&
        tl.contains('"choices"') &&
        (tl.contains('"usage"') || tl.contains('"finish_reason"'))) {
      _ttsLog("⚠️ 检测到疑似 API JSON 整段泄漏，已替换默认句");
      return "好的，我明白了";
    }

    // 保留英文字母与常见标点，供腾讯云 / 中英混读 TTS 使用

    // === 关键修复：移除中文字符之间的空格，避免TTS播报停顿 ===
    processed = processed.replaceAllMapped(
        RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'), (match) {
      return match.group(1)! + match.group(2)!;
    });

    // 继续移除可能的多个字符间空格
    while (
        processed.contains(RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'))) {
      processed = processed.replaceAllMapped(
          RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'), (match) {
        return match.group(1)! + match.group(2)!;
      });
    }

    // 移除可能导致TTS问题的特殊符号，但保留正常的标点符号
    processed =
        processed.replaceAll(RegExp(r'[~|/><!@#$%^&*()_+=\[\]{};"\\<>]'), '');

    // 移除连续的数字串（但保留正常的数字，如"第1章"）
    processed = processed.replaceAll(RegExp(r'\b\d{6,}\b'), '');

    // 规范化空格
    processed = processed.replaceAll(RegExp(r'\s{2,}'), ' ');

    if (processed.length > 500) {
      processed = '${processed.substring(0, 500)}…';
    }

    // 最终检查：如果处理后的文本为空或只包含数字/符号，返回默认文本
    if (processed.trim().isEmpty ||
        RegExp(r'^[\d\s\p{P}]*$', unicode: true).hasMatch(processed)) {
      return "好的";
    }

    processed = processed.trim();
    processed = _truncateToUtf8ByteLength(processed, 560);
    return processed.trim();
  }

  Future<void> stop() async {
    /*await _player.stop();
    await _controller.cancel();*/
    _onPlaybackStartedOnce = null;
    if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
      _currentCompleter!.complete();
    }
    await _player.stop();
    await _controller.cancel();
    _currentCompleter = null;
  }

  Future<void> release() async {
    await stop();
    await _controller.release();
  }
}
