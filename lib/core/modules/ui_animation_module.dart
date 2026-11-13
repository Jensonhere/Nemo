import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:voicegpt/core/llm/planner_expression_catalog.dart';

/// 程序模式枚举
enum ProgramMode {
  idle, // 空闲状态
  environmentCheck, // 环境监测
  gestureRecognition, // 手势识别
  conversation, // 连续对话
}

/// 与 TTS 开播对齐的「说话/模块」表情（在 `_speakText` 内、真正出声前应用）。
enum TtsAlignedExpression {
  /// 不改变当前表情（例如仍在「思考」等待态）。
  none,
  /// 文本问答 / 通用说话嘴型
  textChatSpeaking,
  /// 动作指令
  actionCommandSpeaking,
  /// 图片分析（播报时直接到观察终态）
  imageObserveSpeaking,
  /// 使用 [emotionUiLabel] 走情绪脸（与 [handleEmotionAnimation] 一致）
  emotionSpeaking,
}

/// 动画类型枚举
enum AnimationType {
  // 基础状态
  idle, // 眨眼.json - 默认空闲

  // 连续对话模式
  thinkingStage1, // 思考 01.json - 唤醒后第一阶段
  thinkingStage2, // 思考 02.json - 连续对话默认界面
  listeningCute, // 可爱 02.json - 连续对话聆听中

  // 情绪相关
  happyEmotion, // 可爱 01.json - 正能量情绪（TTS 情绪脸）
  sadEmotion, // 失落 02.json - 负能量情绪
  angryEmotion, // 愤怒 02.json - 愤怒情绪
  surpriseEmotion, // 惊讶 02.json - 惊讶情绪
  firmEmotion, // 坚定 02.json - 谨慎但坚定

  // 功能模块
  commandEager, // 热切 02.json - 动作指令
  observeStage1, // 观察 01.json - 图片分析第一阶段
  observeStage2, // 观察 02.json - 图片分析第二阶段
  chatting, // 说话 02.json - 正常对话
}

/// 界面变换模块
/// 独立线程管理，贯穿整个程序（环境监测、手势识别、连续对话模式）
class UIAnimationModule extends ChangeNotifier {
  static final UIAnimationModule _instance = UIAnimationModule._internal();
  factory UIAnimationModule() => _instance;
  UIAnimationModule._internal();

  // 当前动画路径
  String _currentAnimation = 'assets/emotion/face2/眨眼.json';

  // 动画切换回调
  Function(String)? _animationCallback;

  // 计时器管理
  Timer? _animationTimer;
  Timer? _stageTimer;

  // 当前程序模式
  ProgramMode _currentMode = ProgramMode.idle;

  // 动画状态
  bool _isAnimationLocked = false;

  // 动画路径映射
  static final Map<AnimationType, String> _animationPaths = {
    AnimationType.idle: 'assets/emotion/face2/眨眼.json',
    AnimationType.thinkingStage1: 'assets/emotion/face2/思考/01/思考 01.json',
    AnimationType.thinkingStage2: 'assets/emotion/face2/思考/02/思考 02.json',
    AnimationType.listeningCute: 'assets/emotion/face2/可爱/02/可爱 02.json',
    AnimationType.happyEmotion: 'assets/emotion/face2/可爱/01/可爱 01.json',
    AnimationType.sadEmotion: 'assets/emotion/face2/失落/02/失落 02.json',
    AnimationType.angryEmotion: 'assets/emotion/face2/愤怒/02/愤怒 02.json',
    AnimationType.surpriseEmotion: 'assets/emotion/face2/惊讶/02/惊讶 02.json',
    AnimationType.firmEmotion: 'assets/emotion/face2/坚定/02/坚定 02.json',
    AnimationType.commandEager: 'assets/emotion/face2/热切/02/热切 02.json',
    AnimationType.observeStage1: 'assets/emotion/face2/观察/01/观察 01.json',
    AnimationType.observeStage2: 'assets/emotion/face2/观察/02/观察 02.json',
    AnimationType.chatting: 'assets/emotion/face2/说话/02/说话 02.json',
  };

  /// 当前动画路径
  String get currentAnimation => _currentAnimation;

  /// 当前程序模式
  ProgramMode get currentMode => _currentMode;

  /// 初始化界面变换模块
  void initialize({Function(String)? animationCallback}) {
    _animationCallback = animationCallback;
    print("🎭 界面变换模块初始化完成");
  }

  /// 设置程序模式
  void setProgramMode(ProgramMode mode) {
    if (_currentMode != mode) {
      print("🔄 程序模式切换: ${_currentMode} → $mode");
      _currentMode = mode;

      // 根据模式切换到相应的默认动画
      switch (mode) {
        case ProgramMode.idle:
          _switchToAnimation(AnimationType.idle);
          break;
        case ProgramMode.environmentCheck:
          _switchToAnimation(AnimationType.idle);
          break;
        case ProgramMode.gestureRecognition:
          _switchToAnimation(AnimationType.idle);
          break;
        case ProgramMode.conversation:
          // 连续对话模式在唤醒时会有专门的动画序列
          break;
      }
    }
  }

  /// 处理唤醒词响应（旧：思考 01→02；仍保留供非对话场景如需调用）
  void handleWakeUpResponse() {
    print("🎭 处理唤醒词响应动画");

    // 第一阶段：显示思考 01.json
    _switchToAnimation(AnimationType.thinkingStage1);

    // 500ms后切换到思考 02.json
    _stageTimer?.cancel();
    _stageTimer = Timer(Duration(milliseconds: 500), () {
      _switchToAnimation(AnimationType.thinkingStage2);
      print("🎭 唤醒动画序列完成，进入连续对话默认界面");
    });
  }

  /// 唤醒进入连续对话：不先切「思考」，直接「说话」与首句欢迎 TTS 对齐；播完后由 [onTtsCompleted] 与聆听态衔接
  void handleWakeUpDirectlyToSpeaking() {
    print("🎭 唤醒：跳过思考序列，直接说话表情");
    _stageTimer?.cancel();
    _stageTimer = null;
    handleNormalChatAnimation();
  }

  /// 大模型/网络等待期间：保持「思考」态，避免嘴型先动、声音未到。
  void showThinkingAwaitingModel() {
    if (_currentMode != ProgramMode.conversation) return;
    print('🎭 等待模型回复 → 思考表情');
    _switchToAnimation(AnimationType.thinkingStage2);
  }

  /// 图片分析播报：取消分阶段计时，直接与 TTS 同步到「观察」终态。
  void applyImageSpeakExpressionForTts() {
    print('🎭 TTS 同步：图片分析说话态（观察 02）');
    _stageTimer?.cancel();
    _stageTimer = null;
    _switchToAnimation(AnimationType.observeStage2);
  }

  /// 在即将播放 TTS 前应用与 [expression] 一致的表情（须在大模型返回后调用）。
  void applyExpressionAlignedWithTts(
    TtsAlignedExpression expression, {
    String? emotionUiLabel,
  }) {
    switch (expression) {
      case TtsAlignedExpression.none:
        return;
      case TtsAlignedExpression.textChatSpeaking:
        handleNormalChatAnimation();
        return;
      case TtsAlignedExpression.actionCommandSpeaking:
        handleCommandAnimation();
        return;
      case TtsAlignedExpression.imageObserveSpeaking:
        applyImageSpeakExpressionForTts();
        return;
      case TtsAlignedExpression.emotionSpeaking:
        final label = emotionUiLabel ?? '中性';
        handleEmotionAnimation(label);
        return;
    }
  }

  /// 处理情绪识别模块的动画
  void handleEmotionAnimation(String emotion) {
    print("🎭 处理情绪动画: $emotion");

    AnimationType animationType;
    switch (emotion.toLowerCase()) {
      case '高兴':
      case '正能量':
      case 'happy':
        animationType = AnimationType.happyEmotion;
        break;
      case '悲伤':
      case '负能量':
      case 'sad':
        animationType = AnimationType.sadEmotion;
        break;
      case '愤怒':
      case 'angry':
        animationType = AnimationType.angryEmotion;
        break;
      case '惊讶':
      case 'surprise':
        animationType = AnimationType.surpriseEmotion;
        break;
      case '坚定':
      case '谨慎':
      case 'firm':
        animationType = AnimationType.firmEmotion;
        break;
      case '中性':
      case '未知':
        animationType = AnimationType.thinkingStage2;
        break;
      default:
        print("⚠️ 未知情绪类型: $emotion，使用思考动画");
        animationType = AnimationType.thinkingStage2;
        break;
    }

    _switchToAnimation(animationType);
  }

  /// 处理动作指令模块的动画
  void handleCommandAnimation() {
    print("🎭 处理动作指令动画");
    _switchToAnimation(AnimationType.commandEager);
  }

  /// 处理图片分析模块的动画
  /// 先显示观察 01.json 500ms，然后显示观察 02.json
  void handleImageAnalysisAnimation() {
    print("🎭 处理图片分析动画");

    // 第一阶段：显示观察 01.json
    _switchToAnimation(AnimationType.observeStage1);

    // 500ms后切换到观察 02.json
    _stageTimer?.cancel();
    _stageTimer = Timer(Duration(milliseconds: 500), () {
      _switchToAnimation(AnimationType.observeStage2);
      print("🎭 图片分析动画序列完成");
    });
  }

  /// 处理正常对话模块的动画
  void handleNormalChatAnimation() {
    print("🎭 处理正常对话动画");
    _switchToAnimation(AnimationType.chatting);
  }

  /// Planner 或任务执行器「每步开始」时调用：按白名单标签切 Lottie（与 [PlannerExpressionCatalog] 一致）。
  void applyPlannerExpressionLabel(String label) {
    if (_currentMode != ProgramMode.conversation) return;
    final canonical = PlannerExpressionCatalog.canonicalize(label);
    final path = PlannerExpressionCatalog.assetPathFor(canonical);
    if (path != null) {
      print('🎭 Planner 表情: $canonical → $path');
      setAnimation(path);
      return;
    }
    print('⚠️ Planner 表情无资源映射: $canonical，回退思考');
    _switchToAnimation(AnimationType.thinkingStage2);
  }

  /// 连续对话内 ASR 聆听中：可爱 02
  void showConversationListeningFace() {
    if (_currentMode != ProgramMode.conversation) return;
    print('🎭 聆听中 → 可爱 02');
    _switchToAnimation(AnimationType.listeningCute);
  }

  /// TTS播放完成后回到连续对话默认界面
  void onTtsCompleted() {
    if (_currentMode == ProgramMode.conversation) {
      print("🎭 TTS播放完成，进入聆听态（可爱 02）");
      _switchToAnimation(AnimationType.listeningCute);
    } else {
      print("🎭 TTS播放完成，回到空闲状态");
      _switchToAnimation(AnimationType.idle);
    }
  }

  /// 切换动画
  void _switchToAnimation(AnimationType type) {
    if (_isAnimationLocked) {
      print("🔒 动画已锁定，跳过切换请求: $type");
      return;
    }

    final animationPath = _animationPaths[type];
    if (animationPath == null) {
      print("❌ 未找到动画路径: $type");
      return;
    }

    if (_currentAnimation != animationPath) {
      _currentAnimation = animationPath;
      print("🎭 切换动画: $type → $animationPath");

      // 通知UI层更新
      _animationCallback?.call(_currentAnimation);
      notifyListeners();
    }
  }

  /// 直接设置动画（用于特殊情况）
  void setAnimation(String animationPath) {
    if (_currentAnimation != animationPath) {
      _currentAnimation = animationPath;
      print("🎭 直接设置动画: $animationPath");

      _animationCallback?.call(_currentAnimation);
      notifyListeners();
    }
  }

  /// 锁定动画（防止在特定时期被修改）
  void lockAnimation() {
    _isAnimationLocked = true;
    print("🔒 动画已锁定");
  }

  /// 解锁动画
  void unlockAnimation() {
    _isAnimationLocked = false;
    print("🔓 动画已解锁");
  }

  /// 重置到空闲状态
  void reset() {
    print("🔄 界面变换模块重置");

    _cancelAllTimers();
    _isAnimationLocked = false;
    _currentMode = ProgramMode.idle;
    _switchToAnimation(AnimationType.idle);
  }

  /// 取消所有计时器
  void _cancelAllTimers() {
    _animationTimer?.cancel();
    _stageTimer?.cancel();
  }

  /// 释放资源
  void dispose() {
    print("🗑️ 界面变换模块释放资源");
    _cancelAllTimers();
    _animationCallback = null;
    super.dispose();
  }
}
