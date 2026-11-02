import 'dart:async';
import 'dart:convert';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';

/// 本地 mp3 扫描与播放；与 TTS 并存时需 [pauseForTts] / [resumeAfterTtsIfPaused]。
class LocalMusicService {
  LocalMusicService._();
  static final LocalMusicService instance = LocalMusicService._();

  AudioPlayer? _player;
  bool _inited = false;
  bool _wasPlayingBeforeTts = false;
  String? _defaultAssetTrack;

  static bool isPlayMusicCommand(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    const phrases = [
      '播放音乐',
      '放音乐',
      '播音乐',
      '来首歌',
      '放首歌',
      '放点音乐',
      '听首歌',
      '听歌',
      '播个音乐',
      '播放个音乐',
      '放首歌吧',
      '随便放首歌',
      '来一段音乐',
    ];
    if (phrases.any((k) => t.contains(k))) return true;
    if (t.contains('音乐') &&
        (t.contains('放') || t.contains('播') || t.contains('听'))) {
      return true;
    }
    return false;
  }

  /// 用户指定具体歌曲/歌手时，统一返回版权与权限限制文案。
  static bool isSpecificSongRequest(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    const broadOnly = [
      '播放音乐',
      '放音乐',
      '播音乐',
      '放点音乐',
      '播个音乐',
      '播放个音乐',
      '来一段音乐',
      '听音乐',
    ];
    if (broadOnly.any((k) => t == k)) return false;
    if (t.contains('周杰伦') ||
        t.contains('林俊杰') ||
        t.contains('五月天') ||
        t.contains('邓紫棋') ||
        t.contains('歌曲') ||
        t.contains('这首歌') ||
        t.contains('那首歌') ||
        t.contains('某某歌')) {
      return true;
    }
    // 含“播放/放/播/听 + 歌/音乐”，但不是宽泛放音乐，认为是点播具体内容。
    final hasAction = t.contains('播放') || t.contains('放') || t.contains('播') || t.contains('听');
    final hasMusic = t.contains('歌') || t.contains('音乐');
    return hasAction && hasMusic && !broadOnly.any((k) => t.contains(k));
  }

  Future<void> ensureInitialized() async {
    if (_inited) return;
    _player = AudioPlayer();
    await _resolveDefaultTrackFromAssets();
    _inited = true;
  }

  Future<void> pauseForTts() async {
    await ensureInitialized();
    final pl = _player;
    if (pl == null) return;
    try {
      if (pl.playing) {
        _wasPlayingBeforeTts = true;
        await pl.pause();
      } else {
        _wasPlayingBeforeTts = false;
      }
    } catch (_) {}
  }

  Future<void> resumeAfterTtsIfPaused() async {
    if (!_wasPlayingBeforeTts) return;
    _wasPlayingBeforeTts = false;
    final pl = _player;
    if (pl == null) return;
    try {
      await pl.play();
    } catch (_) {}
  }

  Future<void> stopPlayback() async {
    final pl = _player;
    if (pl == null) return;
    try {
      await pl.stop();
    } catch (_) {}
    _wasPlayingBeforeTts = false;
  }

  /// 空闲时异步刷新资源清单（读取 AssetManifest，不阻塞对话）。
  void scheduleRescan() {
    unawaited(_resolveDefaultTrackFromAssets());
  }

  Future<void> _resolveDefaultTrackFromAssets() async {
    try {
      final raw = await rootBundle.loadString('AssetManifest.json');
      final map = json.decode(raw) as Map<String, dynamic>;
      final tracks = map.keys
          .where(
            (k) =>
                k.startsWith('assets/music/') &&
                k.toLowerCase().endsWith('.mp3'),
          )
          .toList()
        ..sort();
      if (tracks.isNotEmpty) {
        _defaultAssetTrack = tracks.first;
      } else {
        _defaultAssetTrack = null;
      }
    } catch (e) {
      _defaultAssetTrack = null;
      print('⚠️ LocalMusicService 读取 assets/music 失败: $e');
    }
  }

  Future<String?> playRandomTrack() async {
    await ensureInitialized();
    if (_defaultAssetTrack == null) {
      await _resolveDefaultTrackFromAssets();
    }
    final path = _defaultAssetTrack;
    if (path == null || path.isEmpty) return null;
    final pl = _player!;
    try {
      await pl.setAsset(path);
      await pl.play();
      return path.split('/').last;
    } catch (e) {
      print('⚠️ LocalMusicService 播放失败: $e');
      return null;
    }
  }
}
