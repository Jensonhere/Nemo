import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// 设备响应事件基类
abstract class DeviceResponseEvent {}

// 运动开始事件
class MotionStartedEvent extends DeviceResponseEvent {
  final int command;
  MotionStartedEvent(this.command);
}

// 运动完成事件
class MotionCompletedEvent extends DeviceResponseEvent {
  final int command;
  MotionCompletedEvent(this.command);
}

// 运动被中断事件
class MotionInterruptedEvent extends DeviceResponseEvent {
  final int command;
  final int obstacleType; // 障碍类型
  final String obstacleDescription;

  MotionInterruptedEvent(
      this.command, this.obstacleType, this.obstacleDescription);
}

// 传感器状态事件
class SensorStatusEvent extends DeviceResponseEvent {
  final bool frontObstacle;
  final bool rearObstacle;
  final bool frontCliff;
  final bool rearCliff;

  SensorStatusEvent({
    required this.frontObstacle,
    required this.rearObstacle,
    required this.frontCliff,
    required this.rearCliff,
  });
}

/// 前进/后退直线运动结束方式（依赖 MCU 回包 byte2：0x02 完成 / 0x03 传感器中断）
enum LinearMotionEndKind {
  completed,
  interrupted,
  timedOut,
}

class LinearMotionFeedback {
  const LinearMotionFeedback(this.kind, {this.obstacleType = 0});

  final LinearMotionEndKind kind;

  /// 仅 [LinearMotionEndKind.interrupted] 时有效，与 [MotionInterruptedEvent.obstacleType] 一致
  final int obstacleType;
}

class MyBluetoothService extends ChangeNotifier {
  static const bool kEnableFrontSafetyRecover = true;
  static const bool kEnableRearSafetyRecover = true;
  static const int _frontSafetyBackoffTotalMm = 50;
  static const List<int> _frontSafetyBackoffStepsMm = <int>[20, 20, 10];
  static const int _rearSafetyBackoffTotalMm = 50;
  static const List<int> _rearSafetyBackoffStepsMm = <int>[20, 20, 10];
  static const int kFrontSafetyRecoverDistanceMm = _frontSafetyBackoffTotalMm;
  static const int kRearSafetyRecoverDistanceMm = _rearSafetyBackoffTotalMm;
  static const Duration kFrontSafetyRecoverSettleDelay =
      Duration(milliseconds: 150);
  static const Duration _safetyRecoverStepTimeout = Duration(seconds: 4);
  static const int _repeatedCliffWindowMs = 1000;
  static const int _rotationValueScale = 4;
  static const int _rotationPacketMaxValue = 180;

  static const String SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String CHARACTERISTIC_UUID_RX =
      "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  static const String CHARACTERISTIC_UUID_TX =
      "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<int>>? _txValueSubscription;
  BluetoothCharacteristic? _rxCharacteristic; // 写入
  BluetoothCharacteristic? _txCharacteristic; // 通知
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  // 事件流控制器
  final StreamController<DeviceResponseEvent> _responseStreamController =
      StreamController<DeviceResponseEvent>.broadcast();

  // 暴露的事件流
  Stream<DeviceResponseEvent> get responseStream =>
      _responseStreamController.stream;

  // 记录当前是否正在执行命令
  bool _isExecutingCommand = false;

  // 记录当前命令类型
  int? _currentCommand;
  bool _isAutoRecoveringFromObstacle = false;
  bool _edgeRiskHigh = false;
  bool _wheelMayBeOffTable = false;
  bool _lastSafetyRecoverFailed = false;
  int? _lastSafetyRecoverObstacleType;
  DateTime? _lastSafetyRecoverAt;
  final List<DateTime> _recentCliffInterrupts = <DateTime>[];
  Timer? _autoReconnectTimer;
  Timer? _retryConnectTimer;

  bool get isSafetyRecovering => _isAutoRecoveringFromObstacle;
  bool get edgeRiskHigh => _edgeRiskHigh;
  bool get wheelMayBeOffTable => _wheelMayBeOffTable;
  bool get lastSafetyRecoverFailed => _lastSafetyRecoverFailed;
  int? get lastSafetyRecoverObstacleType => _lastSafetyRecoverObstacleType;
  DateTime? get lastSafetyRecoverAt => _lastSafetyRecoverAt;

  // 连接设备
  Future<void> connect(String deviceName) async {
    try {
      print("🔍 开始扫描设备: $deviceName ...");
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      // 监听扫描结果
      final results = await FlutterBluePlus.scanResults.firstWhere((results) {
        return results.any((r) =>
            r.device.name.isNotEmpty &&
            r.device.name.toLowerCase().contains(deviceName.toLowerCase()));
      });

      // 找到目标设备
      final target = results.firstWhere((r) =>
          r.device.name.toLowerCase().contains(deviceName.toLowerCase()));
      _device = target.device;
      await FlutterBluePlus.stopScan();

      print("✅ 找到设备: ${_device!.name}, 尝试连接...");
      await _device!.connect(autoConnect: false);
      _retryConnectTimer?.cancel();
      _retryConnectTimer = null;
      _isConnected = true;
      notifyListeners();

      // 监听断开事件
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = _device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          print("⚠️ 设备断开，准备重连...");
          _isConnected = false;
          notifyListeners();
          _rxCharacteristic = null;
          _txCharacteristic = null;
          _clearExecutingCommandTracking();
          _retryConnect(deviceName);
        }
      });

      // 发现服务
      List<BluetoothService> services = await _device!.discoverServices();
      for (var service in services) {
        print('发现服务 UUID: ${service.uuid}');
        for (var characteristic in service.characteristics) {
          print('发现特征值 UUID: ${characteristic.uuid}');

          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID_RX) {
            _rxCharacteristic = characteristic;
          }
          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID_TX) {
            _txCharacteristic = characteristic;
            await _txCharacteristic!.setNotifyValue(true);
            await _txValueSubscription?.cancel();
            _txValueSubscription = _txCharacteristic!.lastValueStream.listen(
              (data) => _handleDeviceResponse(Uint8List.fromList(data)),
            );
          }
        }
      }

      if (_rxCharacteristic == null) {
        throw Exception("❌ 未找到写入特征值 (RX)");
      }
      print("✅ 蓝牙连接成功，特征值已找到");
    } catch (e) {
      print("蓝牙连接失败: $e");
      _isConnected = false;
      notifyListeners();
      rethrow;
    }
  }

  // 处理设备返回的数据
  void _handleDeviceResponse(Uint8List data) {
    // 忽略空数据包（可能是心跳包或初始化信号）
    if (data.isEmpty) {
      return; // 静默处理，不输出日志
    }

    print("📩 收到设备返回: ${data.join(' ')}");

    if (data.length == 1 && data[0] == 0x66) {
      print("[BT_ACK] single_byte_ack");
      return;
    }

    // 检查数据长度和基本格式
    if (data.length != 5) {
      print("⚠️ 无效数据长度: ${data.length}");
      return;
    }

    if (data[0] != 0x66 || data[4] != 0xEE) {
      print("⚠️ 数据格式错误: 起始/结束字节无效");
      return;
    }

    // 解析命令类型
    final byte1 = data[1];
    final byte2 = data[2];
    final byte3 = data[3];

    // 处理运动相关响应
    if (byte1 == _currentCommand && _isExecutingCommand) {
      if (byte2 == 0x01) {
        _responseStreamController.add(MotionStartedEvent(byte1));
        print("🚀 运动开始: ${_commandToString(byte1)}");
      } else if (byte2 == 0x02) {
        _clearExecutingCommandTracking();
        _responseStreamController.add(MotionCompletedEvent(byte1));
        print("🏁 运动完成: ${_commandToString(byte1)}");
      } else if (byte2 == 0x03) {
        _clearExecutingCommandTracking();
        final obstacleInfo = _parseObstacleType(byte3);
        _responseStreamController
            .add(MotionInterruptedEvent(byte1, byte3, obstacleInfo));
        print("🛑 运动中断: ${_commandToString(byte1)}, 原因: $obstacleInfo");
        print(
          "[BT_SAFE] motion_interrupted "
          "command=${_commandToString(byte1)} "
          "obstacleType=0x${byte3.toRadixString(16).toUpperCase()} "
          "obstacleDescription=$obstacleInfo",
        );
        if (_isCliffObstacleType(byte3)) {
          _registerCliffInterrupt();
        }
        if (byte3 >= 0x01 && byte3 <= 0x04) {
          unawaited(_autoRecoverFromObstacle(byte3));
        }
      }
    }
    // 处理传感器查询响应
    else {
      if (byte3 != 0xEE) {
        print("⚠️ 数据格式错误: 传感器响应消息次尾字节无效");
        return;
      }

      // 解析传感器状态 (高位在前)
      final frontObstacle = (byte1 & 0xF0) == 0xE0; // W (前4位)，前面有障碍
      final rearObstacle = (byte1 & 0x0F) == 0x0E; // X (后4位)，后面有障碍
      final frontCliff = (byte2 & 0xF0) == 0xE0; // Y (前4位)，前面有悬崖
      final rearCliff = (byte2 & 0x0F) == 0x0E; // Z (后4位)，后面有悬崖

      _responseStreamController.add(SensorStatusEvent(
        frontObstacle: frontObstacle,
        rearObstacle: rearObstacle,
        frontCliff: frontCliff,
        rearCliff: rearCliff,
      ));

      print("📡 传感器状态: "
          "前障碍: ${frontObstacle ? '有' : '无'}, "
          "后障碍: ${rearObstacle ? '有' : '无'}, "
          "前悬崖: ${frontCliff ? '有' : '无'}, "
          "后悬崖: ${rearCliff ? '有' : '无'}");
      if (rearCliff) {
        print(
          "[BT_SAFE] rear_cliff_reported "
          "source=sensor_query ignored_for_auto_recover",
        );
      }
    }
  }

  // 解析障碍类型
  String _parseObstacleType(int type) {
    switch (type) {
      case 0x01:
        return "前面障碍";
      case 0x02:
        return "后面障碍";
      case 0x03:
        return "前面悬崖";
      case 0x04:
        return "后面悬崖";
      default:
        return "未知障碍 (0x${type.toRadixString(16).toUpperCase()})";
    }
  }

  // 命令值转字符串
  String _commandToString(int command) {
    switch (command) {
      case 0x00:
        return "停止";
      case 0x01:
        return "前进";
      case 0x02:
        return "后退";
      case 0x03:
        return "左转";
      case 0x04:
        return "右转";
      case 0x05:
        return "持续前进";
      case 0x06:
        return "持续后退";
      case 0x10:
        return "脑袋角度";
      case 0x11:
        return "查询传感器";
      default:
        return "未知命令 (0x${command.toRadixString(16).toUpperCase()})";
    }
  }

  void _clearExecutingCommandTracking() {
    _isExecutingCommand = false;
    _currentCommand = null;
  }

  String _obstacleTypeTag(int obstacleType) {
    switch (obstacleType) {
      case 0x01:
        return 'front_obstacle';
      case 0x02:
        return 'rear_obstacle';
      case 0x03:
        return 'front_cliff';
      case 0x04:
        return 'rear_cliff';
      default:
        return 'unknown';
    }
  }

  bool _isCliffObstacleType(int obstacleType) {
    return obstacleType == 0x03 || obstacleType == 0x04;
  }

  void _registerCliffInterrupt() {
    final now = DateTime.now();
    _recentCliffInterrupts.removeWhere(
      (time) => now.difference(time).inMilliseconds > _repeatedCliffWindowMs,
    );
    _recentCliffInterrupts.add(now);
    if (_recentCliffInterrupts.length >= 2) {
      print(
        "[BT_SAFE] repeated_cliff_detected "
        "count=${_recentCliffInterrupts.length} "
        "withinMs=$_repeatedCliffWindowMs",
      );
      _markWheelMayBeOffTable(reason: 'repeated_cliff');
    }
  }

  void _markWheelMayBeOffTable({required String reason}) {
    _edgeRiskHigh = true;
    _wheelMayBeOffTable = true;
    print("[BT_SAFE] wheel_may_be_off_table=true reason=$reason");
  }

  String _formatSafetyRecoverSteps(List<int> steps) {
    return '[${steps.join(',')}]';
  }

  // 发送命令
  Future<void> sendCommand(String command, int value) async {
    if (!_isConnected || _rxCharacteristic == null) {
      throw Exception('蓝牙未连接');
    }

    int commandCode;
    switch (command) {
      case '停止':
        commandCode = 0x00;
        break;
      case '前进':
        commandCode = 0x01;
        break;
      case '后退':
        commandCode = 0x02;
        break;
      case '左转':
        commandCode = 0x03;
        break;
      case '右转':
        commandCode = 0x04;
        break;
      case '持续前进':
        commandCode = 0x05;
        break;
      case '持续后退':
        commandCode = 0x06;
        break;
      case '脑袋角度':
        commandCode = 0x10;
        break;
      case '查询传感器':
        commandCode = 0x11;
        break;
      default:
        throw Exception('未知命令: $command');
    }

    final shouldTrackExecutingCommand = commandCode == 0x01 ||
        commandCode == 0x02 ||
        commandCode == 0x03 ||
        commandCode == 0x04;
    if (shouldTrackExecutingCommand) {
      _currentCommand = commandCode;
      _isExecutingCommand = true;
    }

    // 停止/持续前进/持续后退/查询传感器指令，数据包具有相同格式
    if (commandCode == 0x00 ||
        commandCode == 0x05 ||
        commandCode == 0x06 ||
        commandCode == 0x11) {
      // 构建数据包: 0x66 A B C 0xFE
      final data = Uint8List.fromList([0x66, commandCode, 0, 0, 0xFE]);
      await _rxCharacteristic!.write(data);
      print('发送指令: $command | 发送数据包: $data');
      if (commandCode == 0x00) {
        _clearExecutingCommandTracking();
      }
    }
    // 前进或后退指令
    else if (commandCode == 0x01 || commandCode == 0x02) {
      await _writeForwardBackwardMm(commandCode, value);
      print('发送指令: $command $value');
    }
    // 左转或右转指令：按真实角度下发，单包最大 180 度，超过时拆包发送
    else if (commandCode == 0x03 || commandCode == 0x04) {
      final angleDeg = value.clamp(0, 3600).toInt();
      final encodedTotal = angleDeg * _rotationValueScale;
      if (encodedTotal <= _rotationPacketMaxValue) {
        final data =
            Uint8List.fromList([0x66, commandCode, encodedTotal, 0, 0xFE]);
        await _rxCharacteristic!.write(data);
        print(
            "[BT_TURN] command=$command angleDeg=$angleDeg encoded=$encodedTotal");

        // 等待旋转完成，根据角度大小调整等待时间
        int waitTime = (encodedTotal * 12).clamp(700, 2600);
        await Future.delayed(Duration(milliseconds: waitTime));
        print('旋转完成，等待时间: ${waitTime}ms');
        _clearExecutingCommandTracking();
      } else {
        const int maxAnglePerPacket =
            _rotationPacketMaxValue ~/ _rotationValueScale;
        int times = angleDeg ~/ maxAnglePerPacket;
        int remainder = angleDeg % maxAnglePerPacket;

        print('需要旋转 $angleDeg 度，分 ${times + (remainder > 0 ? 1 : 0)} 次执行');

        for (int i = 0; i < times; i++) {
          final data = Uint8List.fromList(
              [0x66, commandCode, _rotationPacketMaxValue, 0, 0xFE]);
          await _rxCharacteristic!.write(data);
          print(
            "[BT_TURN] command=$command "
            "angleDeg=$maxAnglePerPacket encoded=$_rotationPacketMaxValue",
          );

          await Future.delayed(const Duration(milliseconds: 2200));
          print('完成第${i + 1}次${maxAnglePerPacket}度旋转');
          if (!_isExecutingCommand || _currentCommand != commandCode) {
            break;
          }
        }

        if (remainder > 0 &&
            _isExecutingCommand &&
            _currentCommand == commandCode) {
          final encodedRemainder = remainder * _rotationValueScale;
          final data = Uint8List.fromList(
              [0x66, commandCode, encodedRemainder, 0, 0xFE]);
          await _rxCharacteristic!.write(data);
          print(
            "[BT_TURN] command=$command "
            "angleDeg=$remainder encoded=$encodedRemainder",
          );

          int waitTime = (encodedRemainder * 12).clamp(700, 2200);
          await Future.delayed(Duration(milliseconds: waitTime));
          print('完成最后 $remainder 度旋转，等待时间: ${waitTime}ms');
        }
        _clearExecutingCommandTracking();
      }
    }
    // 头部移动指令，绝对角度范围为 8 到 20 度（协议定义）
    else if (commandCode == 0x10) {
      if (value >= 8 && value <= 20) {
        final data = Uint8List.fromList([0x66, commandCode, value, 0, 0xFE]);
        await _rxCharacteristic!.write(data);
        print('发送指令: $commandCode $command | 发送数据包: $data');
      } else {
        throw Exception('头部旋转角度不在规定范围内');
      }
    }
  }

  Future<void> _autoRecoverFromObstacle(int obstacleType) async {
    if (!_isConnected || _rxCharacteristic == null) return;
    if (_isAutoRecoveringFromObstacle) return;
    _isAutoRecoveringFromObstacle = true;
    _lastSafetyRecoverObstacleType = obstacleType;
    _lastSafetyRecoverAt = DateTime.now();
    _lastSafetyRecoverFailed = false;
    try {
      // 先下发停止，确保恢复动作从静止开始。
      await _writeStopPacket();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final obstacleTag = _obstacleTypeTag(obstacleType);
      if (_edgeRiskHigh && _isCliffObstacleType(obstacleType)) {
        _lastSafetyRecoverFailed = true;
        return;
      }

      if (obstacleType == 0x01 || obstacleType == 0x03) {
        if (!kEnableFrontSafetyRecover) {
          print(
              "[BT_SAFE] front_safety_recover_disabled obstacle=$obstacleTag");
          return;
        }

        final recovered = await _runSegmentedSafetyRecover(
          label: 'front_safety_recover',
          command: '后退',
          totalMm: _frontSafetyBackoffTotalMm,
          steps: _frontSafetyBackoffStepsMm,
          obstacleType: obstacleType,
          reason: obstacleTag,
        );
        if (recovered) {
          _edgeRiskHigh = false;
          _wheelMayBeOffTable = false;
          _lastSafetyRecoverFailed = false;
          _lastSafetyRecoverAt = DateTime.now();
        }
        return;
      }

      if (obstacleType == 0x04) {
        if (!kEnableRearSafetyRecover) {
          print(
            "[BT_SAFE] rear_recover_disabled "
            "obstacle=$obstacleTag no_forward_recovery",
          );
          return;
        }

        final recovered = await _runSegmentedSafetyRecover(
          label: 'rear_safety_recover',
          command: '前进',
          totalMm: _rearSafetyBackoffTotalMm,
          steps: _rearSafetyBackoffStepsMm,
          obstacleType: obstacleType,
          reason: obstacleTag,
        );
        if (recovered) {
          _edgeRiskHigh = false;
          _wheelMayBeOffTable = false;
          _lastSafetyRecoverFailed = false;
          _lastSafetyRecoverAt = DateTime.now();
        }
        return;
      }

      if (obstacleType == 0x02) {
        print(
          "[BT_SAFE] rear_recover_disabled "
          "obstacle=$obstacleTag no_forward_recovery",
        );
        return;
      }

      print(
        "[BT_SAFE] safety_recover_ignored obstacle=$obstacleTag",
      );
    } catch (e) {
      _lastSafetyRecoverFailed = true;
      print('⚠️ 自动脱困失败: $e');
    } finally {
      _isAutoRecoveringFromObstacle = false;
    }
  }

  Future<bool> _runSegmentedSafetyRecover({
    required String label,
    required String command,
    required int totalMm,
    required List<int> steps,
    required int obstacleType,
    required String reason,
  }) async {
    print(
      "[BT_SAFE] $label start "
      "totalMm=$totalMm "
      "steps=${_formatSafetyRecoverSteps(steps)} "
      "reason=$reason",
    );

    for (var i = 0; i < steps.length; i++) {
      final stepMm = steps[i];
      print(
        "[BT_SAFE] $label step=${i + 1}/${steps.length} "
        "distanceMm=$stepMm",
      );
      final feedback = await sendLinearMotionAndAwaitFeedback(
        command,
        stepMm,
        timeout: _safetyRecoverStepTimeout,
      );
      if (feedback.kind != LinearMotionEndKind.completed) {
        _lastSafetyRecoverFailed = true;
        _lastSafetyRecoverObstacleType = obstacleType;
        _lastSafetyRecoverAt = DateTime.now();
        final interruptedObstacle =
            feedback.kind == LinearMotionEndKind.interrupted
                ? '0x${feedback.obstacleType.toRadixString(16).toUpperCase()}'
                : 'timeout';
        print(
          "[BT_SAFE] safety_recover interrupted "
          "obstacleType=$interruptedObstacle "
          "step=${i + 1}/${steps.length}",
        );
        _markWheelMayBeOffTable(reason: 'recover_interrupted');
        print(
          "[BT_SAFE] recovery_failed=true "
          "edgeRiskHigh=$_edgeRiskHigh "
          "wheelMayBeOffTable=$_wheelMayBeOffTable",
        );
        await _writeStopPacket();
        await Future<void>.delayed(kFrontSafetyRecoverSettleDelay);
        return false;
      }

      await _writeStopPacket();
      await Future<void>.delayed(kFrontSafetyRecoverSettleDelay);
    }

    print("[BT_SAFE] $label done totalMm=$totalMm");
    return true;
  }

  Future<void> _writeStopPacket() async {
    final stop = Uint8List.fromList([0x66, 0x00, 0, 0, 0xFE]);
    await _rxCharacteristic!.write(stop);
    _clearExecutingCommandTracking();
  }

  /// 写入前进(0x01)/后退(0x02)毫米距离包（与 [sendCommand] 内逻辑一致）
  Future<void> _writeForwardBackwardMm(int commandCode, int value) async {
    if (value <= 255) {
      final data = Uint8List.fromList([0x66, commandCode, value, 0, 0xFE]);
      await _rxCharacteristic!.write(data);
      print(
          '发送直线运动包: cmd=0x${commandCode.toRadixString(16)} mm=$value | $data');
    } else {
      final times = value ~/ 256;
      final remainder = value % 256;
      final data =
          Uint8List.fromList([0x66, commandCode, remainder, times, 0xFE]);
      await _rxCharacteristic!.write(data);
      print(
          '发送直线运动包: cmd=0x${commandCode.toRadixString(16)} mm=$value | $data');
    }
  }

  /// 发送前进/后退并等待 MCU 回报「完成」或「传感器中断」；用于播报真实结果（悬崖/碰撞等）。
  ///
  /// [command] 仅支持 `前进`、`后退`；超时则返回 [LinearMotionEndKind.timedOut] 并复位执行状态。
  Future<LinearMotionFeedback> sendLinearMotionAndAwaitFeedback(
    String command,
    int valueMm, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!_isConnected || _rxCharacteristic == null) {
      throw Exception('蓝牙未连接');
    }
    if (command != '前进' && command != '后退') {
      throw Exception('仅前进/后退可走直线运动反馈: $command');
    }
    final commandCode = command == '前进' ? 0x01 : 0x02;

    final completer = Completer<LinearMotionFeedback>();
    late final StreamSubscription<DeviceResponseEvent> sub;
    Timer? watchdog;

    void finish(LinearMotionFeedback r) {
      watchdog?.cancel();
      watchdog = null;
      if (!completer.isCompleted) {
        completer.complete(r);
      }
      sub.cancel();
    }

    sub = responseStream.listen(
      (e) {
        if (e is MotionCompletedEvent && e.command == commandCode) {
          finish(const LinearMotionFeedback(LinearMotionEndKind.completed));
        } else if (e is MotionInterruptedEvent && e.command == commandCode) {
          finish(
            LinearMotionFeedback(
              LinearMotionEndKind.interrupted,
              obstacleType: e.obstacleType,
            ),
          );
        }
      },
      onError: (Object e, StackTrace st) {
        watchdog?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
        sub.cancel();
      },
    );

    watchdog = Timer(timeout, () {
      if (!completer.isCompleted) {
        print('⚠️ 直线运动等待 MCU 反馈超时 (${timeout.inSeconds}s)');
        _clearExecutingCommandTracking();
        finish(const LinearMotionFeedback(LinearMotionEndKind.timedOut));
      }
    });

    _currentCommand = commandCode;
    _isExecutingCommand = true;
    try {
      await _writeForwardBackwardMm(commandCode, valueMm);
      return await completer.future;
    } catch (e) {
      watchdog?.cancel();
      _clearExecutingCommandTracking();
      rethrow;
    } finally {
      watchdog?.cancel();
      await sub.cancel();
    }
  }

  // 主动断开
  Future<void> disconnect() async {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _retryConnectTimer?.cancel();
    _retryConnectTimer = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _txValueSubscription?.cancel();
    _txValueSubscription = null;

    if (_device != null) {
      await _device!.disconnect();
      _isConnected = false;
      notifyListeners();
      _device = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
    }
    _isConnected = false;
    _device = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _clearExecutingCommandTracking();
    notifyListeners();
  }

  /// 自动重连固定设备
  Future<void> reconnectLastDevice() async {
    // 固定设备名（替换成你的 Looi 机器人名字）
    const deviceName = "XHRobot";

    try {
      print("♻️ 尝试自动重连设备: $deviceName");
      await connect(deviceName);
    } catch (e) {
      print("⚠️ 自动重连失败: $e");
    }
  }

  Future<void> startAutoReconnect() async {
    if (_autoReconnectTimer != null) {
      print("[BT_RECONNECT] auto_reconnect_already_running");
      return;
    }
    _autoReconnectTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      if (!_isConnected) {
        try {
          await reconnectLastDevice();
        } catch (e) {
          print("自动重连失败: $e");
        }
      }
    });
  }

  // 自动重连
  Future<void> _retryConnect(String deviceName) async {
    if (_retryConnectTimer != null) {
      print("[BT_RECONNECT] retry_already_scheduled");
      return;
    }
    _retryConnectTimer = Timer(const Duration(seconds: 2), () async {
      _retryConnectTimer = null;
      try {
        print("🔄 自动重连中...");
        await connect(deviceName);
      } catch (e) {
        print("⚠️ 重连失败: $e，稍后重试...");
        _retryConnectTimer = Timer(const Duration(seconds: 5), () {
          _retryConnectTimer = null;
          _retryConnect(deviceName);
        });
      }
    });
  }
}
