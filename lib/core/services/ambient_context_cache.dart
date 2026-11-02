import 'dart:async';

import 'package:voicegpt/core/services/device_context_service.dart';

/// 在「非对话」空闲时后台刷新定位与天气，供 [api_call] 链路注入 prompt，
/// 避免在用户说话当下再发起 HTTP 拉长首包延迟。
class AmbientContextCache {
  AmbientContextCache._();
  static final AmbientContextCache instance = AmbientContextCache._();

  bool Function()? _isAmbientRefreshAllowed;
  Timer? _timer;

  String? _locationLine;
  String? _weatherLine;
  DateTime? _lastSuccessAt;

  void configure({required bool Function() isAmbientRefreshAllowed}) {
    _isAmbientRefreshAllowed = isAmbientRefreshAllowed;
  }

  bool get hasLocation =>
      _locationLine != null && _locationLine!.trim().isNotEmpty;
  bool get hasWeather =>
      _weatherLine != null && _weatherLine!.trim().isNotEmpty;

  /// 启动周期刷新（默认 30 分钟）；单次刷新仅在 [isAmbientRefreshAllowed] 为 true 时执行。
  void startPeriodic(Duration interval) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (_isAmbientRefreshAllowed?.call() ?? true) {
        unawaited(refreshNow(force: false));
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// [force] 为 true 时忽略空闲门控（用于应用启动后尽快拉一次）。
  Future<void> refreshNow({bool force = false}) async {
    if (!force && !(_isAmbientRefreshAllowed?.call() ?? true)) {
      print('ℹ️ [AmbientCtx] 跳过刷新（当前非空闲态）');
      return;
    }
    final svc = DeviceContextService();
    try {
      print('🔄 [AmbientCtx] 开始刷新（force=$force）');
      final loc = await svc.getCurrentLocation();
      if (loc != null) {
        _locationLine =
            '当前位置：${loc.displayName}（纬度 ${loc.latitude}，经度 ${loc.longitude}）';
        final w = await svc.getCurrentWeather(loc.latitude, loc.longitude);
        _weatherLine = w != null ? '当前天气（参考）：$w' : '当前天气：暂时无法从网络获取';
        print('✅ [AmbientCtx] 刷新成功 location=${loc.displayName} weather=${w ?? "(null)"}');
      } else {
        final ipLoc = await svc.getCurrentLocationByIp();
        _locationLine = ipLoc != null
            ? '当前位置（IP估算）：${ipLoc.displayName}'
            : null;
        final w = await svc.getCurrentWeatherByIp();
        _weatherLine = w != null ? '当前天气（IP兜底）：$w' : null;
        print(
          '⚠️ [AmbientCtx] 定位为空，已走IP兜底 location=${ipLoc?.displayName ?? "(null)"} weather=${w ?? "(null)"}',
        );
      }
      _lastSuccessAt = DateTime.now();
    } catch (e) {
      print('⚠️ [AmbientCtx] 刷新异常: $e');
    }
  }

  /// 启动阶段快速预热：优先用 IP 城市 + 天气先写入缓存，避免首轮「我在哪里/天气」回答为空。
  Future<void> primeFromIpNow() async {
    final svc = DeviceContextService();
    try {
      print('🚀 [AmbientCtx] 启动预热：先走IP位置与天气');
      final ipLoc = await svc.getCurrentLocationByIp();
      final w = await svc.getCurrentWeatherByIp();
      if (ipLoc != null) {
        _locationLine = '当前位置（IP估算）：${ipLoc.displayName}';
      }
      if (w != null) {
        _weatherLine = '当前天气（IP兜底）：$w';
      }
      if (ipLoc != null || w != null) {
        _lastSuccessAt = DateTime.now();
        print(
          '✅ [AmbientCtx] 启动预热成功 location=${ipLoc?.displayName ?? "(null)"} weather=${w ?? "(null)"}',
        );
      } else {
        print('⚠️ [AmbientCtx] 启动预热未拿到IP位置与天气');
      }
    } catch (e) {
      print('⚠️ [AmbientCtx] 启动预热异常: $e');
    }
  }

  /// 拼入 system prompt 的【当前设备上下文】块（时间始终用本机 [DateTime.now]）。
  String buildPromptBlock() {
    final svc = DeviceContextService();
    final sb = StringBuffer();
    sb.writeln('【当前设备上下文】');
    sb.writeln('当前时间：${svc.getFormattedTime()}（设备本机时钟，非网络时间）');
    if (hasLocation) {
      sb.writeln(_locationLine);
    } else {
      sb.writeln('当前位置：暂无后台缓存（未定位或无权限）；不要编造具体地址。');
    }
    if (hasWeather) {
      sb.writeln(_weatherLine);
    } else {
      sb.writeln('当前天气：暂无后台缓存；可如实说明并建议稍后再问或检查网络与定位权限。');
    }
    sb.writeln('请仅基于以上事实回答与时间、位置、天气相关的问题；不要编造未提供的数据。');
    sb.writeln('天气回答默认不提缓存时间或数据来源细节（如 IP 兜底），除非用户明确追问“什么时候更新/数据从哪来”。');
    return sb.toString();
  }

  /// 仅用内存缓存拼一段可直接 TTS 的短播报（不发起 HTTP、不调 LLM）。
  /// [wantsWeather] / [wantsLocation] 由 [DeviceContextService.ambientSpeechIntent] 给出。
  String composeTtsFromCachedAmbient({
    required bool wantsWeather,
    required bool wantsLocation,
  }) {
    final svc = DeviceContextService();
    final parts = <String>[];

    String normalizeTail(String line) {
      var t = line.trim();
      final i = t.indexOf('：');
      if (i > 0 && i < t.length - 1) {
        final tail = t.substring(i + 1).trim();
        if (tail.isNotEmpty) t = tail;
      }
      return t.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    void addPart(String s) {
      final t = s.trim();
      if (t.isEmpty) return;
      parts.add(t.endsWith('。') || t.endsWith('！') || t.endsWith('？') ? t : '$t。');
    }

    addPart('当前时间是${svc.getFormattedTime()}');

    if (wantsLocation) {
      if (hasLocation && _locationLine != null && _locationLine!.trim().isNotEmpty) {
        addPart(normalizeTail(_locationLine!));
      } else {
        addPart('位置信息我这边还没有可用的后台缓存，可以稍后再问或检查一下定位权限');
      }
    }
    if (wantsWeather) {
      if (hasWeather && _weatherLine != null && _weatherLine!.trim().isNotEmpty) {
        addPart(normalizeTail(_weatherLine!));
      } else {
        addPart('天气信息暂时还没有后台缓存，可以稍后再试');
      }
    }

    return parts.join('');
  }
}
