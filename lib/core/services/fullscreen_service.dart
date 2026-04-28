import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class FullscreenService {
  static final FullscreenService _instance = FullscreenService._internal();
  factory FullscreenService() => _instance;
  FullscreenService._internal();

  /// 启用全屏模式
  Future<void> enableFullscreen() async {
    try {
      // 设置包含刘海区域的全屏模式
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: [],
      );

      // 设置系统UI样式 - 确保刘海区域为黑色
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.black,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarDividerColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );

      print('✅ 包含刘海区域的全屏模式已启用');
    } catch (e) {
      print('❌ 启用全屏模式失败: $e');
    }
  }

  /// 禁用全屏模式
  Future<void> disableFullscreen() async {
    try {
      // 恢复正常的系统UI显示
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );

      print('✅ 全屏模式已禁用');
    } catch (e) {
      print('❌ 禁用全屏模式失败: $e');
    }
  }

  /// 切换全屏模式
  Future<void> toggleFullscreen() async {
    try {
      // 由于无法直接获取当前状态，我们通过尝试启用来切换
      await enableFullscreen();
    } catch (e) {
      print('❌ 切换全屏模式失败: $e');
    }
  }

  /// 获取当前全屏状态（简化版本）
  bool get isFullscreen {
    // 简化实现，返回true表示期望的全屏状态
    return true;
  }
}
