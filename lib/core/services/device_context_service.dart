// device_context_service.dart
//
// 设备上下文服务：提供本地时间、定位、天气等信息，
// 在用户问「我在哪里」「现在几点」「今天天气如何」时注入给大模型，以便正确回答。

import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:voicegpt/app/constants/app.keys.dart';

/// 设备上下文拉取策略：默认不拉定位/天气，仅在用户话里命中相关意图时再请求（避免每轮对话阻塞）
enum DeviceContextFetchMode {
  /// 不注入设备上下文（普通闲聊/问答，最快）
  none,

  /// 仅同步注入本地时间，无网络
  localTimeOnly,

  /// api_call 链路：本机时间 + 空闲时后台缓存的定位/天气（对话轮内不再发起 HTTP）
  cachedAmbient,

  /// 定位 + 逆地理 + 天气（仅「天气怎么样」「我在哪」等）
  full,
}

/// 天气/位置缓存播报意图（由 [DeviceContextService.ambientSpeechIntent] 解析）。
class AmbientSpeechIntent {
  final bool wantsWeather;
  final bool wantsLocation;

  const AmbientSpeechIntent({
    required this.wantsWeather,
    required this.wantsLocation,
  });
}

class LocationData {
  final double latitude;
  final double longitude;
  final String? locality; // 城市/地区名
  final String? adminRegion; // 省/州
  final String? country;

  LocationData({
    required this.latitude,
    required this.longitude,
    this.locality,
    this.adminRegion,
    this.country,
  });

  String get displayName {
    final parts = [locality, adminRegion, country].where((e) => e != null && e.toString().isNotEmpty).toList();
    return parts.isEmpty ? '纬度 $latitude, 经度 $longitude' : parts.join(' ');
  }
}

class DeviceContextService {
  static const String _amapWeather =
      'https://restapi.amap.com/v3/weather/weatherInfo';
  static const String _amapReverseGeocode =
      'https://restapi.amap.com/v3/geocode/regeo';
  static const String _amapIpLocation = 'https://restapi.amap.com/v3/ip';

  static String get _amapKey => AppKeys.amapWebServiceKey.trim();
  static String get _amapKeyMask {
    if (_amapKey.isEmpty) return '(empty)';
    if (_amapKey.length <= 8) return _amapKey;
    return '${_amapKey.substring(0, 4)}***${_amapKey.substring(_amapKey.length - 4)}';
  }

  /// 根据用户说法决定拉取深度（供 TextQA / OpenAINotifier 使用）
  static DeviceContextFetchMode fetchModeForQuery(String raw) {
    final s = raw.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return DeviceContextFetchMode.none;

    const weatherLocation = [
      '天气',
      '气温',
      '温度',
      '下雨',
      '下雪',
      '刮风',
      '雾霾',
      '预报',
      '降水',
      '穿什么',
      '带伞',
      '冷不冷',
      '热不热',
      '紫外线',
      '空气质量',
      '湿度',
      '在哪',
      '位置',
      '定位',
      '地址',
      '我在哪',
      '我到哪',
      '什么地方',
      '哪个城市',
      '经纬度',
      '坐标',
      '到哪儿',
      '这里是什么地方',
      '当前城市',
      '离家',
      '附近天气',
    ];
    if (weatherLocation.any((k) => s.contains(k))) {
      return DeviceContextFetchMode.full;
    }

    const timeOnly = [
      '几点',
      '什么时间',
      '时间',
      '日期',
      '今天星期',
      '星期几',
      '几号',
      '现在几点',
      '啥时候',
      '什么时候了',
      '现在时间',
    ];
    if (timeOnly.any((k) => s.contains(k))) {
      return DeviceContextFetchMode.localTimeOnly;
    }

    return DeviceContextFetchMode.none;
  }

  /// 是否为「天气或地理位置」类问法（与 [fetchModeForQuery]==[DeviceContextFetchMode.full] 一致）。
  static bool isWeatherOrLocationAmbientQuery(String raw) =>
      fetchModeForQuery(raw) == DeviceContextFetchMode.full;

  /// 缓存直拼 TTS 时：用户更关心天气、位置或两者（与 [isWeatherOrLocationAmbientQuery] 配套使用）。
  static AmbientSpeechIntent ambientSpeechIntent(String raw) {
    final s = raw.replaceAll(RegExp(r'\s+'), '');
    const weatherHints = [
      '天气',
      '气温',
      '温度',
      '下雨',
      '下雪',
      '刮风',
      '雾霾',
      '预报',
      '降水',
      '穿什么',
      '带伞',
      '冷不冷',
      '热不热',
      '紫外线',
      '空气质量',
      '湿度',
      '附近天气',
    ];
    const locationHints = [
      '在哪',
      '位置',
      '定位',
      '地址',
      '我在哪',
      '我到哪',
      '什么地方',
      '哪个城市',
      '经纬度',
      '坐标',
      '到哪儿',
      '这里是什么地方',
      '当前城市',
      '离家',
    ];
    var wantsWeather = weatherHints.any((k) => s.contains(k));
    var wantsLocation = locationHints.any((k) => s.contains(k));
    if (isWeatherOrLocationAmbientQuery(raw) && !wantsWeather && !wantsLocation) {
      wantsWeather = true;
      wantsLocation = true;
    }
    return AmbientSpeechIntent(
      wantsWeather: wantsWeather,
      wantsLocation: wantsLocation,
    );
  }

  /// 仅本地时间（无 GPS、无天气 HTTP）
  String getLocalTimeContextBlock() {
    return '【当前设备上下文】\n当前时间：${getFormattedTime()}\n'
        '请根据当前时间自然回答用户关于时间的提问。\n';
  }

  /// 获取当前本地时间（格式化字符串）
  String getFormattedTime() {
    final now = DateTime.now();
    return '${now.year}年${now.month}月${now.day}日 ${now.hour}时${now.minute}分';
  }

  /// 获取当前定位（需已授权位置权限）
  Future<LocationData?> getCurrentLocation() async {
    try {
      print('🌦️ [DeviceCtx] 开始定位与逆地理，amapKey=$_amapKeyMask');
      bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        print('⚠️ [DeviceCtx] 定位服务未开启');
        return null;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        print('⚠️ [DeviceCtx] 无定位权限');
        return null;
      }

      // 1) 先尝试读取系统缓存位置（几乎即时，适合启动阶段预热）
      Position? pos = await Geolocator.getLastKnownPosition();
      if (pos != null) {
        print('📍 [DeviceCtx] 使用上次缓存定位 lat=${pos.latitude}, lon=${pos.longitude}');
      } else {
        print('ℹ️ [DeviceCtx] 无缓存定位，尝试实时定位');
      }

      // 2) 若无缓存，再尝试低精度快速定位（更容易在室内拿到结果）
      if (pos == null) {
        try {
          pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.low,
            timeLimit: const Duration(seconds: 6),
          );
          print('📍 [DeviceCtx] 低精度定位成功 lat=${pos.latitude}, lon=${pos.longitude}');
        } catch (e) {
          print('⚠️ [DeviceCtx] 低精度定位失败: $e');
        }
      }

      // 3) 仍失败则再试中等精度（给更长时间）
      if (pos == null) {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 18),
        );
        print('📍 [DeviceCtx] 中精度定位成功 lat=${pos.latitude}, lon=${pos.longitude}');
      }

      final loc = LocationData(
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      print('📍 [DeviceCtx] 定位成功 lat=${pos.latitude}, lon=${pos.longitude}');

      // 逆地理编码获取城市名（高德）
      final place = await _reverseGeocode(pos.latitude, pos.longitude);
      if (place != null) {
        print('🗺️ [DeviceCtx] 逆地理成功 name=${place['name']} admin=${place['admin1']} adcode=${place['adcode']}');
        return LocationData(
          latitude: pos.latitude,
          longitude: pos.longitude,
          locality: place['name'],
          adminRegion: place['admin1'],
          country: place['country'],
        );
      }
      return loc;
    } catch (e) {
      print('⚠️ [DeviceCtx] 定位失败: $e');
      return null;
    }
  }

  Future<Map<String, String?>?> _reverseGeocode(double lat, double lon) async {
    try {
      if (_amapKey.isEmpty) {
        print('⚠️ [DeviceCtx] 高德 key 未配置，跳过逆地理编码');
        return null;
      }

      final uri = Uri.parse(_amapReverseGeocode).replace(queryParameters: {
        'key': _amapKey,
        'location': '$lon,$lat',
        'extensions': 'base',
        'roadlevel': '0',
      });
      final r = await http.get(uri).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) {
        print('⚠️ [DeviceCtx] 逆地理HTTP失败 status=${r.statusCode}');
        return null;
      }
      final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>?;
      if (data == null || data['status']?.toString() != '1') {
        print(
          '⚠️ [DeviceCtx] 逆地理业务失败 status=${data?['status']} infocode=${data?['infocode']} info=${data?['info']}',
        );
        return null;
      }

      final regeocode = data['regeocode'] as Map<String, dynamic>?;
      final comp = regeocode?['addressComponent'] as Map<String, dynamic>?;
      if (comp == null) return null;
      final cityRaw = comp['city'];
      final city = cityRaw is String
          ? cityRaw
          : cityRaw is List && cityRaw.isNotEmpty
              ? cityRaw.first.toString()
              : null;
      final district = comp['district']?.toString();
      final province = comp['province']?.toString();
      final country = comp['country']?.toString() ?? '中国';
      final adcode = comp['adcode']?.toString();

      final locality = (city != null && city.isNotEmpty) ? city : district;
      return {
        'name': locality,
        'admin1': province,
        'country': country,
        'adcode': adcode,
      };
    } catch (e) {
      print('⚠️ [DeviceCtx] 逆地理编码失败: $e');
      return null;
    }
  }

  Future<Map<String, String?>?> _locateCityByIp() async {
    try {
      if (_amapKey.isEmpty) return null;
      final uri = Uri.parse(_amapIpLocation).replace(queryParameters: {
        'key': _amapKey,
        'output': 'json',
      });
      final r = await http.get(uri).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) {
        print('⚠️ [DeviceCtx] IP定位HTTP失败 status=${r.statusCode}');
        return null;
      }
      final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>?;
      if (data == null || data['status']?.toString() != '1') {
        print(
          '⚠️ [DeviceCtx] IP定位业务失败 status=${data?['status']} '
          'infocode=${data?['infocode']} info=${data?['info']}',
        );
        return null;
      }
      final adcode = data['adcode']?.toString();
      final city = data['city']?.toString();
      final province = data['province']?.toString();
      print('🌐 [DeviceCtx] IP定位成功 city=$city adcode=$adcode province=$province');
      return {
        'adcode': adcode,
        'name': city,
        'admin1': province,
      };
    } catch (e) {
      print('⚠️ [DeviceCtx] IP定位异常: $e');
      return null;
    }
  }

  Future<String?> _queryLiveWeatherByCity(String cityParam) async {
    final uri = Uri.parse(_amapWeather).replace(queryParameters: {
      'key': _amapKey,
      'city': cityParam,
      'extensions': 'base',
      'output': 'json',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) {
      print('⚠️ [DeviceCtx] 天气HTTP失败 status=${r.statusCode}');
      return null;
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>?;
    if (data == null || data['status']?.toString() != '1') {
      print(
        '⚠️ [DeviceCtx] 天气业务失败 status=${data?['status']} '
        'infocode=${data?['infocode']} info=${data?['info']}',
      );
      return null;
    }
    final lives = data['lives'] as List?;
    if (lives == null || lives.isEmpty) {
      print('⚠️ [DeviceCtx] 天气返回 lives 为空');
      return null;
    }
    final live = lives.first as Map<String, dynamic>;

    final weather = live['weather']?.toString();
    final temp = live['temperature']?.toString();
    final humidity = live['humidity']?.toString();
    final windDir = live['winddirection']?.toString();
    final windPower = live['windpower']?.toString();
    final reportTime = live['reporttime']?.toString();

    final parts = <String>[];
    if (weather != null && weather.isNotEmpty) parts.add(weather);
    if (temp != null && temp.isNotEmpty) parts.add('${temp}℃');
    if (humidity != null && humidity.isNotEmpty) parts.add('湿度${humidity}%');
    if (windDir != null &&
        windDir.isNotEmpty &&
        windPower != null &&
        windPower.isNotEmpty) {
      parts.add('${windDir}风${windPower}级');
    }
    if (reportTime != null && reportTime.isNotEmpty) {
      parts.add('更新时间$reportTime');
    }
    print('✅ [DeviceCtx] 天气查询成功 ${parts.join('，')}');
    return parts.join('，');
  }

  /// 根据经纬度获取当前天气描述（高德 weatherInfo）
  Future<String?> getCurrentWeather(double lat, double lon) async {
    try {
      if (_amapKey.isEmpty) {
        print('⚠️ [DeviceCtx] 高德 key 未配置，跳过天气请求');
        return null;
      }

      // 先用逆地理拿 adcode（天气接口 city 参数支持 adcode）
      final place = await _reverseGeocode(lat, lon);
      final adcode = place?['adcode'];
      final cityName = place?['name'];
      var weatherCity = (adcode != null && adcode.isNotEmpty) ? adcode : cityName;
      if (weatherCity == null || weatherCity.isEmpty) {
        final ipCity = await _locateCityByIp();
        weatherCity = ipCity?['adcode'] ?? ipCity?['name'];
        if (weatherCity != null && weatherCity.isNotEmpty) {
          print('ℹ️ [DeviceCtx] 使用IP定位城市作为天气查询兜底 city=$weatherCity');
        }
      }
      if (weatherCity == null || weatherCity.isEmpty) {
        print('⚠️ [DeviceCtx] 天气查询缺少 city 参数（adcode/name/IP 皆为空）');
        return null;
      }
      print('🌤️ [DeviceCtx] 天气查询 city=$weatherCity (adcode=$adcode, name=$cityName)');
      return await _queryLiveWeatherByCity(weatherCity);
    } catch (e) {
      print('⚠️ [DeviceCtx] 天气请求失败: $e');
      return null;
    }
  }

  /// 无经纬度时的天气兜底（IP 定位到城市后查实况天气）。
  Future<String?> getCurrentWeatherByIp() async {
    if (_amapKey.isEmpty) return null;
    final ipCity = await _locateCityByIp();
    final city = ipCity?['adcode'] ?? ipCity?['name'];
    if (city == null || city.isEmpty) return null;
    print('🌤️ [DeviceCtx] 仅IP兜底天气查询 city=$city');
    return _queryLiveWeatherByCity(city);
  }

  /// 无经纬度时的位置兜底（IP 估算城市）。
  Future<LocationData?> getCurrentLocationByIp() async {
    if (_amapKey.isEmpty) return null;
    final ipCity = await _locateCityByIp();
    if (ipCity == null) return null;
    final name = ipCity['name'];
    final admin1 = ipCity['admin1'];
    if ((name == null || name.isEmpty) && (admin1 == null || admin1.isEmpty)) {
      return null;
    }
    // IP 定位无法提供可靠经纬度，这里仅承载城市/省份信息，坐标置 0.
    return LocationData(
      latitude: 0,
      longitude: 0,
      locality: name,
      adminRegion: admin1,
      country: '中国',
    );
  }

  /// 获取一段可注入给大模型的「当前设备上下文」文本
  /// 包含：当前时间、当前位置（若可用）、当前天气（若可用）
  Future<String> getContextBlock() async {
    final timeStr = getFormattedTime();
    final sb = StringBuffer();
    sb.writeln('【当前设备上下文】');
    sb.writeln('当前时间：$timeStr');

    final loc = await getCurrentLocation();
    if (loc != null) {
      sb.writeln('当前位置：${loc.displayName}（纬度 ${loc.latitude}，经度 ${loc.longitude}）');
      final weather = await getCurrentWeather(loc.latitude, loc.longitude);
      if (weather != null) {
        sb.writeln('当前天气：$weather');
      }
    } else {
      sb.writeln('当前位置：无法获取（未授权或定位失败）');
    }

    sb.writeln('请根据上述上下文自然回答用户关于时间、地点、天气的提问。');
    return sb.toString();
  }
}
