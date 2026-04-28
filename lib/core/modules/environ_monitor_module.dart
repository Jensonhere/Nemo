import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart'
    show
        DeviceResponseEvent,
        MotionCompletedEvent,
        MotionInterruptedEvent,
        MyBluetoothService,
        SensorStatusEvent;
import 'package:voicegpt/core/services/voice_tts_service.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:flutter/foundation.dart';

class EnvironMonitorModule {
  MyBluetoothService? _bluetoothService; // 改为可空，等待外部注入

  // === 依赖服务 ===
  VoiceTtsService? _ttsService;
  UIAnimationModule? _uiModule;
  Function()? _onWakeWordRestart;
  Function()? _onGestureDetectionStart;

  // === 环境监测变量 ===
  Timer? _environmentCheckTimer;
  bool _isEnvironmentMonitoring = false;
  bool _lastDetectDirectly = false;
  int _consecutiveInitialDetections = 0; // 连续在初始位置检测到用户的次数

  // === 摄像头服务 ===
  CameraService? _cameraService;
  bool _humanDetected = false;
  String _monitorStatus = "环境监测已关闭";
  bool _isCameraOn = false;

  // === 状态变量 ===
  bool _isAnswering = false;
  bool _isTtsPlaying = false;
  String _humanEmotion = '';

  // === 表情资源 ===
  final List<String> _happyExpressions = [
    'assets/emotion/face2/可爱/02/可爱 02.json',
    'assets/emotion/face2/眨眼.json',
  ];
  final List<String> _sadExpressions = [
    'assets/emotion/face2/失落/02/失落 02.json',
    'assets/emotion/face2/疑惑/01/疑惑 01.json',
  ];
  final List<String> _surprisedExpressions = [
    'assets/emotion/face2/惊讶/02/惊讶 02.json',
  ];
  final List<String> _angryExpressions = [
    'assets/emotion/face2/愤怒/02/愤怒 02.json',
  ];

  // === 依赖注入方法 ===
  void setBluetoothService(MyBluetoothService bluetoothService) {
    _bluetoothService = bluetoothService;
    print("🔗 环境监测模块：蓝牙服务已设置");
  }

  void setTTSService(VoiceTtsService ttsService) {
    _ttsService = ttsService;
  }

  void setUIModule(UIAnimationModule uiModule) {
    _uiModule = uiModule;
  }

  void setStateCallbacks({
    required bool Function() isAnswering,
    required bool Function() isTtsPlaying,
    Function()? onWakeWordRestart,
    Function()? onGestureDetectionStart,
  }) {
    _onWakeWordRestart = onWakeWordRestart;
    _onGestureDetectionStart = onGestureDetectionStart;
    // 定期更新状态
    Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (!_isEnvironmentMonitoring) {
        timer.cancel();
        return;
      }
      _isAnswering = isAnswering();
      _isTtsPlaying = isTtsPlaying();
    });
  }

  // === 公共接口方法 ===
  void startEnvironmentMonitoring() => _startEnvironmentMonitoring();

  void stopEnvironmentMonitoring() {
    _cleanupEnvironmentMonitoring();
  }

  bool get isMonitoring => _isEnvironmentMonitoring;
  String get monitorStatus => _monitorStatus;

  /// 检查蓝牙连接状态
  bool _checkBluetoothConnection() {
    if (_bluetoothService == null) {
      print("❌ 蓝牙服务未设置！环境监测模块需要蓝牙服务实例");
      return false;
    }
    if (!_bluetoothService!.isConnected) {
      print("❌ 蓝牙未连接！环境监测需要蓝牙控制机器人移动");
      return false;
    }
    return true;
  }

  // === 环境监测主方法 ===
  void _startEnvironmentMonitoring() async {
    // if (speech_isInConversationMode) {
    //   print("🗨 连续对话模式已开启，无法进行环境监测");
    //   return;
    // }

    // 🔴 检查蓝牙连接状态
    if (!_checkBluetoothConnection()) {
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      print("⛔ 环境监测需要蓝牙连接");
      print("");
      print("📋 环境监测功能需要蓝牙来：");
      print("   1. 控制机器人移动（旋转、前进、后退）");
      print("   2. 获取传感器状态（障碍物、悬崖检测）");
      print("   3. 控制头部角度调整");
      print("");
      print("💡 解决方案：");
      print("   1. 确保机器人已开机");
      print("   2. 在设置中连接机器人蓝牙");
      print("   3. 连接成功后，环境监测将自动启动");
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      _monitorStatus = "蓝牙未连接，无法启动环境监测";
      return;
    }

    if (!_isEnvironmentMonitoring) {
      print("🌍 开启环境监测功能");
      print("✅ 蓝牙已连接，可以控制机器人");
      _isEnvironmentMonitoring = true;
      try {
        // 延迟初始化摄像头服务，只在需要时初始化
        if (_cameraService == null) {
          _cameraService = CameraService();
          print("📷 延迟初始化CameraService");
        }

        // 确保摄像头服务正确初始化
        await _cameraService!.initialize();
        _isCameraOn = true;
        print("📷 CameraService初始化完成");

        // 起始位置检测到人且上次也是起始位置检测到人，说明人没动
        bool currentDetectDirectly = await _detectHumanAtPosition();

        // 检查连续在初始位置检测到用户的情况
        if (currentDetectDirectly && _lastDetectDirectly) {
          _consecutiveInitialDetections += 1;
          print("✅ 连续在初始位置检测到用户，计数: $_consecutiveInitialDetections");

          // 连续十次在初始位置检测到用户，提醒休息
          if (_consecutiveInitialDetections >= 10) {
            /// TODO:语音与表情显示修改
            // await speakWithInterruptProtection("主人，该休息一下了！");
            // _loadExpression('assets/face/晕');
            _consecutiveInitialDetections = 0;
            print("🔄 已提醒用户休息，重置连续监测计数器");
          }
        } else {
          // 重置连续检测计数器
          _consecutiveInitialDetections = 0;
          print("🔄 重置连续检测计数器");
        }

        // 更新上一次监测结果
        _lastDetectDirectly = currentDetectDirectly;
        if (!currentDetectDirectly) {
          // 启动基座旋转扫描
          await _performEnvironmentScan();
        }
      } catch (e) {
        _monitorStatus = "环境监测启动失败: $e";
        print('环境监测启动失败: $e');
      } finally {
        // 关闭摄像头服务
        _isEnvironmentMonitoring = false;
        _isCameraOn = false;
        _humanDetected = false;
        if (_cameraService != null) {
          try {
            _cameraService!.stopRealTimeDetection();
            print("⏹️ 停止实时图像流监测");
            await _cameraService!.dispose();
            _cameraService = null;
            print("📷 摄像头资源已释放");
          } catch (disposeError) {
            print("⚠️ 清理摄像头资源失败: $disposeError");
          }
        }
      }
    } else {
      print("🌍 环境检测功能已开启！！！");
    }
  }

  // === 新增: 执行环境扫描 ===
  Future<void> _performEnvironmentScan() async {
    const int maxMoves = 100; // 最大移动次数
    int moveCount = 0;

    // 设置人类检测回调
    _cameraService!.setOnHumanDetectedCallback((hasCenteredHuman) {
      if (hasCenteredHuman && _isCameraOn && _isEnvironmentMonitoring) {
        print("🎯 移动过程中检测到用户");
        _humanDetected = true;
        _bluetoothService!.sendCommand('停止', 0);
      }
    });

    // 开始实时检测
    _cameraService!.startRealTimeDetection();

    // 随机确定初始旋转方向
    bool rotateRight = Random().nextBool();

    while (moveCount < maxMoves && _isCameraOn && _isEnvironmentMonitoring) {
      moveCount++;
      _monitorStatus = "扫描中 - 第$moveCount次移动";
      print(_monitorStatus);

      /// TODO:语音与表情显示修改
      // // 语音播报
      // await speakWithInterruptProtection("主人，你在这里吗？");
      // _loadExpression('assets/face/观察');

      // 移动到下一个随机位置
      await _moveToRandomPosition(rotateRight);

      // 检查是否在移动过程中检测到人类
      if (_humanDetected) {
        print("✅ 移动过程中已检测到用户，处理中...");
        bool shouldContinue = await _handleHumanDetected();

        if (shouldContinue) {
          print("✅ 用户已交互，停止扫描");
          return; // 停止环境监测
        } else {
          print("⏩ 用户未交互，继续扫描");
          _humanDetected = false; // 重置标志继续扫描
          // 继续循环
        }
      } else {
        await _handleNoHumanDetected();
        print("⏩ 未检测到用户，继续扫描");
      }

      // 下一次旋转方向仍随机
      rotateRight = Random().nextBool();
    }

    if (_isCameraOn && _isEnvironmentMonitoring) {
      _monitorStatus = "扫描完成，未检测到人类";
      print("环境扫描完成，未发现人员活动");

      // 确保完全清理环境监测状态
      await _cleanupEnvironmentMonitoring();

      // 播放退出提示
      await _speakExitMessage("我先睡了哦");

      // 重新启动唤醒词检测
      await _restartWakeWordDetection();

      // === 环境监测，设置时间为300s ===
      _environmentCheckTimer?.cancel();
      _environmentCheckTimer = Timer(const Duration(seconds: 300), () {
        if (!_isEnvironmentMonitoring && !_isAnswering && !_isTtsPlaying) {
          _startEnvironmentMonitoring();
        }
      });
    }
  }

  Future<void> _moveToRandomPosition(bool rotateRight) async {
    try {
      // 检查基座是否处于平台边缘或障碍附近
      final sensorStatus = await _getSensorStatus();
      // 生成随机旋转角度
      int rotationAngle;

      // 检查基座是否处于平台边缘
      if (sensorStatus.frontCliff || sensorStatus.frontObstacle) {
        // 先退一段距离
        await _executeWithInterruptionCheck(
            () => _bluetoothService!.sendCommand('后退', 350),
            description: "后退350mm避免前部碰撞或坠落");
        // 生成大于90度的旋转角度（91-180度）
        rotationAngle = 90 + Random().nextInt(91);
        print("🚨 检测到基座处于平台边缘或遇到障碍，生成大角度旋转: ${rotationAngle}度");
      } else if (sensorStatus.rearCliff || sensorStatus.rearObstacle) {
        // 先退10cm
        await _executeWithInterruptionCheck(
            () => _bluetoothService!.sendCommand('前进', 350),
            description: "前进350mm避免后部碰撞或坠落");
        // 生成小于90度的旋转角度（0-89度）
        rotationAngle = Random().nextInt(90);
        print("🚨 检测到基座处于平台边缘或遇到障碍，生成小角度旋转: ${rotationAngle}度");
      } else {
        // 正常情况下生成30-150度的随机角度
        rotationAngle = 30 + Random().nextInt(121);
      }

      // 生成随机前进距离（100-300mm）
      int moveDistance = 100 + Random().nextInt(201);

      await _loadExpression('assets/emotion/face2/眨眼.json');

      // 执行旋转移动（带中断检测）
      await _executeWithInterruptionCheck(
          () => rotateRight
              ? _bluetoothService!.sendCommand('右转', rotationAngle)
              : _bluetoothService!.sendCommand('左转', rotationAngle),
          description: rotateRight ? "右转$rotationAngle度" : "左转$rotationAngle度");
      if (_humanDetected) return;
      await Future.delayed(Duration(milliseconds: 500)); // 等待旋转完成

      // 调整头部角度为水平
      await _bluetoothService!.sendCommand('脑袋角度', 14);
      await Future.delayed(Duration(milliseconds: 300)); // 等待头部调整

      // 前进随机距离（带中断检测）
      await _loadExpression('assets/emotion/face2/寻找/01/寻找 01.json');
      await _executeWithInterruptionCheck(
          () => _bluetoothService!.sendCommand('前进', moveDistance),
          description: "前进${moveDistance}mm");
      if (_humanDetected) return;
      await Future.delayed(Duration(seconds: 1)); // 等待基座稳定

      print("📍 已移动到新的检测位置");
    } catch (e) {
      print("❌ 移动到检测位置失败: $e");
    }
  }

  // 实时获取传感器状态
  Future<SensorStatusEvent> _getSensorStatus() async {
    late StreamSubscription<DeviceResponseEvent> subscription;
    final completer = Completer<SensorStatusEvent>();

    try {
      // 设置订阅，在发送命令前开始监听
      subscription = _bluetoothService!.responseStream.listen((event) {
        if (event is SensorStatusEvent) {
          // 只处理一次响应
          if (!completer.isCompleted) {
            completer.complete(event);
          }
        }
      });

      // 发送查询命令
      await _bluetoothService!.sendCommand('查询传感器', 0);

      // 等待响应或超时
      final sensorStatus = await completer.future
          .timeout(const Duration(seconds: 2), onTimeout: () {
        debugPrint("⚠️ 传感器状态查询超时");
        return SensorStatusEvent(
            frontObstacle: false,
            rearObstacle: false,
            frontCliff: false,
            rearCliff: false);
      });

      subscription.cancel();
      return sensorStatus;
    } catch (e) {
      debugPrint("❌ 获取传感器状态失败: $e");
      return SensorStatusEvent(
          frontObstacle: false,
          rearObstacle: false,
          frontCliff: false,
          rearCliff: false);
    }
  }

  Future<void> _executeWithInterruptionCheck(Future Function() action,
      {required String description}) async {
    final completer = Completer<void>();
    bool interrupted = false;
    Timer? sensorCheckTimer;

    // 监听事件（在动作开始前）
    final subscription = _bluetoothService!.responseStream.listen((event) {
      if (event is MotionInterruptedEvent) {
        interrupted = true;
        _bluetoothService!.sendCommand('停止', 0);
        completer.completeError(
            Exception("${description}被中断: ${event.obstacleDescription}"));
      } else if (event is MotionCompletedEvent) {
        // 检测到动作完成
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });

    try {
      sensorCheckTimer =
          Timer.periodic(Duration(milliseconds: 1000), (timer) async {
        try {
          final sensorStatus = await _getSensorStatus();

          // 检查是否需要立即停止
          bool shouldStop = false;
          String stopReason = "";

          if (sensorStatus.frontCliff) {
            shouldStop = true;
            stopReason = "前方悬崖";
          } else if (sensorStatus.frontObstacle) {
            shouldStop = true;
            stopReason = "前方障碍";
          } else if (sensorStatus.rearCliff) {
            shouldStop = true;
            stopReason = "后方悬崖";
          } else if (sensorStatus.rearObstacle) {
            shouldStop = true;
            stopReason = "后方障碍";
          }

          if (shouldStop && !interrupted) {
            interrupted = true;
            // 发送停止命令
            await _bluetoothService!.sendCommand('停止', 0);
            completer
                .completeError(Exception("${description}被中断: 检测到$stopReason"));
            timer.cancel();
          }
        } catch (e) {
          debugPrint("❌ 传感器定期检查失败: $e");
        }
      });
      // 执行动作
      await action();

      // 等待动作完成或中断（带超时）
      await completer.future.timeout(Duration(seconds: 10));

      // 如果没有超时且未中断
      if (!interrupted) {
        print("✅ $description 完成");
      }
    } on TimeoutException {
      if (!interrupted) {
        print("⚠️ $description 超时未完成");
      }
    } catch (e) {
      rethrow; // 重新抛出中断错误
    } finally {
      subscription.cancel();
      sensorCheckTimer?.cancel();
    }
  }

  // === 新增方法：在初始位置调用摄像头检测人类活动 ===
  Future<bool> _detectHumanAtPosition() async {
    if (!_isEnvironmentMonitoring || !_isCameraOn) {
      print("🛑 人类检测已中断");
      return false;
    }

    // 检查蓝牙连接
    if (!_checkBluetoothConnection()) {
      print("⚠️ 蓝牙未连接，无法调整头部角度");
      return false;
    }

    try {
      await _bluetoothService!.sendCommand('脑袋角度', 20);
      await Future.delayed(Duration(milliseconds: 300));
      _humanDetected = await _cameraService!.detectHuman();

      // 连续两次直接检测到人，则直接返回true
      if (_humanDetected && _lastDetectDirectly) {
        return true;
      }

      // 语音播报
      await speakWithInterruptProtection("主人，你在这里吗？");
      _loadExpression('assets/emotion/face2/观察/01/观察 01.json');

      if (_humanDetected) {
        return await _handleHumanDetected();
      } else {
        await _handleNoHumanDetected();
        return false;
      }
    } catch (e) {
      print('检测失败: $e');
      return false;
    }
  }

  // === 新增：处理检测到人类的情况 ===
  Future<bool> _handleHumanDetected() async {
    _monitorStatus = "⚠️ 检测到人类活动！";
    print("检测到人类活动！！！！！！");

    // 进行人脸监测和人脸识别
    final _isOwner = await _identifyOwner(); // 调用身份识别方法
    if (_isOwner) {
      _monitorStatus = "⚠️ 检测到主人活动！";
      print("检测到主人活动！！！！！！");

      // === 停止图像流监测 ===
      _cameraService!.stopRealTimeDetection();
      print("⏹️ 已停止实时图像流监测");

      // 立即并行播报，同时执行动作
      unawaited(speakWithInterruptProtection("找到你了，主人！"));
      await _performFoundOwnerAction();

      // 进行情绪识别
      _humanEmotion = await _cameraService!.detectFaceEmotion();
      await feedbackHumanEmotion(_humanEmotion);

      // 清理环境监测状态
      await _cleanupEnvironmentMonitoring();

      // === 启动自动手势检测 ===
      _startAutoGestureDetection();
      return true;
    } else {
      _monitorStatus = "⚠️ 检测到陌生人活动！";
      print("检测到陌生人活动，继续监测");
      await speakWithInterruptProtection("有人来了，但不是主人");
      return false;
    }
  }

  // === 新增：处理未检测到人类的情况 ===
  Future<void> _handleNoHumanDetected() async {
    _monitorStatus = "未检测到人类活动";
    print("该位置未检测到人类活动");

    // 显示沮丧的表情
    await _loadExpression(_getRandomExpression(_sadExpressions));

    // 检查蓝牙连接后再尝试低头动作
    if (_checkBluetoothConnection()) {
      await _bluetoothService!.sendCommand('脑袋角度', 8); // 低头
    }

    /// TODO:描述看到的场景
  }

  // === 新增：执行找到主人的动作 ===
  Future<void> _performFoundOwnerAction() async {
    // 检查蓝牙连接
    if (!_checkBluetoothConnection()) {
      print("⚠️ 蓝牙未连接，无法执行找到主人动作");
      return;
    }

    try {
      // 抬头
      print("🎉 执行找到主人动作：抬头");
      await _bluetoothService!.sendCommand('脑袋角度', 20);
      await Future.delayed(Duration(milliseconds: 300));

      // 显示开心表情
      _loadExpression(_getRandomExpression(_happyExpressions));

      // 前进
      print("🎉 执行找到主人动作：前进到平台边缘");
      // 前进随机距离（带中断检测）
      await _executeWithInterruptionCheck(
          () => _bluetoothService!.sendCommand('持续前进', 0),
          description: "持续前进到平台边缘");
      await Future.delayed(Duration(seconds: 3));

      print("🎉 找到主人动作完成");
    } catch (e) {
      print("❌ 执行找到主人动作失败: $e");
    }
  }

  // // 对不同面部表情的不同反馈
  // Future<void> feedbackHumanEmotion(String emotion) async {
  //   switch (emotion) {
  //     case '开心':
  //       print('😊 监测到用户情绪：开心');
  //       _loadExpression(_getRandomExpression(_happyExpressions));
  //       await speakWithInterruptProtection('看到你笑得这么开心，我的心情也变好啦！有什么好事发生吗？');
  //       break;
  //     case '难过':
  //       print('😔 监测到用户情绪：难过');
  //       _loadExpression(_getRandomExpression(_sadExpressions));
  //       await speakWithInterruptProtection('感觉你似乎有些低落呢，没关系，有我在这里陪着你。');
  //       break;
  //     case '惊讶':
  //       print('😲 监测到用户情绪：惊讶');
  //       _loadExpression(_getRandomExpression(_surprisedExpressions));
  //       await speakWithInterruptProtection('看起来发生了什么让你意想不到的事情，可以跟我分享一下吗？');
  //       break;
  //     case '愤怒':
  //       print('😡 监测到用户情绪：愤怒');
  //       _loadExpression(_getRandomExpression(_angryExpressions));
  //       await speakWithInterruptProtection('感觉你有些生气呢，需要我帮你做点什么来缓解一下吗？');
  //       break;
  //     default:
  //       print('🤔 监测到用户情绪：未知');
  //       _loadExpression('assets/face/眨眼');
  //       await speakWithInterruptProtection('你好呀！有什么需要我为你做的吗？');
  //       break;
  //   }
  // }

  // === 新增：清理环境监测状态的方法 ===
  Future<void> _cleanupEnvironmentMonitoring() async {
    print("🧹 清理环境监测状态");
    _isEnvironmentMonitoring = false;
    _isCameraOn = false;
    _lastDetectDirectly = false;
    _humanDetected = false;
    _consecutiveInitialDetections = 0;

    // 取消所有环境监测相关计时器
    _environmentCheckTimer?.cancel();

    // 释放摄像头资源
    try {
      if (_cameraService != null) {
        _cameraService!.stopRealTimeDetection();
        print("⏹️ 停止实时图像流监测");
        await _cameraService!.dispose();
        _cameraService = null; // 重置为null，确保下次重新初始化
        print("📷 摄像头资源已释放");
      }
    } catch (e) {
      print("⚠️ 释放摄像头资源时出错: $e");
      _cameraService = null; // 即使出错也要重置为null
    }

    print("✅ 环境监测状态清理完成");
  }

  // === 辅助方法实现 ===

  /// 加载表情动画
  Future<void> _loadExpression(String expressionPath) async {
    try {
      if (_uiModule != null) {
        _uiModule!.setAnimation(expressionPath);
        print("🎭 切换表情: $expressionPath");
      } else {
        print("⚠️ UIModule未设置，无法切换表情");
      }
    } catch (e) {
      print("❌ 切换表情失败: $e");
    }
  }

  /// 带中断保护的语音播报
  Future<void> speakWithInterruptProtection(String text) async {
    try {
      if (_ttsService != null && !_isTtsPlaying) {
        print("🎤 环境监测语音播报: $text");
        await _ttsService!.speak(text);
      } else if (_isTtsPlaying) {
        print("⚠️ TTS正在播放，跳过语音播报: $text");
      } else {
        print("⚠️ TTS服务未设置，无法语音播报");
      }
    } catch (e) {
      print("❌ 语音播报失败: $e");
    }
  }

  /// 随机获取表情
  String _getRandomExpression(List<String> expressions) {
    if (expressions.isEmpty) {
      return 'assets/emotion/face2/眨眼.json';
    }
    return expressions[Random().nextInt(expressions.length)];
  }

  /// 情绪反馈处理
  Future<void> feedbackHumanEmotion(String emotion) async {
    try {
      switch (emotion) {
        case '开心':
          print('😊 监测到用户情绪：开心');
          await _loadExpression(_getRandomExpression(_happyExpressions));
          await speakWithInterruptProtection('看到你笑得这么开心，我的心情也变好啦！有什么好事发生吗？');
          break;
        case '难过':
          print('😔 监测到用户情绪：难过');
          await _loadExpression(_getRandomExpression(_sadExpressions));
          await speakWithInterruptProtection('感觉你似乎有些低落呢，没关系，有我在这里陪着你。');
          break;
        case '惊讶':
          print('😲 监测到用户情绪：惊讶');
          await _loadExpression(_getRandomExpression(_surprisedExpressions));
          await speakWithInterruptProtection('看起来发生了什么让你意想不到的事情，可以跟我分享一下吗？');
          break;
        case '愤怒':
          print('😡 监测到用户情绪：愤怒');
          await _loadExpression(_getRandomExpression(_angryExpressions));
          await speakWithInterruptProtection('感觉你有些生气呢，需要我帮你做点什么来缓解一下吗？');
          break;
        default:
          print('🤔 监测到用户情绪：未知');
          await _loadExpression('assets/emotion/face2/眨眼.json');
          await speakWithInterruptProtection('你好呀！有什么需要我为你做的吗？');
          break;
      }
    } catch (e) {
      print("❌ 情绪反馈处理失败: $e");
    }
  }

  /// 退出消息播报
  Future<void> _speakExitMessage(String message) async {
    await speakWithInterruptProtection(message);
  }

  /// 重启唤醒词检测
  Future<void> _restartWakeWordDetection() async {
    try {
      if (_onWakeWordRestart != null) {
        _onWakeWordRestart!();
        print("🎤 重新启动唤醒词检测");
      } else {
        print("⚠️ 唤醒词重启回调未设置");
      }
    } catch (e) {
      print("❌ 重启唤醒词检测失败: $e");
    }
  }

  /// 启动自动手势检测
  void _startAutoGestureDetection() {
    try {
      if (_onGestureDetectionStart != null) {
        _onGestureDetectionStart!();
        print("👋 启动自动手势检测");
      } else {
        print("⚠️ 手势检测启动回调未设置");
      }
    } catch (e) {
      print("❌ 启动手势检测失败: $e");
    }
  }

  /// unawaited 辅助方法
  void unawaited(Future future) {
    // 这个方法允许不等待Future完成，用于并行执行
    future.catchError((error) {
      print("⚠️ unawaited future error: $error");
    });
  }

  /// 身份识别方法
  Future<bool> _identifyOwner() async {
    try {
      // TODO: 这里可以集成实际的人脸识别功能
      // 目前暂时返回true，表示都认为是主人
      // 未来可以连接到人脸识别服务或本地模型
      await Future.delayed(Duration(milliseconds: 100)); // 模拟识别延迟
      return true; // 暂时假设都是主人
    } catch (e) {
      print("❌ 身份识别失败: $e");
      return false; // 识别失败时认为是陌生人
    }
  }
}
