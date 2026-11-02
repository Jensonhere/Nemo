/// 调试期全局开关（发布前可按需改回 true）。
class DebugRuntimeFlags {
  DebugRuntimeFlags._();

  /// 为 false 时：不启动空闲/退出后的环境监测（不打相机环视），专注对话调试。
  static const bool enableEnvironmentMonitoring = true;
}
