import 'dart:async';
import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';

/// 用户监测模块
/// 在连续对话模式开始时执行720度旋转寻找用户，并前进到用户位置
class UserDetectionModule {
  static final UserDetectionModule _instance = UserDetectionModule._internal();
  factory UserDetectionModule() => _instance;
  UserDetectionModule._internal();

  final OpenAI _openAI = OpenAI();
  CameraService? _cameraService;
  MyBluetoothService? _bluetoothService;

  bool _isDetecting = false;
  bool _shouldStop = false;

  /// 当前是否正在检测
  bool get isDetecting => _isDetecting;

  /// 初始化蓝牙服务
  void initializeBluetoothService(MyBluetoothService bluetoothService) {
    _bluetoothService = bluetoothService;
    print("🔗 用户监测模块蓝牙服务已设置");
  }

  /// 开始用户监测
  /// 在连续对话模式开始时调用，720度旋转寻找用户
  Future<UserDetectionResult> startUserDetection() async {
    if (_isDetecting) {
      print("⏳ 用户监测已在进行中");
      return UserDetectionResult(
        success: false,
        userFound: false,
        message: "检测已在进行中",
      );
    }

    // 用户可能在 enter 排队的 microtask 执行前就已开口；stopUserDetection 会先置位本标志。
    if (_shouldStop) {
      print("🛑 用户监测启动前已收到停止请求（例如用户已开始说话），跳过本次扫描");
      _shouldStop = false;
      return UserDetectionResult(
        success: false,
        userFound: false,
        message: "监测已取消",
      );
    }

    _isDetecting = true;
    _shouldStop = false;
    print("🔍 开始用户监测，720度旋转扫描");

    try {
      // 初始化摄像头服务
      await _initializeCameraService();

      if (_shouldStop) {
        print("🛑 用户监测在摄像头初始化后已取消");
        return UserDetectionResult(
          success: false,
          userFound: false,
          message: "监测已取消",
        );
      }

      // 检查蓝牙连接
      if (_bluetoothService == null || !_bluetoothService!.isConnected) {
        throw Exception("机器人未连接，无法执行旋转动作");
      }

      // 首先检测初始位置
      print("📸 检测初始位置");
      bool userFoundAtStart = await _detectUserAtCurrentPosition();

      if (userFoundAtStart) {
        print("✅ 在初始位置发现用户");
        return UserDetectionResult(
          success: true,
          userFound: true,
          message: "在初始位置发现用户",
          detectionAngle: 0,
        );
      }

      if (_shouldStop) {
        print("🛑 用户监测在旋转扫描前已取消");
        return UserDetectionResult(
          success: false,
          userFound: false,
          message: "监测已取消",
        );
      }

      // 执行720度旋转扫描
      return await _performRotationScan();
    } catch (e) {
      print("❌ 用户监测失败: $e");
      return UserDetectionResult(
        success: false,
        userFound: false,
        message: "监测过程发生错误: $e",
        error: e.toString(),
      );
    } finally {
      _isDetecting = false;
      _shouldStop = false;
    }
  }

  /// 停止用户监测（含尚未进入 [startUserDetection] 的排队任务：见启动处对 [_shouldStop] 的检查）。
  void stopUserDetection() {
    _shouldStop = true;
    if (_isDetecting) {
      print("🛑 请求停止用户监测");
    }
  }

  /// 执行720度旋转扫描
  Future<UserDetectionResult> _performRotationScan() async {
    print("🔄 开始720度旋转扫描");
    if (_shouldStop) {
      print("🛑 用户监测旋转扫描未开始即已取消");
      return UserDetectionResult(
        success: false,
        userFound: false,
        message: "监测已取消",
      );
    }

    // 旋转参数：每180度拍照一次（0, 180, 360, 540度位置）
    final List<int> checkAngles = [180, 360, 540, 720]; // 检测角度

    int currentAngle = 0;

    for (int targetAngle in checkAngles) {
      if (_shouldStop) {
        print("🛑 用户监测被中断");
        break;
      }

      // 旋转到目标角度
      int rotationAmount = targetAngle - currentAngle;
      print("🔄 旋转到 ${targetAngle}度（旋转${rotationAmount}度）");

      try {
        await _bluetoothService!.sendCommand('右转', rotationAmount);

        // 等待旋转完成
        await Future.delayed(Duration(milliseconds: 2000));

        if (_shouldStop) {
          print("🛑 用户监测在旋转后已取消，不再继续扫描");
          break;
        }

        // 在当前角度检测用户
        print("📸 在 ${targetAngle}度位置检测用户");
        bool userFound = await _detectUserAtCurrentPosition();

        if (userFound) {
          print("✅ 在 ${targetAngle}度位置发现用户");

          // 向用户方向前进200mm
          await _moveToUser();

          return UserDetectionResult(
            success: true,
            userFound: true,
            message: "在 ${targetAngle}度位置发现用户，已前进到用户位置",
            detectionAngle: targetAngle,
          );
        }

        currentAngle = targetAngle;
      } catch (e) {
        print("❌ 在角度 ${targetAngle} 执行操作失败: $e");
      }
    }

    if (_shouldStop) {
      print("🛑 用户监测旋转扫描已中断");
      return UserDetectionResult(
        success: false,
        userFound: false,
        message: "监测已中断",
      );
    }

    print("❌ 720度扫描完成，未发现用户");
    return UserDetectionResult(
      success: true,
      userFound: false,
      message: "720度扫描完成，未发现用户",
    );
  }

  /// 在当前位置检测用户
  Future<bool> _detectUserAtCurrentPosition() async {
    try {
      // 拍照
      String imagePath = await _cameraService!.captureImage();

      // 使用视觉大模型检测用户
      String prompt = """
      请判断图片中是否有人类存在。
      
      要求：
      1. 仔细观察图片中是否有人类的身体、面部或身体部位
      2. 如果发现人类，请回答"发现用户"
      3. 如果没有发现人类，请回答"未发现用户"
      4. 只需要简单回答，不需要详细描述
      """;

      final response = await _openAI.generateImageText(prompt, imagePath);

      if (response['choices'] != null && response['choices'].isNotEmpty) {
        String result = response['choices'][0]['message']['content']
            .toString()
            .toLowerCase();
        bool userDetected = result.contains('发现用户') ||
            result.contains('有人') ||
            result.contains('人类');

        print("🤖 视觉检测结果: ${userDetected ? '发现用户' : '未发现用户'}");
        return userDetected;
      }

      return false;
    } catch (e) {
      print("❌ 用户监测视觉请求失败: $e");
      return false;
    }
  }

  /// 向用户位置前进
  Future<void> _moveToUser() async {
    try {
      print("🚶 向用户方向前进200mm");
      await _bluetoothService!.sendCommand('前进', 200);
      await Future.delayed(Duration(milliseconds: 1500)); // 等待移动完成
      print("✅ 已到达用户位置");
    } catch (e) {
      print("❌ 前进到用户位置失败: $e");
    }
  }

  /// 初始化摄像头服务
  Future<void> _initializeCameraService() async {
    if (_cameraService == null) {
      _cameraService = CameraService();
      await _cameraService!.initialize();
      print("📷 用户监测摄像头服务初始化完成");
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    _shouldStop = true;

    if (_cameraService != null) {
      await _cameraService!.dispose();
      _cameraService = null;
      print("📷 用户监测模块摄像头资源已释放");
    }
  }
}

/// 用户监测结果
class UserDetectionResult {
  final bool success;
  final bool userFound;
  final String message;
  final int? detectionAngle; // 发现用户的角度
  final String? error;
  final DateTime timestamp;

  UserDetectionResult({
    required this.success,
    required this.userFound,
    required this.message,
    this.detectionAngle,
    this.error,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    return 'UserDetectionResult{success: $success, userFound: $userFound, message: "$message"${detectionAngle != null ? ', angle: ${detectionAngle}°' : ''}${error != null ? ', error: "$error"' : ''}}';
  }
}
