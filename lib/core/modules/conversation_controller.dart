import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:voicegpt/core/modules/intent_recognition_module.dart';
import 'package:voicegpt/core/modules/text_qa_module.dart';
import 'package:voicegpt/core/modules/image_analysis_module.dart';
import 'package:voicegpt/core/modules/emotion_recognition_module.dart';
import 'package:voicegpt/core/modules/action_command_module.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/modules/user_detection_module.dart';
import 'package:voicegpt/core/modules/environ_monitor_module.dart';
import 'package:voicegpt/core/modules/plan_executor_controller.dart';
import 'package:voicegpt/core/llm/llm_router.dart';
import 'package:voicegpt/core/llm/llm_planner.dart';
import 'package:voicegpt/core/llm/planner_expression_catalog.dart';
import 'package:voicegpt/core/motion/motion_step_bluetooth.dart';
import 'package:voicegpt/core/services/voice_tts_factory.dart';
import 'package:voicegpt/core/services/voice_tts_service.dart';
import 'package:voicegpt/core/llm/conversation_context_pack.dart';
import 'package:voicegpt/core/services/ambient_context_cache.dart';
import 'package:voicegpt/core/services/device_context_service.dart';
import 'package:voicegpt/core/services/local_music_service.dart';
import 'package:voicegpt/core/storage/app_database.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';
import 'package:voicegpt/core/models/conversation_history_turn.dart';
import 'package:voicegpt/core/models/tts_voice_option.dart';
import 'package:voicegpt/core/utils/input_language_gate.dart';
import 'package:voicegpt/core/services/camera_resource_manager.dart'
    show CameraTaskPriority;
import 'package:voicegpt/core/config/debug_runtime_flags.dart';
import 'package:voicegpt/core/debug/conversation_flow_tracer.dart';

enum _VaValueKind { valence, arousal, dominance }

/// 连续对话控制器
/// 统一管理连续对话模式的主流程，协调各个功能模块
class ConversationController extends ChangeNotifier {
  static final ConversationController _instance =
      ConversationController._internal();
  factory ConversationController() => _instance;
  ConversationController._internal();

  static const String _stockVaDemoFirstReply =
      '听起来你对这只股票的下跌有些担心。先别急着做决定，短期下跌不一定代表基本面恶化，也可能和大盘情绪、行业消息、资金流出或者短线回调有关。你可以先看一下它下跌的原因，是不是有业绩、政策或者公司公告方面的变化。如果只是市场波动，没必要因为一两天的跌幅就情绪化操作；但如果基本面出现明显问题，也要及时控制风险。';
  static const String _stockVaDemoSecondReply =
      '听你的语气，好像是在观察它有没有更合适的入场机会。下跌确实可能带来更低的买入价格，但不能只因为跌了就马上抄底。建议先判断它为什么跌：如果是大盘整体回调，可以继续观察支撑位和成交量；如果是公司自身利空，就要更谨慎。你可以把它放进观察名单，等走势稳定、风险释放后再考虑分批介入。';

  // 语音通知器引用（用于启动语音识别）
  dynamic _speechNotifier;

  // 对话退出回调
  Function()? _onConversationExit;

  // 各功能模块
  final IntentRecognitionModule _intentModule = IntentRecognitionModule();
  final TextQAModule _textQAModule = TextQAModule();
  final LlmRouter _llmRouter = LlmRouter();
  final LlmPlanner _llmPlanner = LlmPlanner();
  final PlanExecutorController _planExecutor = PlanExecutorController();
  final ImageAnalysisModule _imageModule = ImageAnalysisModule();
  final EmotionRecognitionModule _emotionModule = EmotionRecognitionModule();
  final ActionCommandModule _actionModule = ActionCommandModule();
  final UIAnimationModule _uiModule = UIAnimationModule();
  final UserDetectionModule _userDetectionModule = UserDetectionModule();
  final EnvironMonitorModule _environModule = EnvironMonitorModule();
  late VoiceTtsService _ttsService;
  bool _ttsServiceReady = false;

  // 连续对话状态
  bool _isInConversationMode = false;
  bool _isProcessingUserInput = false;
  bool _isTtsPlaying = false;
  bool _isComplexTaskExecuting = false;
  bool _plannerStopRequested = false;
  String _lastAppliedPlannerExpression = '';
  final List<String> _plannerCapturedImagePaths = [];
  bool _plannerDidBatchAnalyze = false;
  String _lastRouterDecision = '';
  String _lastPlannerPlanDisplay = '';
  bool _forceEnglishTeachingMode = false;
  bool _ttsInterruptInFlight = false;
  Timer? _conversationTimeoutTimer;

  // 30秒超时设置
  static const Duration _conversationTimeout = Duration(seconds: 30);

  /// Planner 单步墙钟：进入具体 step 后等待其执行完成，超时仅作最终兜底。
  static const Duration _plannerStepTimeoutQuick = Duration(seconds: 120);
  static const Duration _plannerStepTimeoutBluetooth = Duration(seconds: 20);
  static const Duration _plannerStepTimeoutVision = Duration(seconds: 240);

  /// 蓝牙步内与动作并行的短口播分支上限（勿过长，避免与 5s 整步冲突）。
  static const int _plannerVisionTtsMaxChars = 600;

  bool _planExecutorListenerAttached = false;

  // 对话历史和上下文
  String _lastUserInput = "";
  int _stockVaDemoQuestionCount = 0;

  /// 最近若干轮「用户/小航」文本，供 C 层注入（最多约 4 轮）
  final List<String> _dialogTurnLines = [];

  /// 上一轮处理结束时间，用于「距上次交互」描述
  DateTime? _lastInteractionTime;
  DateTime? _continuousInputWindowStart;
  DateTime? _lastInputAt;
  int _continuousInputCount = 0;

  static const Duration _continuousInputWindowLimit = Duration(minutes: 2);
  static const Duration _continuousInputGapReset = Duration(seconds: 8);
  static const int _continuousInputCountLimit = 18;

  /// 状态访问器
  bool get isInConversationMode => _isInConversationMode;
  bool get isProcessingUserInput => _isProcessingUserInput;
  bool get isTtsPlaying => _isTtsPlaying;
  bool get forceEnglishTeachingMode => _forceEnglishTeachingMode;
  bool get isComplexTaskExecuting => _isComplexTaskExecuting;
  String get lastRouterDecision => _lastRouterDecision;

  /// scene=Agent 且 complexity=C 时 Planner 的多行展示（接在 Router 调试条之后）；否则为空。
  String get lastPlannerPlanDisplay => _lastPlannerPlanDisplay;
  PlanExecutionState get planExecutionState => _planExecutor.state;
  int get planTotalSteps => _planExecutor.totalSteps;
  int get planCurrentStep => _planExecutor.currentStep;
  String get planLastError => _planExecutor.lastError;

  void setForceEnglishTeachingMode(bool enabled) {
    if (_forceEnglishTeachingMode == enabled) return;
    _forceEnglishTeachingMode = enabled;
    print('🌐 强制英文教学模式: ${enabled ? "开启" : "关闭"}');
    _notifySpeechUi();
    notifyListeners();
  }

  /// 当前 TTS 是否为本机后端（始终为腾讯云云端时为 `false`；需在 [initialize] 之后访问）
  bool get isTtsLocalBackend => _ttsService.isLocalBackend;
  String get lastUserInput => _lastUserInput;

  /// 初始化连续对话控制器
  Future<void> initialize() async {
    print("🎤 初始化连续对话控制器");

    // 初始化各个模块
    await _intentModule.initialize();

    final selectedVoiceType = PreferenceManager().getTtsVoiceType();
    final selectedVoice = ttsVoiceOptionForType(selectedVoiceType);
    print(
      '🎙️ TTS 声线: ${selectedVoice.name} '
      '(${selectedVoice.category}, ${selectedVoice.voiceType})',
    );
    _ttsService = await _createTtsService(selectedVoice.voiceType);
    _ttsServiceReady = true;

    // 设置UI动画回调
    _uiModule.initialize();

    if (DebugRuntimeFlags.enableEnvironmentMonitoring) {
      _initializeEnvironMonitorModule();
    } else {
      print(
        '════════ 已跳过环境监测模块初始化（DebugRuntimeFlags.enableEnvironmentMonitoring=false）════════',
      );
    }

    AmbientContextCache.instance.configure(
      isAmbientRefreshAllowed: () =>
          !isInConversationMode && !isProcessingUserInput && !isTtsPlaying,
    );
    try {
      await AmbientContextCache.instance
          .primeFromIpNow()
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      print('⚠️ 启动阶段 IP 缓存预热超时/失败: $e');
    }
    unawaited(AmbientContextCache.instance.refreshNow(force: true));
    AmbientContextCache.instance.startPeriodic(const Duration(minutes: 30));
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5), () async {
        if (!isInConversationMode) {
          LocalMusicService.instance.scheduleRescan();
        }
      }),
    );

    if (!_planExecutorListenerAttached) {
      _planExecutor.addListener(_onPlanExecutorChanged);
      _planExecutorListenerAttached = true;
    }

    print("✅ 连续对话控制器初始化完成");
  }

  Future<VoiceTtsService> _createTtsService(int voiceType) {
    const tencentAppId =
        int.fromEnvironment('TENCENT_TTS_APP_ID', defaultValue: 0);
    const tencentSecretId =
        String.fromEnvironment('TENCENT_TTS_SECRET_ID', defaultValue: '');
    const tencentSecretKey =
        String.fromEnvironment('TENCENT_TTS_SECRET_KEY', defaultValue: '');
    return VoiceTtsServiceFactory.create(
      tencentAppId: tencentAppId,
      tencentSecretId: tencentSecretId,
      tencentSecretKey: tencentSecretKey,
      tencentVoiceType: voiceType,
    );
  }

  Future<void> updateTtsVoiceType(int voiceType) async {
    final selectedVoice = ttsVoiceOptionForType(voiceType);
    if (!_ttsServiceReady) {
      print(
        '🎙️ TTS 尚未初始化，已保存声线，稍后使用: '
        '${selectedVoice.name} (${selectedVoice.voiceType})',
      );
      return;
    }
    print(
      '🎙️ 切换 TTS 声线: ${selectedVoice.name} '
      '(${selectedVoice.category}, ${selectedVoice.voiceType})',
    );
    try {
      await _ttsService.release();
    } catch (e) {
      print('⚠️ 释放旧 TTS 服务失败: $e');
    }
    _ttsService = await _createTtsService(selectedVoice.voiceType);
    _environModule.setTTSService(_ttsService);
  }

  void _onPlanExecutorChanged() {
    notifyListeners();
    _notifySpeechUi();
  }

  /// 初始化环境监测模块
  void _initializeEnvironMonitorModule() {
    if (!DebugRuntimeFlags.enableEnvironmentMonitoring) return;
    try {
      print("🌍 开始初始化环境监测模块（延迟配置，不阻塞主线程）");

      // 设置依赖服务
      _environModule.setTTSService(_ttsService);
      _environModule.setUIModule(_uiModule);

      // 设置状态回调
      _environModule.setStateCallbacks(
        isAnswering: () => _isProcessingUserInput,
        isTtsPlaying: () => _isTtsPlaying,
        onWakeWordRestart: () {
          // 重启唤醒词检测的回调
          if (_speechNotifier != null) {
            try {
              // 调用speech notifier的重启唤醒词方法
              _speechNotifier.restartWakeWordDetection?.call();
              print("🎤 通过ConversationController重启唤醒词检测");
            } catch (e) {
              print("❌ 重启唤醒词检测失败: $e");
            }
          }
        },
        onGestureDetectionStart: () {
          // 启动手势检测的回调
          if (_speechNotifier != null) {
            try {
              _speechNotifier.startGestureRecognition?.call();
              print("👋 通过ConversationController启动手势检测");
            } catch (e) {
              print("❌ 启动手势检测失败: $e");
            }
          }
        },
      );

      print("✅ 环境监测模块配置完成（不占用麦克风资源）");
    } catch (e) {
      print("❌ 环境监测模块初始化失败: $e");
    }
  }

  /// 设置蓝牙服务
  void setBluetoothService(dynamic bluetoothService) {
    _actionModule.initializeBluetoothService(bluetoothService);
    _userDetectionModule.initializeBluetoothService(bluetoothService);
    _environModule.setBluetoothService(bluetoothService);
    print("🔗 连续对话控制器：已设置所有模块的蓝牙服务");
  }

  /// 设置语音通知器引用
  void setSpeechNotifier(dynamic speechNotifier) {
    _speechNotifier = speechNotifier;
    print("🔗 连续对话控制器已设置语音通知器引用");
  }

  /// [Consumer] 只监听 [SpeechNotifierSimplified] 时，依赖本控制器的状态需由此刷新。
  void _notifySpeechUi() {
    final n = _speechNotifier;
    if (n is ChangeNotifier) {
      n.notifyListeners();
    }
  }

  /// TTS 播放期间 Sherpa KWS 命中后调用；随后 `_speakText` 的 `finally` 会拉起主 ASR。
  /// 多人模式底部按住说话触发的 TTS 打断（与 Sherpa/VAD 打断区分）。
  static const String kTtsInterruptKeywordMultiPersonPtt = 'multi_person_ptt';

  /// 声纹模式：VAD + embedding 验证通过后的 TTS 打断。
  static const String kTtsInterruptKeywordOwnerVoiceprint = 'owner_voiceprint';

  Future<void> interruptConversationTtsFromKws(String keyword) async {
    try {
      final sn = _speechNotifier;
      if (sn != null) {
        if (sn.skipAutoVoiceRecognitionInConversation == true &&
            keyword != kTtsInterruptKeywordMultiPersonPtt) {
          print('🛑 [TTS打断] 多人按住说话模式，已禁用 (keyword=$keyword)');
          return;
        }
        final voiceprintGate =
            sn.isOwnerVoiceprintBargeInMode == true || sn.isOwnerMode == true;
        final hasOwner = sn.hasOwnerVoiceprint == true;
        if (voiceprintGate && hasOwner) {
          if (keyword != kTtsInterruptKeywordOwnerVoiceprint &&
              keyword != kTtsInterruptKeywordMultiPersonPtt) {
            print('🛑 [TTS打断] 主人/声纹模式：未验证声纹，忽略 (keyword=$keyword)');
            return;
          }
        } else if (voiceprintGate && !hasOwner) {
          print('🛑 [TTS打断] 主人/声纹模式未注册主人，忽略 (keyword=$keyword)');
          return;
        }
      }
    } catch (_) {}
    if (!_isTtsPlaying) {
      print("🛑 [TTS打断] 跳过：当前未在播放 TTS (keyword=$keyword)");
      return;
    }
    if (_ttsInterruptInFlight) {
      print("🛑 [TTS打断] 跳过：已有打断在处理 (keyword=$keyword)");
      return;
    }
    _ttsInterruptInFlight = true;
    try {
      print(
          "🛑 [TTS打断] 执行 stop() keyword=$keyword inConversation=$_isInConversationMode");
      if (_isInConversationMode && _isTtsPlaying) {
        _isTtsPlaying = false;
        notifyListeners();
        _notifySpeechUi();
        _uiModule.onTtsCompleted();
      }
      await _ttsService.stop();
    } catch (e) {
      print("❌ [TTS打断] stop 失败: $e");
    } finally {
      _ttsInterruptInFlight = false;
      await LocalMusicService.instance.resumeAfterTtsIfPaused();
    }
  }

  /// 对话内 TTS 前：恢复 Sherpa 麦克风（VoIP+AEC 路径由通知器侧已配置）。
  Future<void> prepareSherpaBargeInForConversationTts() async {
    try {
      if (!_isInConversationMode) return;
      if (_speechNotifier != null &&
          _speechNotifier.prepareSherpaBargeInForConversationTts != null) {
        print("🎧 [TTS打断] 调用 prepareSherpaBargeInForConversationTts");
        await _speechNotifier.prepareSherpaBargeInForConversationTts();
      }
    } catch (e) {
      print("⚠️ [TTS打断] prepareSherpa 失败: $e");
    }
  }

  /// 设置对话退出回调
  void setConversationExitCallback(Function() callback) {
    _onConversationExit = callback;
    print("🔗 连续对话控制器已设置退出回调");
  }

  /// 进入连续对话模式
  Future<void> enterConversationMode() async {
    if (_isInConversationMode) {
      print("⚠️ 已在连续对话模式中");
      return;
    }

    print("🎤 进入连续对话模式");
    _isInConversationMode = true;
    _resetContinuousInputGuard();
    _stockVaDemoQuestionCount = 0;

    // 设置UI模式
    _uiModule.setProgramMode(ProgramMode.conversation);

    // 唤醒直出「说话」态，避免先闪「思考」再等首句 TTS（与 onPlaybackStarted 对齐出声）
    _uiModule.handleWakeUpDirectlyToSpeaking();

    // 播放欢迎语音（语音识别和超时计时器将在TTS完成后启动）
    await _speakText(
      "你好，请说",
      ttsExpression: TtsAlignedExpression.textChatSpeaking,
    );

    // 启动用户监测（并行执行，不阻塞主流程）
    _startUserDetectionInBackground();

    // 注意：语音识别和30秒超时计时器现在在TTS播放完成后启动（_speakText的finally块中）

    notifyListeners();
    print("✅ 连续对话模式已启动");
  }

  /// 后台启动用户监测
  void _startUserDetectionInBackground() {
    print("🔍 启动后台用户监测");

    // 异步执行用户监测，不阻塞主对话流程
    Future.microtask(() async {
      try {
        final result = await _userDetectionModule.startUserDetection();
        print("🔍 用户监测完成: $result");
      } catch (e) {
        print("❌ 用户监测失败: $e");
      }
    });
  }

  /// 处理用户输入
  Future<RouterDecision> previewRouterDecision(String userInput) async {
    final routerPack = await _buildRouterContextPack(userInput);
    return _llmRouter.route(
      userInput: userInput,
      contextPack: routerPack,
      replyLengthMode: _replyLengthModeHint(),
    );
  }

  Future<void> processUserInput(
    String userInput, {
    Map<String, dynamic>? vaResult,
    RouterDecision? precomputedRouterDecision,
  }) async {
    if (!_isInConversationMode) {
      ConversationFlowTracer.orphan(
        'processUserInput_IGNORED not_in_conversation_mode',
      );
      print("⚠️ 不在连续对话模式，忽略用户输入");
      return;
    }

    if (_isImmediateStopCommand(userInput)) {
      ConversationFlowTracer.orphan('processUserInput immediate_stop_command');
      await _handleImmediateStopCommand(userInput);
      return;
    }

    if (_isProcessingUserInput && _isComplexTaskExecuting) {
      ConversationFlowTracer.orphan(
        'processUserInput interrupt_complex_task_for_new_input',
      );
      await _interruptComplexTaskForNewInput(userInput);
    }

    if (_isProcessingUserInput) {
      ConversationFlowTracer.orphan(
        'processUserInput_IGNORED already_processing',
      );
      print("⏳ 正在处理用户输入，忽略新输入");
      return;
    }

    // 单字环境 ASR 噪声：视为未输入——不占处理位、不记轮次、不取消 30s 计时器、不播「没听清」。
    if (isSingleHanAsrNoise(userInput)) {
      ConversationFlowTracer.orphan(
        'processUserInput_IGNORED single_han_noise="${userInput.trim()}"',
      );
      print('🔇 环境噪声单字已忽略: ${userInput.trim()}');
      return;
    }

    print("💬 处理用户输入: $userInput");
    // 与进入连续对话时启动的「720° 机身找用户」并行；用户已开口则取消扫描，避免聊天中途突然转圈。
    _userDetectionModule.stopUserDetection();

    _isProcessingUserInput = true;
    _planExecutor.reset();
    _notifySpeechUi();
    _lastUserInput = userInput;
    _recordContinuousInput(userInput);

    ConversationFlowTracer.beginTurn(userInput);
    final turnSw = Stopwatch()..start();
    try {
      if (_shouldForceExitForContinuousInput()) {
        ConversationFlowTracer.step('safety_exit_continuous_input');
        await _handleContinuousInputSafetyExit();
        return;
      }

      // 检查是否为退出指令：先走一轮温暖告别，再退出
      if (_isExitCommand(userInput)) {
        ConversationFlowTracer.step('exit_command_matched');
        await _handleExitIntent(userInput);
        return;
      }

      _uiModule.showThinkingAwaitingModel();

      // 取消当前的30秒计时器（用户开始说话，暂停计时）
      _conversationTimeoutTimer?.cancel();
      ConversationFlowTracer.step('timeout30_cancelled_will_restart_after_tts');
      print("🔄 收到用户输入，取消超时计时器（计时将在TTS完成后重新启动）");

      if (_isLikelyInvalidInput(userInput)) {
        print(
          '🔕 一级路由：无效输入，不走大模型: '
          '${userInput.trim().length <= 2 ? userInput.trim() : "…"}',
        );
        ConversationFlowTracer.step('invalid_input_short_reply');
        await _speakText(
          "没听清，您再说一遍？",
          ttsExpression: TtsAlignedExpression.textChatSpeaking,
        );
        return;
      }

      _pushDialogLine('用户：$userInput');

      if (await _tryHandleStockVaDemoReply(userInput)) {
        return;
      }

      if (_forceEnglishTeachingMode ||
          InputLanguageGate.isEnglishTeachingScene(userInput)) {
        ConversationFlowTracer.step(
          'branch_english_teaching',
          'force=$_forceEnglishTeachingMode',
        );
        print(
          _forceEnglishTeachingMode
              ? '🌐 强制英文教学模式：锁定英语教学场景（跳过意图链路）'
              : '🌐 英文/中英混排门控：走英语教学场景（等同对话链路，专属 prompt）',
        );
        await _handleTextQA(
          userInput,
          sceneIntent: IntentType.dialogue,
          englishTeachingScene: true,
        );
        return;
      }

      ConversationFlowTracer.step('router_context_pack_begin');
      final routerDecision = precomputedRouterDecision ??
          await (() async {
            final routerPack = await _buildRouterContextPack(userInput);
            ConversationFlowTracer.step('router_llm_route_begin');
            return _llmRouter.route(
              userInput: userInput,
              contextPack: routerPack,
              replyLengthMode: _replyLengthModeHint(),
            );
          })();
      _lastRouterDecision = routerDecision.rawJson;
      _lastPlannerPlanDisplay = '';
      final rj = routerDecision.rawJson;
      final rjShort = rj.length > 160 ? '${rj.substring(0, 160)}…' : rj;
      ConversationFlowTracer.step(
        'router_done',
        'scene=${routerDecision.scene} complexity=${routerDecision.complexity} '
            'needTools=${routerDecision.needTools} raw=$rjShort',
      );
      print('🧭 [Router] $_lastRouterDecision');
      _notifySpeechUi();
      notifyListeners();

      if (routerDecision.scene == RouterScene.agent &&
          routerDecision.complexity == RouterComplexity.c) {
        ConversationFlowTracer.step('branch_planner_agent_c');
        _isComplexTaskExecuting = true;
        _notifySpeechUi();
        notifyListeners();
        try {
          await _runPlannerLlmForDisplayOnly(userInput);
        } finally {
          _isComplexTaskExecuting = false;
          _notifySpeechUi();
          notifyListeners();
        }
        ConversationFlowTracer.step('branch_planner_agent_c_return');
        return;
      }

      if (!routerDecision.needTools) {
        ConversationFlowTracer.step('branch_router_no_tools');
        if (routerDecision.scene == RouterScene.companion) {
          ConversationFlowTracer.step(
            'router_companion_force_textqa_with_va',
            'hasVa=${vaResult != null}',
          );
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.comfort,
            vaResult: vaResult,
          );
          return;
        }
        final directReply = routerDecision.dialogueReply.trim();
        if (directReply.isNotEmpty) {
          ConversationFlowTracer.step(
            'router_direct_reply_tts',
            'len=${directReply.length}',
          );
          await _speakText(
            directReply,
            ttsExpression: TtsAlignedExpression.textChatSpeaking,
            recordAssistantForTurns: directReply,
          );
          _textQAModule.recordRouterDirectTurn(userInput, directReply);
        } else {
          ConversationFlowTracer.step('router_fallback_textqa', 'dialogue');
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.dialogue,
            vaResult: vaResult,
          );
        }
        return;
      }

      _isComplexTaskExecuting = routerDecision.scene == RouterScene.agent ||
          routerDecision.complexity == RouterComplexity.c;
      if (_isComplexTaskExecuting) {
        _notifySpeechUi();
        notifyListeners();
      }

      if (await _tryExecuteRouterMotionStep(routerDecision, userInput)) {
        ConversationFlowTracer.step('branch_router_motion_done');
        return;
      }

      if (routerDecision.needTools &&
          routerDecision.scene == RouterScene.visionVlm &&
          routerDecision.complexity == RouterComplexity.b) {
        ConversationFlowTracer.step('branch_vision_vlm_b_skip_bert');
        print('📷 [Router] VisionVlm+B → 图像分析（跳过 BERT 意图）');
        await _handleImageAnalysis(userInput);
        return;
      }

      // 意图识别
      ConversationFlowTracer.step('intent_bert_begin');
      final intentSw = Stopwatch()..start();
      final intentResult = await _intentModule.predictIntent(userInput);
      intentSw.stop();
      ConversationFlowTracer.step(
        'intent_bert_done',
        '${intentSw.elapsedMilliseconds}ms valid=${intentResult.isValid} '
            'label=${intentResult.intent}',
      );
      print(
        '⏱️ [ConvStage][意图识别] ${intentSw.elapsedMilliseconds}ms → $intentResult',
      );

      if (!intentResult.isValid) {
        // 意图识别置信度低，默认进入文本问答（普通问答场景）
        ConversationFlowTracer.step('intent_low_confidence_textqa_dialogue');
        print("⚠️ 意图识别置信度低，进入文本问答模式");
        await _handleTextQA(
          userInput,
          sceneIntent: IntentType.dialogue,
          vaResult: vaResult,
        );
        return;
      }

      // 根据意图分发到不同模块（六类 + unknown，与 BERT 标签一致）
      ConversationFlowTracer.step('intent_dispatch', '${intentResult.intent}');
      switch (intentResult.intent) {
        case IntentType.comfort:
          await _handleEmotionRecognition(userInput, vaResult: vaResult);
          break;

        case IntentType.image:
          await _handleImageAnalysis(userInput);
          break;

        case IntentType.command:
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.command,
            vaResult: vaResult,
          );
          break;

        case IntentType.dialogue:
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.dialogue,
            vaResult: vaResult,
          );
          break;

        case IntentType.apiCall:
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.apiCall,
            vaResult: vaResult,
          );
          break;

        case IntentType.idle:
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.idle,
            vaResult: vaResult,
          );
          break;

        case IntentType.unknown:
          await _handleTextQA(
            userInput,
            sceneIntent: IntentType.unknown,
            vaResult: vaResult,
          );
          break;
      }
    } catch (e, st) {
      ConversationFlowTracer.step('processUserInput_catch', '$e');
      print("❌ 处理用户输入失败: $e\n$st");
      await _speakText(
        "抱歉，我现在无法处理您的请求，请重试",
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: "抱歉，我现在无法处理您的请求，请重试",
      );
    } finally {
      turnSw.stop();
      print(
        '⏱️ [ConvStage][本轮用户输入总墙钟] ${turnSw.elapsedMilliseconds}ms '
        '(processUserInput 起至处理结束，含意图/TTS 等)',
      );
      _lastInteractionTime = DateTime.now();
      _isComplexTaskExecuting = false;
      _isProcessingUserInput = false;
      ConversationFlowTracer.endTurn(
        'procUserInput_finally elapsedMs=${turnSw.elapsedMilliseconds}ms',
      );
      _notifySpeechUi();
      notifyListeners();
    }
  }

  /// Agent + C：调用 Planner LLM，并按 step 顺序执行（蓝牙/TTS 步内表情与口播与动作并行；视觉步先识别再播结论）。
  Future<void> _runPlannerLlmForDisplayOnly(String userInput) async {
    _plannerStopRequested = false;
    _lastAppliedPlannerExpression = '';
    _plannerCapturedImagePaths.clear();
    _plannerDidBatchAnalyze = false;
    // 复杂任务执行期间保持 ASR 常开，便于随时语音打断。
    await _startVoiceRecognition();
    var planFailed = false;
    var failureHint = '';
    try {
      final result = await _llmPlanner.plan(userGoal: userInput);
      if (result.steps.isEmpty) {
        print('[Plan] (无有效步骤) raw=${result.rawContent}');
        _lastPlannerPlanDisplay = '[Plan] (无有效步骤)\n${result.rawContent.trim()}';
      } else {
        final buf = StringBuffer();
        for (var i = 0; i < result.steps.length; i++) {
          final s = result.steps[i];
          final pt = s.parallelTts == null || s.parallelTts!.isEmpty
              ? ''
              : ' parallel_tts=${s.parallelTts}';
          final line =
              '[Plan] step${i + 1} action=${s.action} expression=${s.expression} reply=${s.reply}$pt';
          print(line);
          buf.writeln(line);
        }
        _lastPlannerPlanDisplay = buf.toString().trimRight();

        await _planExecutor.executeSteps(
          result.steps,
          timeoutForStep: _plannerStepTimeoutFor,
          runStep: _runPlannerStep,
        );
        if (_planExecutor.state == PlanExecutionState.done &&
            !_plannerDidBatchAnalyze &&
            _plannerCapturedImagePaths.length >= 2) {
          final fallbackResult = await _imageModule.processMultiImageAnalysis(
            '请结合我刚刚旋转采集的多角度图片，做一次综合分析并给出结论。',
            List<String>.from(_plannerCapturedImagePaths),
            conversationContext: _getConversationContext(),
          );
          _plannerCapturedImagePaths.clear();
          _plannerDidBatchAnalyze = true;
          if (!fallbackResult.success) {
            throw Exception(
              '视觉/VLM 失败: ${fallbackResult.error ?? fallbackResult.response}',
            );
          }
          var toSpeak = fallbackResult.response.trim();
          toSpeak = _truncatePlannerVisionTts(toSpeak);
          if (toSpeak.isNotEmpty) {
            await _speakPlannerText(toSpeak);
          }
        }
        planFailed = _planExecutor.state == PlanExecutionState.failed;
        if (planFailed) {
          failureHint = _plannerFailureHint(_planExecutor.lastError);
        }
      }
    } catch (e, st) {
      print('[Plan] 请求失败: $e\n$st');
      _lastPlannerPlanDisplay = '[Plan] 错误: $e';
      planFailed = true;
      failureHint = _plannerFailureHint(e.toString());
    }
    if (planFailed && failureHint.isNotEmpty) {
      await _speakText(
        failureHint,
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: failureHint,
      );
      _notifySpeechUi();
      notifyListeners();
      return;
    }
    await _resumeListeningAfterPlanner(forceTtsStop: planFailed);
    _notifySpeechUi();
    notifyListeners();
  }

  String _plannerFailureHint(String rawError) {
    final e = rawError.trim();
    if (e.isEmpty) {
      return '任务执行失败，已退出当前任务。';
    }
    if (e.contains('蓝牙未连接') || e.contains('机器人未连接')) {
      return '蓝牙未连接，任务已停止。请先连接机器人后再试。';
    }
    if (e.contains('任务已被停止')) {
      return '已停止当前任务。';
    }
    if (e.contains('视觉/VLM 连接超时') ||
        (e.contains('视觉/VLM') && e.contains('超时'))) {
      return '视觉服务连接超时，任务已停止。请检查网络或服务状态后再试。';
    }
    if (e.contains('视觉/VLM 失败')) {
      return '视觉分析失败，任务已停止。请稍后重试。';
    }
    if (e.contains('Planner 分支') && e.contains('超过')) {
      return '任务步骤执行超时，已停止当前任务。';
    }
    return '任务执行失败：$e';
  }

  Duration _plannerStepTimeoutFor(PlannerStep step) {
    if (step.action == '视觉/VLM') return _plannerStepTimeoutVision;
    if (step.action == '蓝牙动作') return _plannerStepTimeoutBluetooth;
    return _plannerStepTimeoutQuick;
  }

  Future<void> _resumeListeningAfterPlanner({bool forceTtsStop = false}) async {
    if (!_isInConversationMode) return;
    if (forceTtsStop && _isTtsPlaying) {
      try {
        await _ttsService.stop();
      } catch (_) {}
      _isTtsPlaying = false;
      notifyListeners();
    }
    if (_isTtsPlaying) return;
    _uiModule.onTtsCompleted();
    try {
      await _startVoiceRecognition();
    } catch (e, st) {
      print("⚠️ Planner 完成后启动语音识别失败，重试一次: $e\n$st");
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        await _startVoiceRecognition();
      } catch (e2, st2) {
        print("❌ Planner 完成后二次启动语音识别仍失败: $e2\n$st2");
      }
    }
    _startConversationTimeout();
  }

  Future<void> _runPlannerStep(PlannerStep step) async {
    if (_plannerStopRequested) {
      throw Exception('任务已被停止');
    }
    switch (step.action) {
      case '蓝牙动作':
        final cue = (step.parallelTts?.trim().isNotEmpty ?? false)
            ? step.parallelTts!.trim()
            : '好。';
        await Future.wait<void>([
          _applyPlannerStepExpression(step),
          () async {
            final actionResult = await _actionModule.processActionCommand(
              step.reply,
              playCommandAnimation: false,
            );
            print(
              '[PlanExec][蓝牙] success=${actionResult.success} '
              'response=${actionResult.response}',
            );
            if (!actionResult.success) {
              final msg = actionResult.response.trim();
              if (msg.contains('不理解这个动作指令') || msg.contains('未识别')) {
                print('[PlanExec][蓝牙] 未识别动作，跳过本 step: ${step.reply}');
                return;
              }
              throw Exception(
                '蓝牙动作失败: ${actionResult.error ?? actionResult.response}',
              );
            }
          }(),
          _speakPlannerText(cue),
        ]);
        return;
      case '视觉/VLM':
        if (_isVisionBatchAnalyzeStep(step) &&
            _plannerCapturedImagePaths.length >= 2) {
          late final dynamic imageResult;
          await Future.wait<void>([
            _applyPlannerStepExpression(step),
            () async {
              imageResult = await _imageModule.processMultiImageAnalysis(
                step.reply,
                List<String>.from(_plannerCapturedImagePaths),
                conversationContext: _getConversationContext(),
              );
            }(),
          ]);
          _plannerCapturedImagePaths.clear();
          _plannerDidBatchAnalyze = true;
          print(
            '[PlanExec][视觉联合] success=${imageResult.success} '
            'resp=${imageResult.response.length > 30 ? '${imageResult.response.substring(0, 30)}…' : imageResult.response}',
          );
          if (!imageResult.success) {
            throw Exception(
              '视觉/VLM 失败: ${imageResult.error ?? imageResult.response}',
            );
          }
          var toSpeak = imageResult.response.trim();
          if (toSpeak.isEmpty) {
            toSpeak = step.reply.trim();
          }
          toSpeak = _truncatePlannerVisionTts(toSpeak);
          if (toSpeak.isNotEmpty) {
            await _speakPlannerText(toSpeak);
          }
          return;
        }

        if (_isVisionCaptureOnlyStep(step)) {
          final shotPath = await _imageModule.captureImageOnly(
            cameraCapturePriority: CameraTaskPriority.high,
          );
          _plannerCapturedImagePaths.add(shotPath);
          print(
              '[PlanExec][视觉采集] 已采集: $shotPath, total=${_plannerCapturedImagePaths.length}');
          await _applyPlannerStepExpression(step);
          return;
        }
        late final dynamic imageResult;
        await Future.wait<void>([
          _applyPlannerStepExpression(step),
          () async {
            imageResult = await _imageModule.processImageAnalysis(
              step.reply,
              conversationContext: _getConversationContext(),
              cameraCapturePriority: CameraTaskPriority.high,
            );
          }(),
        ]);
        print(
          '[PlanExec][视觉] success=${imageResult.success} '
          'resp=${imageResult.response.length > 30 ? '${imageResult.response.substring(0, 30)}…' : imageResult.response}',
        );
        if (!imageResult.success) {
          throw Exception(
            '视觉/VLM 失败: ${imageResult.error ?? imageResult.response}',
          );
        }
        var toSpeak = imageResult.response.trim();
        if (toSpeak.isEmpty) {
          toSpeak = step.reply.trim();
        }
        toSpeak = _truncatePlannerVisionTts(toSpeak);
        if (toSpeak.isNotEmpty) {
          await _speakPlannerText(toSpeak);
        }
        return;
      case 'TTS 播报':
        await Future.wait<void>([
          _applyPlannerStepExpression(step),
          _speakPlannerText(step.reply),
        ]);
        return;
      default:
        print('[PlanExec] 未知 action=${step.action}，仅表情');
        await _applyPlannerStepExpression(step);
        return;
    }
  }

  bool _isVisionCaptureOnlyStep(PlannerStep step) {
    if (step.action != '视觉/VLM') return false;
    final t = step.reply.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    const hints = ['仅拍照', '只拍照', '采集', '先拍', '不分析', '不做分析'];
    return hints.any(t.contains);
  }

  bool _isVisionBatchAnalyzeStep(PlannerStep step) {
    if (step.action != '视觉/VLM') return false;
    final t = step.reply.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    const hints = ['一起分析', '统一分析', '联合分析', '综合分析', '多图', '四张图', '汇总分析'];
    return hints.any(t.contains);
  }

  String _truncatePlannerVisionTts(String s) {
    if (s.length <= _plannerVisionTtsMaxChars) return s;
    return '${s.substring(0, _plannerVisionTtsMaxChars)}…';
  }

  bool _isImmediateStopCommand(String raw) {
    if (_isExitCommand(raw)) return false;
    final s = raw.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (s.isEmpty) return false;
    const hints = [
      '停止',
      '停下',
      '停住',
      '停',
      '别动',
      '不要动',
      '马上停',
      '立刻停',
      '紧急停止',
      'emergencystop',
      'stop',
    ];
    return hints.any((k) => s.contains(k));
  }

  Future<void> _handleImmediateStopCommand(String userInput) async {
    print('🛑 高优先级停止命令: $userInput');
    _plannerStopRequested = true;
    try {
      await _ttsService.stop();
    } catch (e) {
      print('⚠️ 停止 TTS 失败: $e');
    }
    await _actionModule.stopAllActions();
    _isTtsPlaying = false;
    _isComplexTaskExecuting = false;
    _isProcessingUserInput = false;
    _notifySpeechUi();
    notifyListeners();
    await _speakText(
      '已收到停止指令，当前动作已停止。',
      ttsExpression: TtsAlignedExpression.textChatSpeaking,
      recordAssistantForTurns: '已收到停止指令，当前动作已停止。',
    );
  }

  Future<void> _interruptComplexTaskForNewInput(String userInput) async {
    print('🛑 复杂任务被新语音打断，切换到新输入: $userInput');
    _plannerStopRequested = true;
    try {
      await _ttsService.stop();
    } catch (e) {
      print('⚠️ 打断复杂任务时停止 TTS 失败: $e');
    }
    await _actionModule.stopAllActions();
    _isTtsPlaying = false;
    _isComplexTaskExecuting = false;
    _isProcessingUserInput = false;
    _notifySpeechUi();
    notifyListeners();
  }

  Future<void> _applyPlannerStepExpression(PlannerStep step) async {
    var expr = PlannerExpressionCatalog.canonicalize(step.expression);
    // 若连续两步给到同一表情，执行层自动轮换一个，确保每步都有明显切换。
    if (_lastAppliedPlannerExpression == expr) {
      final labels = PlannerExpressionCatalog.allowedLabels;
      final idx = labels.indexOf(expr);
      if (idx >= 0) {
        expr = labels[(idx + 1) % labels.length];
      } else {
        expr = '眨眼';
      }
    }
    _lastAppliedPlannerExpression = expr;
    _uiModule.applyPlannerExpressionLabel(expr);
  }

  Future<void> _speakPlannerText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    _isTtsPlaying = true;
    _notifySpeechUi();
    notifyListeners();
    try {
      print('[PlanExec][TTS] $text');
      await _ttsService.speak(
        text,
        onPlaybackStarted: null,
      );
    } catch (e) {
      print('[PlanExec][TTS] 失败: $e');
    } finally {
      _isTtsPlaying = false;
      _notifySpeechUi();
      notifyListeners();
    }
  }

  /// Router 单轴 B 类：`motion_step` → 解析 → 单条蓝牙；不调 command 场景主 LLM。
  Future<bool> _tryExecuteRouterMotionStep(
    RouterDecision d,
    String userInput,
  ) async {
    if (!d.needTools) return false;
    if (d.scene != RouterScene.bluetoothMotion &&
        d.scene != RouterScene.toolUse) {
      return false;
    }
    if (d.complexity != RouterComplexity.b) return false;
    if (!MotionStepBluetooth.isSimpleCardinalMotionQuery(userInput)) {
      return false;
    }
    final raw = d.motionStep?.trim() ?? '';
    if (raw.isEmpty) return false;

    final action = MotionStepBluetooth.parseMotionStepToBluetooth(raw);
    if (action == null) {
      print('⚠️ [MotionStep] 无法解析 motion_step="$raw"，回退意图链路');
      return false;
    }
    print('🎯 [MotionStep] 执行单步 ${action.name} value=${action.value}');

    if (!_actionModule.isBluetoothConnected) {
      const msg = '机器人未连接';
      await _speakText(
        msg,
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: msg,
      );
      _textQAModule.recordRouterDirectTurn(userInput, msg);
      return true;
    }

    final spokenLine = d.dialogueReply.trim().isNotEmpty
        ? d.dialogueReply.trim()
        : MotionStepBluetooth.spokenAckFor(action);
    await _speakText(
      spokenLine,
      ttsExpression: TtsAlignedExpression.actionCommandSpeaking,
      recordAssistantForTurns: spokenLine,
    );

    final outcome =
        await _actionModule.applyStructuredBluetoothActions([action]);
    if (outcome.skippedDisconnected) {
      await _speakText(
        '机器人未连接',
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: '机器人未连接',
      );
    } else if (outcome.linearInterrupted) {
      final cliff =
          outcome.obstacleType == 0x03 || outcome.obstacleType == 0x04;
      final safety = cliff ? '要掉下去啦' : '马上碰撞啦';
      await _speakText(
        safety,
        ttsExpression: TtsAlignedExpression.emotionSpeaking,
        emotionUiLabel: '愤怒',
        recordAssistantForTurns: safety,
      );
    }

    _textQAModule.recordRouterDirectTurn(userInput, spokenLine);
    return true;
  }

  /// 处理情绪识别
  Future<void> _handleEmotionRecognition(
    String userInput, {
    Map<String, dynamic>? vaResult,
  }) async {
    print("😊 进入情绪识别模块");

    try {
      final result = await _emotionModule.processEmotionRecognition(
        userInput,
        conversationContext: _getConversationContext(),
      );

      final emoLabel =
          EmotionRecognitionModule.emotionToUiLabel(result.emotion);
      if (result.success) {
        await _speakText(
          result.response,
          ttsExpression: TtsAlignedExpression.emotionSpeaking,
          emotionUiLabel: emoLabel,
          recordAssistantForTurns: result.response,
        );
      } else {
        await _speakText(
          "我能感受到您的情绪，让我来陪陪您吧",
          ttsExpression: TtsAlignedExpression.emotionSpeaking,
          emotionUiLabel: emoLabel,
          recordAssistantForTurns: "我能感受到您的情绪，让我来陪陪您吧",
        );
      }
    } catch (e) {
      print("❌ 情绪识别处理失败: $e");
      await _speakText(
        "我理解您的感受",
        ttsExpression: TtsAlignedExpression.emotionSpeaking,
        emotionUiLabel: '中性',
        recordAssistantForTurns: "我理解您的感受",
      );
    }
  }

  /// 处理图片分析
  Future<void> _handleImageAnalysis(String userInput) async {
    ConversationFlowTracer.step('image_analysis_enter');
    print("📷 进入图片分析模块");

    try {
      final result = await _imageModule.processImageAnalysis(
        userInput,
        conversationContext: _getConversationContext(),
        cameraCapturePriority: CameraTaskPriority.high,
      );

      if (result.success) {
        await _speakText(
          result.response,
          ttsExpression: TtsAlignedExpression.imageObserveSpeaking,
          recordAssistantForTurns: result.response,
        );
      } else {
        await _speakText(
          "抱歉，我现在无法分析图片",
          ttsExpression: TtsAlignedExpression.textChatSpeaking,
          recordAssistantForTurns: "抱歉，我现在无法分析图片",
        );
      }
    } catch (e) {
      ConversationFlowTracer.step('image_analysis_catch', '$e');
      print("❌ 图片分析处理失败: $e");
      await _speakText(
        "图片分析遇到问题，请重试",
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: "图片分析遇到问题，请重试",
      );
    }
  }

  /// 从增量 token 缓冲区中提取可播报句段；未闭合尾巴保留在 [buf]。
  List<String> _extractReadySpeechChunks(StringBuffer buf) {
    final s = buf.toString();
    if (s.isEmpty) return const <String>[];
    final out = <String>[];
    var start = 0;
    // 更激进的切分：逗号类也可触发，缩短首句等待。
    bool isBreakChar(String ch) => '。！？.!?\n,，;；'.contains(ch);
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (!isBreakChar(ch)) continue;
      final seg = s.substring(start, i + 1).trim();
      if (seg.isNotEmpty) out.add(seg);
      start = i + 1;
    }
    final tail = s.substring(start);
    buf
      ..clear()
      ..write(tail);
    // 极长无标点时按 24 字强行吐出，优先首句时延。
    if (buf.length >= 24) {
      final forced = buf.toString().substring(0, 24).trim();
      if (forced.isNotEmpty) {
        out.add(forced);
      }
      final rest = buf.toString().substring(24);
      buf
        ..clear()
        ..write(rest);
    }
    return out;
  }

  /// 处理文本问答
  Future<void> _handleTextQA(
    String userInput, {
    IntentType sceneIntent = IntentType.dialogue,
    bool englishTeachingScene = false,
    Map<String, dynamic>? vaResult,
  }) async {
    ConversationFlowTracer.step(
      'textqa_enter',
      'scene=$sceneIntent english=$englishTeachingScene',
    );
    print(
      "💬 进入文本问答模块 scene=$sceneIntent "
      'englishTeaching=$englishTeachingScene',
    );
    if (sceneIntent == IntentType.comfort) {
      final fusionSummary = vaResult?['fusion_summary'];
      print(
        '💞 [Companion] 本轮改走 TextQA+VA '
        'hasVa=${vaResult != null} fusion=${fusionSummary ?? 'none'}',
      );
    }

    try {
      final contextPack = _buildContextPack(vaResult: vaResult);
      if (sceneIntent == IntentType.comfort && vaResult != null) {
        print(
          '🧩 [Companion][VA_CONTEXT] '
          '${contextPack.formatContextBlock().replaceAll('\n', ' | ')}',
        );
      }

      if (sceneIntent == IntentType.command &&
          !_actionModule.isBluetoothConnected) {
        await _speakText(
          '机器人未连接',
          ttsExpression: TtsAlignedExpression.textChatSpeaking,
          recordAssistantForTurns: '机器人未连接',
        );
        return;
      }

      if (sceneIntent == IntentType.apiCall &&
          LocalMusicService.isPlayMusicCommand(userInput)) {
        await LocalMusicService.instance.ensureInitialized();
        if (LocalMusicService.isSpecificSongRequest(userInput)) {
          await _speakText(
            '抱歉，这首歌暂时不能播放。受版权和应用权限限制，目前我只能播放应用内置的那一首音乐。',
            ttsExpression: TtsAlignedExpression.textChatSpeaking,
            recordAssistantForTurns:
                '抱歉，这首歌暂时不能播放。受版权和应用权限限制，目前我只能播放应用内置的那一首音乐。',
          );
          return;
        }
        final title = await LocalMusicService.instance.playRandomTrack();
        if (title == null) {
          LocalMusicService.instance.scheduleRescan();
          await _speakText(
            '抱歉，我暂时没找到应用内置音乐资源。请确认 mp3 已放在 assets/music 下并已加入资源清单。',
            ttsExpression: TtsAlignedExpression.textChatSpeaking,
            recordAssistantForTurns:
                '抱歉，我暂时没找到应用内置音乐资源。请确认 mp3 已放在 assets/music 下并已加入资源清单。',
          );
        } else {
          await _speakText(
            '好的，正在播放内置音乐：$title',
            ttsExpression: TtsAlignedExpression.textChatSpeaking,
            recordAssistantForTurns: '好的，正在播放内置音乐：$title',
          );
        }
        return;
      }

      final tts = _ttsService;
      final supportsStream = tts.supportsInputStreaming;
      // command 场景模型输出整段 JSON，流式会把未闭合 JSON 送进 TTS，故强制整段模式
      final hasVisualVa = _hasAvailableVaImage(vaResult);
      final useStream = supportsStream &&
          sceneIntent != IntentType.command &&
          !(sceneIntent == IntentType.comfort && hasVisualVa);
      final deviceCtxMode = sceneIntent == IntentType.command
          ? DeviceContextFetchMode.none
          : sceneIntent == IntentType.apiCall
              ? DeviceContextFetchMode.cachedAmbient
              : DeviceContextService.fetchModeForQuery(userInput);
      TextQAResult result;
      if (useStream) {
        final qaSw = Stopwatch()..start();
        var firstEnqueueLogged = false;
        var firstPlayLogged = false;
        final innerPlayback = _playbackStartedVisualCallback(
          TtsAlignedExpression.textChatSpeaking,
          null,
        );

        if (_isInConversationMode) {
          _isTtsPlaying = true;
          notifyListeners();
        }
        try {
          await prepareSherpaBargeInForConversationTts();
          await LocalMusicService.instance.pauseForTts();

          final swTtsInit = Stopwatch()..start();
          await tts.startInputStream(
            onPlaybackStarted: () {
              if (!firstPlayLogged) {
                print(
                  '⏱️ [ConvStage][TTS·首帧出声] 距本问答开始 '
                  '${qaSw.elapsedMilliseconds}ms',
                );
                firstPlayLogged = true;
              }
              innerPlayback?.call();
            },
          );
          swTtsInit.stop();
          print(
            '⏱️ [ConvStage][TTS·会话初始化] startInputStream '
            '${swTtsInit.elapsedMilliseconds}ms',
          );

          final pending = StringBuffer();
          final swLlm = Stopwatch()..start();
          result = await _textQAModule.handleTextQAStream(
            userInput,
            [],
            sceneIntent: sceneIntent,
            englishTeachingScene: englishTeachingScene,
            contextPack: contextPack,
            replyLengthMode: _replyLengthModeHint(),
            deviceContextMode: deviceCtxMode,
            onDelta: (delta) async {
              pending.write(delta);
              final chunks = _extractReadySpeechChunks(pending);
              for (final c in chunks) {
                if (!firstEnqueueLogged) {
                  print(
                    '⏱️ [ConvStage][TTS·首次入队] 距本问答开始 '
                    '${qaSw.elapsedMilliseconds}ms 段长=${c.length}字',
                  );
                  firstEnqueueLogged = true;
                }
                unawaited(tts.pushInputText(c));
              }
            },
          );
          swLlm.stop();
          print(
            '⏱️ [ConvStage][本问答·LLM+onDelta阶段] '
            '${swLlm.elapsedMilliseconds}ms',
          );

          final swTail = Stopwatch()..start();
          final tail = pending.toString().trim();
          if (tail.isNotEmpty) {
            await tts.pushInputText(tail);
          }
          swTail.stop();
          print(
            '⏱️ [ConvStage][TTS·尾段推送] await push 尾段 '
            '${swTail.elapsedMilliseconds}ms',
          );

          final swFinish = Stopwatch()..start();
          await tts.finishInputStream();
          swFinish.stop();
          qaSw.stop();
          print(
            '⏱️ [ConvStage][TTS·收尾播完] finishInputStream '
            '${swFinish.elapsedMilliseconds}ms '
            '本问答合计=${qaSw.elapsedMilliseconds}ms',
          );
        } finally {
          if (_isInConversationMode) {
            _isTtsPlaying = false;
            notifyListeners();
          }
          await LocalMusicService.instance.resumeAfterTtsIfPaused();
        }
        // 流式播报已结束：与 [_speakText] 一致，先切聆听脸再起麦，降低「思考中」卡死感
        _isProcessingUserInput = false;
        ConversationFlowTracer.step(
          'textqa_stream_path_processing_cleared',
          'before_onTtsCompleted_and_startAsr',
        );
        _notifySpeechUi();
        if (_isInConversationMode) {
          _uiModule.onTtsCompleted();
          try {
            ConversationFlowTracer.step('textqa_stream_startAsr_try');
            await _startVoiceRecognition();
            ConversationFlowTracer.step('textqa_stream_startAsr_ok');
          } catch (e, st) {
            print("⚠️ 流式后启动语音识别失败，将重试: $e\n$st");
            await Future<void>.delayed(const Duration(milliseconds: 300));
            try {
              await _startVoiceRecognition();
              ConversationFlowTracer.step('textqa_stream_startAsr_ok_retry');
            } catch (e2, st2) {
              print("❌ 流式后语音识别二次启动仍失败: $e2\n$st2");
              ConversationFlowTracer.step('textqa_stream_startAsr_fail', '$e2');
            }
          }
          _startConversationTimeout();
        }
      } else {
        final swQa = Stopwatch()..start();
        result = await _textQAModule.handleTextQA(
          userInput,
          [],
          sceneIntent: sceneIntent,
          englishTeachingScene: englishTeachingScene,
          contextPack: contextPack,
          replyLengthMode: _replyLengthModeHint(),
          deviceContextMode: deviceCtxMode,
        );
        swQa.stop();
        print(
          '⏱️ [ConvStage][本问答·整段LLM+解析] ${swQa.elapsedMilliseconds}ms '
          '（细项见上文 [TextQA·整段]）',
        );
        final swTtsRound = Stopwatch()..start();
        final responseToSpeak = _ensureVisualVaVisible(
          result.response,
          vaResult: vaResult,
          userInput: userInput,
          sceneIntent: sceneIntent,
        );
        await _speakText(
          responseToSpeak,
          ttsExpression: sceneIntent == IntentType.command
              ? TtsAlignedExpression.actionCommandSpeaking
              : TtsAlignedExpression.textChatSpeaking,
          recordAssistantForTurns: responseToSpeak,
        );
        swTtsRound.stop();
        print(
          '⏱️ [ConvStage][本问答·speakText总墙钟] ${swTtsRound.elapsedMilliseconds}ms '
          '（含准备打断；纯 TTS 见上文 [TTS合成与播放]）',
        );
      }
      final structured = result.structured;
      final allowBluetoothActions = sceneIntent == IntentType.command;
      var chainOutcome = const BluetoothChainOutcome();
      if (allowBluetoothActions &&
          structured != null &&
          structured.bluetoothActions.isNotEmpty) {
        chainOutcome = await _actionModule.applyStructuredBluetoothActions(
          structured.bluetoothActions,
        );
      } else if (!allowBluetoothActions &&
          structured != null &&
          structured.bluetoothActions.isNotEmpty) {
        print('⚠️ 忽略非指令场景下的蓝牙动作建议，避免误触发');
      }

      if (sceneIntent == IntentType.command) {
        if (chainOutcome.skippedDisconnected) {
          await _speakText(
            '机器人未连接',
            ttsExpression: TtsAlignedExpression.textChatSpeaking,
            recordAssistantForTurns: '机器人未连接',
          );
        } else if (chainOutcome.linearInterrupted) {
          final cliff = chainOutcome.obstacleType == 0x03 ||
              chainOutcome.obstacleType == 0x04;
          final safety = cliff ? '要掉下去啦' : '马上碰撞啦';
          await _speakText(
            safety,
            ttsExpression: TtsAlignedExpression.emotionSpeaking,
            emotionUiLabel: '愤怒',
            recordAssistantForTurns: safety,
          );
        }
      }

      if (useStream && result.response.trim().isNotEmpty) {
        _pushDialogLine('小航：${result.response.trim()}');
        unawaited(_recordConversationHistoryTurn(userInput, result.response));
      }
    } catch (e) {
      print("❌ 文本问答处理失败: $e");
      await _speakText(
        "抱歉，我现在无法回答您的问题",
        ttsExpression: TtsAlignedExpression.textChatSpeaking,
        recordAssistantForTurns: "抱歉，我现在无法回答您的问题",
      );
    }
  }

  /// 处理“结束对话”意图：先生成并播报一句温暖告别，再退出连续对话模式。
  Future<void> _handleExitIntent(String userInput) async {
    print("🚪 命中退出意图，先生成告别语再退出");
    _conversationTimeoutTimer?.cancel();
    _uiModule.showThinkingAwaitingModel();

    var farewell = "希望你今天也顺顺利利，我先退出了。";
    try {
      final result = await _textQAModule.handleTextQA(
        '$userInput。请只回复一句温暖且简短的告别语，表达“希望你愉快，我先退出了”这类意思。',
        [],
        sceneIntent: IntentType.dialogue,
        contextPack: _buildContextPack(),
        replyLengthMode: '待机',
        deviceContextMode: DeviceContextFetchMode.none,
      );
      final t = result.response.trim();
      if (t.isNotEmpty) {
        farewell = t;
      }
    } catch (e) {
      print("⚠️ 退出告别语生成失败，使用默认文案: $e");
    }

    await _speakText(
      farewell,
      ttsExpression: TtsAlignedExpression.textChatSpeaking,
      recordAssistantForTurns: farewell,
      transitionToListeningAfterTts: false,
    );

    // 退出前不再重复播报固定退出语，避免二次播报
    await _exitConversationMode(speakExitLine: false);
  }

  /// 与 TTS 播放器 `PlayerState.playing` 对齐的一次性表情切换（非 none 时）。
  VoidCallback? _playbackStartedVisualCallback(
    TtsAlignedExpression expression,
    String? emotionUiLabel,
  ) {
    if (expression == TtsAlignedExpression.none) return null;
    return () {
      _uiModule.applyExpressionAlignedWithTts(
        expression,
        emotionUiLabel: emotionUiLabel,
      );
    };
  }

  /// 语音合成
  Future<void> _speakText(
    String text, {
    TtsAlignedExpression ttsExpression = TtsAlignedExpression.none,
    String? emotionUiLabel,
    String? recordAssistantForTurns,
    bool transitionToListeningAfterTts = true,
  }) async {
    if (text.isEmpty) return;

    ConversationFlowTracer.step(
      'tts_speak_enter',
      'len=${text.length} transitionListen=$transitionToListeningAfterTts '
          'inConvo=$_isInConversationMode',
    );
    _isTtsPlaying = true;
    notifyListeners();

    try {
      print("🔊 TTS播放: $text");

      // 勿用英文常用词做子串过滤（如 chat/message/content/model），否则正常英文回复会被整段跳过
      if (_shouldSkipTtsAsLikelyDebug(text)) {
        ConversationFlowTracer.step('tts_skipped_debug_snippet');
        print("⚠️ 检测到可能的调试信息，跳过播报: $text");
        return;
      }

      await prepareSherpaBargeInForConversationTts();
      await LocalMusicService.instance.pauseForTts();

      // 表情在播放器进入 playing 时切换，贴近首帧出声（与云端 TTS 行为一致）
      final ttsSw = Stopwatch()..start();
      await _ttsService.speak(
        text,
        onPlaybackStarted:
            _playbackStartedVisualCallback(ttsExpression, emotionUiLabel),
      );
      ttsSw.stop();
      print(
        '⏱️ [ConvStage][TTS合成与播放] ${ttsSw.elapsedMilliseconds}ms '
        'len=${text.length}字',
      );

      if (recordAssistantForTurns != null &&
          recordAssistantForTurns.trim().isNotEmpty) {
        _pushDialogLine('小航：${recordAssistantForTurns.trim()}');
        unawaited(
          _recordConversationHistoryTurn(
            _lastUserInput,
            recordAssistantForTurns,
          ),
        );
      }

      print("✅ TTS播放完成");
    } catch (e) {
      print("❌ TTS播放失败: $e");
    } finally {
      // 音频已结束时立即清「播报中」并切聆听脸，再拉麦克风；避免 speak() 已返回但
      // await _startVoiceRecognition() 期间 UI 仍显示播报中/说话嘴型过久，或听写未起导致 30s 超时退出。
      if (_isInConversationMode) {
        _isTtsPlaying = false;
        notifyListeners();
        if (transitionToListeningAfterTts) {
          _uiModule.onTtsCompleted();
        }
        _isProcessingUserInput = false;
        _notifySpeechUi();

        print("🎙️ TTS播放完成，启动语音识别监听");
        ConversationFlowTracer.step('tts_finally_before_startAsr');
        try {
          await _startVoiceRecognition();
          ConversationFlowTracer.step('tts_finally_after_startAsr_ok');
        } catch (e, st) {
          print("⚠️ 启动语音识别失败，300ms 后重试一次: $e\n$st");
          ConversationFlowTracer.step('tts_startAsr_fail_retry', '$e');
          await Future<void>.delayed(const Duration(milliseconds: 300));
          try {
            await _startVoiceRecognition();
            ConversationFlowTracer.step('tts_finally_after_startAsr_ok_retry');
          } catch (e2, st2) {
            print("❌ 语音识别二次启动仍失败: $e2\n$st2");
            ConversationFlowTracer.step('tts_startAsr_fail_final', '$e2');
          }
        }
        print("⏰ TTS播放完成，现在启动30秒超时计时器");
        ConversationFlowTracer.step('tts_finally_arm_timeout30');
        _startConversationTimeout();
      } else {
        _isTtsPlaying = false;
        notifyListeners();
        if (transitionToListeningAfterTts) {
          _uiModule.onTtsCompleted();
        }
      }

      await LocalMusicService.instance.resumeAfterTtsIfPaused();
      notifyListeners();
    }
  }

  /// 启动语音识别
  Future<void> _startVoiceRecognition() async {
    try {
      print("🎙️ 启动语音识别监听");
      ConversationFlowTracer.step('_startVoiceRecognition_delegate');

      if (_speechNotifier != null &&
          _speechNotifier.startVoiceRecognition != null) {
        // 调用SpeechNotifierSimplified的语音识别启动方法
        await _speechNotifier.startVoiceRecognition();
        print("✅ 已通知语音通知器启动语音识别");
      } else {
        print("⚠️ 语音通知器引用未设置，无法启动语音识别");
      }
    } catch (e) {
      print("❌ 启动语音识别失败: $e");
    }
  }

  /// 停止语音识别
  Future<void> _stopVoiceRecognition({bool resumeSherpaKws = true}) async {
    try {
      ConversationFlowTracer.orphan(
        '_stopVoiceRecognition resumeSherpaKws=$resumeSherpaKws',
      );
      if (_speechNotifier != null &&
          _speechNotifier.stopVoiceRecognition != null) {
        await _speechNotifier.stopVoiceRecognition(
            resumeSherpaKws: resumeSherpaKws);
        print("🔇 语音识别已停止");
      }
    } catch (e) {
      print("❌ 停止语音识别失败: $e");
    }
  }

  Future<void> _resumeSherpaAfterConversationExit() async {
    try {
      if (_speechNotifier != null &&
          _speechNotifier.resumeSherpaWakeListeningAfterExit != null) {
        await _speechNotifier.resumeSherpaWakeListeningAfterExit();
      }
    } catch (e) {
      print("❌ 恢复唤醒监听失败: $e");
    }
  }

  /// 用户正在说话（含声纹未通过）：暂停 30 秒空闲超时。
  void pauseConversationTimeoutForUserSpeech() {
    if (!_isInConversationMode) return;
    if (_conversationTimeoutTimer == null) return;
    _conversationTimeoutTimer!.cancel();
    _conversationTimeoutTimer = null;
    ConversationFlowTracer.step('timeout30_paused_user_speaking');
    print('⏸️ 检测到用户说话，暂停30秒超时');
  }

  /// 回到空闲聆听：重新启动超时（TTS/处理中时不启动）。
  void resumeIdleConversationTimeout() {
    _startConversationTimeout();
  }

  /// 启动30秒超时计时器
  void _startConversationTimeout() {
    _conversationTimeoutTimer?.cancel();

    // 修复：确保只在TTS播放完成且在对话模式中才启动计时器
    if (_isTtsPlaying) {
      ConversationFlowTracer.orphan(
        'timeout30_arm_skipped ttsStillPlaying=true',
      );
      print("🔊 TTS播放中，延迟启动超时计时器");
      return;
    }

    if (!_isInConversationMode) {
      ConversationFlowTracer.orphan(
        'timeout30_arm_skipped notInConversationMode',
      );
      print("⚠️ 不在连续对话模式，不启动超时计时器");
      return;
    }

    _conversationTimeoutTimer = Timer(_conversationTimeout, () {
      ConversationFlowTracer.orphan(
        'timeout30_FIRED -> _exitConversationMode',
      );
      print("⏰ 连续对话30秒超时，自动退出");
      _exitConversationMode().catchError((Object e, StackTrace st) {
        print("❌ 超时退出对话异常: $e\n$st");
      });
    });

    ConversationFlowTracer.orphan('timeout30_timer_ARMED');
    print("⏰ 30秒超时计时器已启动（TTS播放完成后）");
  }

  /// 检查是否为退出指令
  bool _isExitCommand(String text) {
    final exitCommands = [
      '就这样吧',
      '先这样吧',
      '就到这吧',
      '结束',
      '结束吧',
      '退出',
      '退出吧',
      '我要休息了',
      '再见',
      '拜拜',
      '停止对话',
      '结束对话',
      '不说了',
      '睡觉',
      '休息',
      '滚',
      '滚蛋',
      '闭嘴',
    ];

    final lowerText = text.toLowerCase();
    return exitCommands.any((cmd) => lowerText.contains(cmd));
  }

  /// 获取对话上下文（供情绪/图像等模块注入）
  String _getConversationContext() {
    if (_dialogTurnLines.isEmpty) return '';
    return _dialogTurnLines.join('\n');
  }

  void _pushDialogLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return;
    _dialogTurnLines.add(t);
    while (_dialogTurnLines.length > 8) {
      _dialogTurnLines.removeAt(0);
    }
  }

  Future<void> _recordConversationHistoryTurn(
    String userText,
    String assistantText,
  ) async {
    final user = userText.trim();
    final assistant = assistantText.trim();
    if (user.isEmpty || assistant.isEmpty) return;
    if (user == assistant) return;
    final activeUser = await AppDatabase.instance.getActiveUser();
    final userId = activeUser?.id.trim() ?? '';
    if (userId.isEmpty) return;
    await AppDatabase.instance.addConversationHistoryTurn(
      userId,
      ConversationHistoryTurn(
        userText: user,
        assistantText: assistant,
        createdAt: DateTime.now(),
      ),
    );
  }

  /// 仅拦截明显调试串；英文里常出现 chat/model/message 等词，不可做简单 [String.contains]。
  bool _shouldSkipTtsAsLikelyDebug(String text) {
    if (text.contains('utterance_')) return true;
    if (text.contains('🎤') || text.contains('✅') || text.contains('❌')) {
      return true;
    }
    if (RegExp(r'\bTTS\b').hasMatch(text)) return true;
    final t = text.trim();
    if (RegExp(r'^\d{12,}$').hasMatch(t)) return true;
    final tl = text.trimLeft();
    if (tl.startsWith('{') &&
        tl.contains('"choices"') &&
        (tl.contains('"usage"') || tl.contains('"finish_reason"'))) {
      return true;
    }
    return false;
  }

  /// 单字汉字且不在白名单：多为环境噪声误识别（如「饭」）；白名单保留应答语气词供意图区分。
  static const Set<String> _asrSingleHanKeep = {
    '嗯',
    '唔',
    '呣',
    '哼',
    '哦',
    '噢',
    '喔',
    '啊',
    '呃',
    '欸',
    '诶',
    '唉',
    '嘿',
    '哟',
    '嗨',
    '对',
    '好',
    '行',
    '是',
    '可',
    '要',
    '成',
  };

  /// 仅一个 CJK 汉字且不在 [_asrSingleHanKeep] 时视为 ASR 垃圾，在 [_isLikelyInvalidInput] 中过滤。
  static bool isSingleHanAsrNoise(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    final it = t.runes.iterator;
    if (!it.moveNext()) return false;
    final r = it.current;
    if (it.moveNext()) return false;
    if (r < 0x4e00 || r > 0x9fff) return false;
    return !_asrSingleHanKeep.contains(String.fromCharCode(r));
  }

  bool _isLikelyInvalidInput(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return true;
    if (t.length <= 1 && RegExp(r'^[^\u4e00-\u9fff\w]$').hasMatch(t)) {
      return true;
    }
    if (RegExp(r'^[\s\.,;:!?，。！？、…]+$').hasMatch(t)) return true;
    return false;
  }

  Future<bool> _tryHandleStockVaDemoReply(String userInput) async {
    if (!_isStockVaDemoQuestion(userInput)) return false;
    _stockVaDemoQuestionCount += 1;
    final reply = _stockVaDemoQuestionCount == 1
        ? _stockVaDemoFirstReply
        : _stockVaDemoSecondReply;
    ConversationFlowTracer.step(
      'stock_va_demo_fixed_reply',
      'count=$_stockVaDemoQuestionCount',
    );
    print('🎬 [VA Demo] 股票问题第 $_stockVaDemoQuestionCount 次，按录制模板回复');
    final isFirstStockVaDemoReply = _stockVaDemoQuestionCount == 1;
    await _speakText(
      reply,
      ttsExpression: TtsAlignedExpression.emotionSpeaking,
      emotionUiLabel: isFirstStockVaDemoReply ? '悲伤' : '坚定',
      recordAssistantForTurns: reply,
    );
    _textQAModule.recordRouterDirectTurn(userInput, reply);
    return true;
  }

  bool _isStockVaDemoQuestion(String raw) {
    final t = raw.replaceAll(RegExp(r'\s+'), '');
    if (t.isEmpty) return false;
    return t.contains('关注') &&
        t.contains('股票') &&
        t.contains('今天') &&
        t.contains('跌') &&
        (t.contains('怎么看') || t.contains('怎么想') || t.contains('看法'));
  }

  ConversationContextPack _buildContextPack({
    Map<String, dynamic>? vaResult,
  }) {
    final fusionRaw = vaResult?['fusion_summary'];
    final fusionSummary = _summarizeVaForCompanion(fusionRaw);
    final vaValuesSummary = _summarizeVaValuesForCompanion(fusionRaw);
    final vaModalitySummary = _summarizeVaModalitiesForCompanion(vaResult);
    final vaTagsSummary = _summarizeVaTagsForCompanion(fusionRaw);
    final vaPromptHint = _buildVaPromptHintForCompanion(
      fusionRaw,
      vaResult: vaResult,
    );
    final combinedVaValues = [
      if (vaValuesSummary != null && vaValuesSummary.isNotEmpty)
        vaValuesSummary,
      if (vaModalitySummary != null && vaModalitySummary.isNotEmpty)
        vaModalitySummary,
    ].join(' ');
    return ConversationContextPack(
      recentTurnLines: List<String>.from(_dialogTurnLines),
      userEmotionFromVa:
          fusionSummary == null || fusionSummary.isEmpty ? null : fusionSummary,
      vaValuesSummary: combinedVaValues.isEmpty ? null : combinedVaValues,
      vaTagsSummary:
          vaTagsSummary == null || vaTagsSummary.isEmpty ? null : vaTagsSummary,
      vaPromptHint:
          vaPromptHint == null || vaPromptHint.isEmpty ? null : vaPromptHint,
      deviceStateLine: '基座电量与传感器详情：待硬件上报',
      environmentSummary: null,
      idleSinceDescription: _describeIdleSince(),
    );
  }

  Map<String, dynamic>? _asStringDynamicMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map(
        (key, dynamic val) => MapEntry(key.toString(), val),
      );
    }
    return null;
  }

  double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  bool _hasAvailableVaImage(Map<String, dynamic>? vaResult) {
    final image = _asStringDynamicMap(vaResult?['image_summary']);
    return image?['available'] == true;
  }

  String _ensureVisualVaVisible(
    String rawReply, {
    required Map<String, dynamic>? vaResult,
    required String userInput,
    required IntentType sceneIntent,
  }) {
    final reply = rawReply.trim();
    if (reply.isEmpty || sceneIntent != IntentType.comfort) return rawReply;

    final image = _asStringDynamicMap(vaResult?['image_summary']);
    if (image == null || image['available'] != true) return rawReply;

    final firstSentence = reply.split(RegExp(r'(?<=[。！？!?])')).first.trim();
    final visualAlreadyVisible = RegExp(
      r'看起来|看上去|脸上|表情|笑着|带笑|皱眉|绷着|不太轻松|有点累',
    ).hasMatch(firstSentence);
    if (visualAlreadyVisible) return rawReply;

    final opener = _buildVisualVaReplyOpener(image, userInput);
    if (opener == null || opener.isEmpty) return rawReply;

    final revised = '$opener$reply';
    print('🧩 [Companion][VA_VISUAL_REWRITE] "$reply" -> "$revised"');
    return revised;
  }

  String? _buildVisualVaReplyOpener(
    Map<String, dynamic> image,
    String userInput,
  ) {
    final valence = _asDouble(image['valence']);
    final arousal = _asDouble(image['arousal']);
    final label = image['latest_emotion_label']?.toString().trim();
    final normalizedLabel = (label ?? '').toLowerCase();
    final hasNegativeText =
        RegExp(r'烦|难过|不开心|累|崩溃|焦虑|生气|难受').hasMatch(userInput);

    final smileLabel = _isVaPositiveVisualLabel(normalizedLabel);
    final frownLabel = _isVaNegativeVisualLabel(normalizedLabel);
    final positiveVisual = smileLabel || (valence ?? 0) >= 0.16;
    final negativeVisual = frownLabel ||
        (valence ?? 0) <= -0.16 ||
        ((valence ?? 0) <= -0.08 && (arousal ?? 0) >= 0.45);
    final highVisualArousal = (arousal ?? 0) >= 0.25;
    final lowVisualArousal = (arousal ?? 0) <= -0.2;

    if (positiveVisual && hasNegativeText) {
      return '你是笑着说这个的欸，像是在逗我，也像有点苦笑。';
    }
    if (positiveVisual) {
      return '你看起来还带着点笑意。';
    }
    if (negativeVisual && highVisualArousal) {
      return '你看起来也有点绷着，不太轻松。';
    }
    if (negativeVisual && lowVisualArousal) {
      return '你看起来也有点累，没什么劲。';
    }
    if (negativeVisual) {
      return '你看起来不太轻松。';
    }
    if (highVisualArousal) {
      return '你看起来也有点绷着。';
    }
    if (lowVisualArousal) {
      return '你看起来有点累。';
    }
    if (hasNegativeText) {
      return '你看起来还在撑着。';
    }
    return null;
  }

  String? _summarizeVaForCompanion(Object? fusionRaw) {
    final fusion = _asStringDynamicMap(fusionRaw);
    if (fusion == null || fusion.isEmpty) return null;
    final emotion = (fusion['emotion'] ?? '').toString().trim();
    final valence = _asDouble(fusion['valence']);
    final arousal = _asDouble(fusion['arousal']);
    final dominance = _asDouble(fusion['dominance']);
    final tags = (fusion['va_tags'] is List)
        ? List<String>.from(
            (fusion['va_tags'] as List).map((e) => e.toString()))
        : const <String>[];

    final state = _describeVaState(emotion, valence, arousal, tags);
    final tone = _describeVaTone(valence, arousal, tags);
    final control = _describeVaControl(dominance, tags);
    return '本轮状态判断：$state；整体语气：$tone；外在撑着程度：$control。';
  }

  String? _summarizeVaValuesForCompanion(Object? fusionRaw) {
    final fusion = _asStringDynamicMap(fusionRaw);
    if (fusion == null || fusion.isEmpty) return null;
    final valence = _asDouble(fusion['valence']);
    final arousal = _asDouble(fusion['arousal']);
    final dominance = _asDouble(fusion['dominance']);
    if (valence == null && arousal == null && dominance == null) return null;

    final valenceText = valence == null
        ? '未知'
        : (valence <= -0.25 ? '偏负向' : (valence >= 0.25 ? '偏正向' : '接近中性'));
    final arousalText = arousal == null
        ? '未知'
        : (arousal <= -0.2
            ? '偏低唤醒（更累、更慢）'
            : (arousal >= 0.25 ? '偏高唤醒（更紧、更绷）' : '中等唤醒'));
    final dominanceText = dominance == null
        ? '未知'
        : (dominance >= 0.2
            ? '偏能撑着/偏克制'
            : (dominance <= -0.2 ? '偏无力/偏没底气' : '中等'));
    return 'VA数值可解释为：情绪倾向=$valenceText；激活程度=$arousalText；掌控感=$dominanceText。';
  }

  String? _summarizeVaModalitiesForCompanion(Map<String, dynamic>? vaResult) {
    if (vaResult == null || vaResult.isEmpty) return null;
    final audio = _asStringDynamicMap(vaResult['audio_summary']);
    final image = _asStringDynamicMap(vaResult['image_summary']);
    final fusion = _asStringDynamicMap(vaResult['fusion_summary']);
    final parts = <String>[];

    final audioLine = _describeVaModalityLine(
      '语音线索',
      audio,
      includeDominance: true,
    );
    if (audioLine != null) parts.add(audioLine);

    final imageLine = _describeVaModalityLine(
      '画面线索',
      image,
      includeImageLabel: true,
    );
    if (imageLine != null) parts.add(imageLine);
    final visualCue = _describeVaVisualCue(image);
    if (visualCue != null) parts.add(visualCue);

    final contrast = _describeVaModalityContrast(audio, image, fusion);
    if (contrast != null) parts.add(contrast);

    if (parts.isEmpty) return null;
    return 'VA多模态摘要：${parts.join('；')}。';
  }

  String? _describeVaModalityLine(
    String label,
    Map<String, dynamic>? summary, {
    bool includeDominance = false,
    bool includeImageLabel = false,
  }) {
    if (summary == null || summary.isEmpty) return null;
    final available = summary['available'] == true;
    final count = (summary['count'] as num?)?.toInt();
    if (!available && (count == null || count <= 0)) {
      return '$label=暂无有效数据';
    }

    final valence = _asDouble(summary['valence']);
    final arousal = _asDouble(summary['arousal']);
    final dominance = _asDouble(summary['dominance']);
    final bits = <String>[
      '$label=${available ? '有效' : '弱可用'}',
      '情绪倾向${_describeVaValueBand(valence, kind: _VaValueKind.valence)}',
      '唤醒${_describeVaValueBand(arousal, kind: _VaValueKind.arousal)}',
    ];
    if (includeDominance && dominance != null) {
      bits.add(
          '掌控感${_describeVaValueBand(dominance, kind: _VaValueKind.dominance)}');
    }
    if (includeImageLabel) {
      final imageLabel = summary['latest_emotion_label']?.toString().trim();
      if (imageLabel != null && imageLabel.isNotEmpty) {
        bits.add('表情标签=$imageLabel');
      }
    }
    return bits.join('，');
  }

  String? _describeVaVisualCue(Map<String, dynamic>? image) {
    if (image == null || image.isEmpty || image['available'] != true) {
      return null;
    }
    final valence = _asDouble(image['valence']);
    final arousal = _asDouble(image['arousal']);
    final label = image['latest_emotion_label']?.toString().trim();
    final normalizedLabel = (label ?? '').toLowerCase();

    final smileLabel = _isVaPositiveVisualLabel(normalizedLabel);
    final frownLabel = _isVaNegativeVisualLabel(normalizedLabel);
    final positiveVisual = smileLabel || (valence ?? 0) >= 0.16;
    final negativeVisual = frownLabel ||
        (valence ?? 0) <= -0.16 ||
        ((valence ?? 0) <= -0.08 && (arousal ?? 0) >= 0.45);
    final highVisualArousal = (arousal ?? 0) >= 0.25;
    final lowVisualArousal = (arousal ?? 0) <= -0.2;

    if (positiveVisual) {
      if (highVisualArousal) {
        return '视觉状态提示=画面看起来偏轻松/带笑，而且能量不低；如果用户说烦或难过，回复要明显体现“嘴上说难受但表情有点撑着/带笑”的反差';
      }
      return '视觉状态提示=画面看起来偏轻松或带笑；如果用户说烦或难过，回复可以先轻轻点出“你是笑着说的欸，是在逗我，还是有点苦笑”';
    }
    if (negativeVisual && highVisualArousal) {
      return '视觉状态提示=画面看起来不太放松，像有点皱眉/绷着；回复要把“看起来也有点紧”体现出来，不要只说听起来';
    }
    if (negativeVisual && lowVisualArousal) {
      return '视觉状态提示=画面看起来偏低落或疲惫；回复要更轻一点，体现“看起来也有点累/没什么劲”';
    }
    if (negativeVisual) {
      return '视觉状态提示=画面看起来不太轻松；回复中要体现视觉上的低落或紧绷，不要只根据语音判断';
    }
    if (highVisualArousal) {
      return '视觉状态提示=画面激活程度偏高，可能有点紧或很专注；回复可以说“看起来也有点绷/有点顶着”';
    }
    if (lowVisualArousal) {
      return '视觉状态提示=画面能量偏低；回复可以说“看起来有点累/慢下来也没关系”';
    }
    return '视觉状态提示=画面整体偏平静；若语音或文字很烦，回复可体现“看起来还在撑着/表面还算稳”';
  }

  bool _isVaPositiveVisualLabel(String label) {
    return _vaLabelContainsAny(label, const [
      'happy',
      'happiness',
      'joy',
      'smile',
      'laugh',
      'positive',
      '高兴',
      '开心',
      '愉快',
      '微笑',
      '笑',
    ]);
  }

  bool _isVaNegativeVisualLabel(String label) {
    return _vaLabelContainsAny(label, const [
      'angry',
      'anger',
      'mad',
      'frown',
      'disgust',
      'fear',
      'sad',
      'sadness',
      'negative',
      '皱眉',
      '生气',
      '愤怒',
      '厌烦',
      '害怕',
      '悲伤',
      '难过',
      '低落',
    ]);
  }

  bool _vaLabelContainsAny(String label, List<String> needles) {
    if (label.isEmpty) return false;
    return needles.any(label.contains);
  }

  String _describeVaValueBand(double? value, {required _VaValueKind kind}) {
    if (value == null) return '未知';
    switch (kind) {
      case _VaValueKind.valence:
        if (value >= 0.25) return '偏正向';
        if (value <= -0.25) return '偏负向';
        return '接近中性';
      case _VaValueKind.arousal:
        if (value >= 0.25) return '偏高/更激动';
        if (value <= -0.2) return '偏低/更疲惫';
        return '中等';
      case _VaValueKind.dominance:
        if (value >= 0.2) return '偏能撑住';
        if (value <= -0.2) return '偏没底气';
        return '中等';
    }
  }

  String? _describeVaModalityContrast(
    Map<String, dynamic>? audio,
    Map<String, dynamic>? image,
    Map<String, dynamic>? fusion,
  ) {
    if (audio == null || image == null) return null;
    if (audio['available'] != true || image['available'] != true) return null;

    final audioValence = _asDouble(audio['valence']);
    final audioArousal = _asDouble(audio['arousal']);
    final imageValence = _asDouble(image['valence']);
    final imageArousal = _asDouble(image['arousal']);
    final imageLabel = image['latest_emotion_label']?.toString().toLowerCase();
    final fusionValence = _asDouble(fusion?['valence']);

    final imagePositiveLabel = _isVaPositiveVisualLabel(imageLabel ?? '');
    final imageNegativeLabel = _isVaNegativeVisualLabel(imageLabel ?? '');
    final imageLooksPositive = imagePositiveLabel ||
        (imageValence ?? 0) >= 0.16 ||
        imageLabel == 'happy' ||
        imageLabel == 'joy' ||
        imageLabel == 'smile';
    final imageLooksNegative = imageNegativeLabel ||
        (imageValence ?? 0) <= -0.16 ||
        ((imageValence ?? 0) <= -0.08 && (imageArousal ?? 0) >= 0.45);
    final audioSoundsNegative = (audioValence ?? 0) <= -0.16;
    final audioSoundsPositive = (audioValence ?? 0) >= 0.2;
    final overallNegative =
        audioSoundsNegative || (fusionValence ?? 0) <= -0.05;
    final overallPositive = audioSoundsPositive || (fusionValence ?? 0) >= 0.18;
    final valenceGap = (audioValence != null && imageValence != null)
        ? (audioValence - imageValence).abs()
        : 0.0;
    final arousalGap = (audioArousal != null && imageArousal != null)
        ? (audioArousal - imageArousal).abs()
        : 0.0;

    if ((imageLooksPositive && overallNegative) ||
        (imageLooksNegative && overallPositive) ||
        valenceGap >= 0.45 ||
        arousalGap >= 0.75) {
      if (imageLooksPositive &&
          (audioSoundsNegative || (fusionValence ?? 0) <= 0)) {
        return '一致性判断=语音/文本偏负向但画面偏笑或偏正向，可自然点出“你是笑着说难过/烦的，是在逗我，还是有点苦笑或硬撑呀”这类轻松确认';
      }
      if (imageLooksNegative && overallPositive) {
        return '一致性判断=语音听起来还行但画面偏低落，可自然点出“你声音像在撑着，但看起来没那么轻松”';
      }
      return '一致性判断=语音和画面线索不完全一致，回复中要轻轻点出这种反差，并用一个温和问题确认';
    }

    if (imageLooksPositive && !audioSoundsNegative) {
      return '一致性判断=画面状态相对轻松，可用略轻快的方式回应，但仍接住用户主诉';
    }
    if (imageLooksNegative || audioSoundsNegative) {
      return '一致性判断=语音和画面整体偏不轻松，优先认真接住情绪';
    }
    return null;
  }

  String? _summarizeVaTagsForCompanion(Object? fusionRaw) {
    final fusion = _asStringDynamicMap(fusionRaw);
    if (fusion == null || fusion.isEmpty) return null;
    final tags = (fusion['va_tags'] is List)
        ? List<String>.from(
            (fusion['va_tags'] as List).map((e) => e.toString()))
        : const <String>[];
    if (tags.isEmpty) return null;

    final mapped =
        tags.map(_translateVaTagToChinese).where((e) => e.isNotEmpty).toList();
    if (mapped.isEmpty) return null;
    return '可参考的状态标签：${mapped.join('、')}。';
  }

  String? _buildVaPromptHintForCompanion(
    Object? fusionRaw, {
    Map<String, dynamic>? vaResult,
  }) {
    final fusion = _asStringDynamicMap(fusionRaw);
    final visualInstruction =
        _buildVaVisualPromptInstruction(vaResult?['image_summary']);
    if (fusion == null || fusion.isEmpty) {
      if (visualInstruction == null || visualInstruction.isEmpty) return null;
      return '$visualInstruction 禁止提“看不到表情/无法看到你”，禁止机械复述标签名。';
    }
    final emotion = (fusion['emotion'] ?? '').toString().trim();
    final valence = _asDouble(fusion['valence']);
    final arousal = _asDouble(fusion['arousal']);
    final dominance = _asDouble(fusion['dominance']);
    final tags = (fusion['va_tags'] is List)
        ? List<String>.from(
            (fusion['va_tags'] as List).map((e) => e.toString()))
        : const <String>[];

    final state = _describeVaState(emotion, valence, arousal, tags);
    final advice = _buildCompanionReplyAdvice(emotion, valence, arousal, tags);
    final arousalContrast = _buildVaArousalContrastInstruction(
      valence,
      arousal,
      dominance,
      tags,
    );
    final modalityContrast = _buildVaModalityPromptInstruction(vaResult);
    final visualPart = visualInstruction == null || visualInstruction.isEmpty
        ? ''
        : '$visualInstruction ';
    return '请把用户理解为：$state。回复时先做柔和观察，再做共情安抚；$advice $arousalContrast $visualPart$modalityContrast 禁止提“看不到表情/无法看到你”，禁止机械复述标签名。';
  }

  String _describeVaState(
    String emotion,
    double? valence,
    double? arousal,
    List<String> tags,
  ) {
    final highArousal = tags.contains('high_arousal') || (arousal ?? 0) >= 0.25;
    final lowArousal = tags.contains('low_arousal') || (arousal ?? 0) <= -0.2;
    final negative = emotion == 'tense_negative' ||
        tags.contains('negative_valence') ||
        (valence ?? 0) <= -0.15;
    final positive = tags.contains('positive_valence') || (valence ?? 0) > 0.2;

    if (highArousal && negative) {
      return '烦躁感偏强，像是有点急、有点绷，心里压着事';
    }
    if (lowArousal && negative) {
      return '烦躁下面更像疲惫和低落，像是有点提不起劲';
    }
    if (positive && lowArousal) {
      return '整体比较平稳，情绪不算糟，但也偏安静';
    }
    if (highArousal) {
      return '语气/状态偏紧，像是有点被事情顶住了';
    }
    if (lowArousal) {
      return '状态偏慢偏累，需要轻声接住';
    }
    if (emotion == 'neutral' || tags.contains('neutral')) {
      return '表面比较平静，但可能有些没说出来的心事';
    }
    if (positive) {
      return '状态还算稳，没有明显低落';
    }
    return '状态总体平稳，但值得用温和方式继续确认感受';
  }

  String _describeVaTone(double? valence, double? arousal, List<String> tags) {
    if (tags.contains('high_arousal') || (arousal ?? 0) >= 0.25) {
      return '偏紧、偏急，需要先放缓';
    }
    if (tags.contains('low_arousal') || (arousal ?? 0) <= -0.2) {
      return '偏疲惫、偏慢，适合轻声接住';
    }
    if (tags.contains('positive_valence') || (valence ?? 0) >= 0.25) {
      return '还算平和';
    }
    if (tags.contains('negative_valence') || (valence ?? 0) <= -0.25) {
      return '隐约有点低落';
    }
    return '中性偏平静';
  }

  String _describeVaControl(double? dominance, List<String> tags) {
    if (tags.contains('high_dominance') || (dominance ?? 0) >= 0.2) {
      return '表面上还能撑住，但不代表真的轻松';
    }
    if (tags.contains('balanced_dominance')) {
      return '看起来还算稳';
    }
    return '可能更需要被接住';
  }

  String _buildCompanionReplyAdvice(
    String emotion,
    double? valence,
    double? arousal,
    List<String> tags,
  ) {
    final highArousal = tags.contains('high_arousal') || (arousal ?? 0) >= 0.25;
    final lowArousal = tags.contains('low_arousal') || (arousal ?? 0) <= -0.2;
    final negative = emotion == 'tense_negative' ||
        tags.contains('negative_valence') ||
        (valence ?? 0) <= -0.15;

    if (highArousal && negative) {
      return '更适合先点出“有点急/有点绷/烦躁顶上来”，再用短句帮用户降速；';
    }
    if (lowArousal && negative) {
      return '更适合先点出“烦下面有点累/提不起劲”，再允许休息，给很轻的照顾建议；';
    }
    if (highArousal) {
      return '更适合先说“听起来有点绷/节奏有点急”，再帮助放缓，不要输出建议清单；';
    }
    if (lowArousal) {
      return '更适合轻声接住疲惫感，少追问，少催促；';
    }
    if (emotion == 'neutral' || tags.contains('neutral')) {
      return '更适合用“表面还算平静，但像是有点心事/有点在撑着”这类保守观察，不要夸大；';
    }
    if ((valence ?? 0) > 0.2 && (arousal ?? 0) < 0.2) {
      return '更适合说状态总体还稳，但仍认真接住用户主诉，不要只报喜；';
    }
    return '更适合先观察、再陪伴、最后轻轻追问，不要一上来就给很多建议；';
  }

  String _buildVaArousalContrastInstruction(
    double? valence,
    double? arousal,
    double? dominance,
    List<String> tags,
  ) {
    final highArousal = tags.contains('high_arousal') || (arousal ?? 0) >= 0.25;
    final lowArousal = tags.contains('low_arousal') || (arousal ?? 0) <= -0.2;
    final negative =
        tags.contains('negative_valence') || (valence ?? 0) <= -0.15;
    final lowDominance =
        tags.contains('low_dominance') || (dominance ?? 0) <= -0.2;

    if (highArousal && negative) {
      return '本轮必须体现“高唤醒烦躁”和普通烦的区别：第一句用“听起来有点急/绷/烦躁顶上来”一类自然观察，句子短一点，先降速，不要立刻讲大道理。';
    }
    if (lowArousal && negative) {
      return '本轮必须体现“低唤醒疲惫”和普通烦的区别：第一句用“听起来烦下面还有点累/没劲”一类自然观察，语气更轻，不要催用户振作。';
    }
    if (highArousal) {
      return '本轮要明显体现高唤醒：回复节奏更短、更稳，先帮助用户慢下来。';
    }
    if (lowArousal || lowDominance) {
      return '本轮要明显体现低能量/低掌控感：回复更轻、更少压迫，先允许用户不用马上解决。';
    }
    return '若用户文本表达了烦躁，即使 VA 较中性，也要在第一句承认烦躁感，再用“表面还算稳/可能有点在撑着”作保守观察。';
  }

  String _buildVaModalityPromptInstruction(Map<String, dynamic>? vaResult) {
    final audio = _asStringDynamicMap(vaResult?['audio_summary']);
    final image = _asStringDynamicMap(vaResult?['image_summary']);
    final contrast = _describeVaModalityContrast(
      audio,
      image,
      _asStringDynamicMap(vaResult?['fusion_summary']),
    );
    if (contrast == null || contrast.isEmpty) {
      return '若语音与画面都可用，回复时同时参考两者；同一句“我好烦”在笑着说和皱眉说时，开头必须不一样，不要只看语音。';
    }
    return '多模态反差很重要：$contrast。若用户文字情绪和画面表情相反，第一句要自然点出反差，可以带一点轻松感，但不要嘲笑用户。';
  }

  String? _buildVaVisualPromptInstruction(Object? imageRaw) {
    final image = _asStringDynamicMap(imageRaw);
    final cue = _describeVaVisualCue(image);
    if (cue == null || cue.isEmpty) return null;
    return '视觉 VA 必须进入回复：$cue。若用户问心情或表达烦/难过，第一句必须先体现画面状态，再补语音状态；画面偏笑就点出“笑着说/有点苦笑”，画面偏皱眉或紧绷就点出“看起来也有点绷/不太轻松”。禁止只用“听起来”开头。';
  }

  String _translateVaTagToChinese(String tag) {
    switch (tag) {
      case 'positive_valence':
        return '偏正向';
      case 'negative_valence':
        return '偏负向';
      case 'balanced_valence':
        return '情绪倾向较平衡';
      case 'high_arousal':
        return '偏高唤醒/偏紧绷';
      case 'medium_arousal':
        return '中等唤醒';
      case 'low_arousal':
        return '偏低唤醒/偏疲惫';
      case 'high_dominance':
        return '表面掌控感较强';
      case 'balanced_dominance':
        return '掌控感较平衡';
      case 'neutral':
        return '整体中性';
      case 'tense_negative':
        return '紧张偏负面';
      default:
        return tag;
    }
  }

  /// Router 用：天气/地理问法注入**仅后台缓存**（不在 Router 轮内阻塞 HTTP）；
  /// 由 Router 直接生成 dialogue_reply，时间类用本地块；普通闲聊可附带软缓存。
  Future<ConversationContextPack> _buildRouterContextPack(
      String userInput) async {
    final base = _buildContextPack();
    String? deviceBlock;
    final mode = DeviceContextService.fetchModeForQuery(userInput);
    try {
      final svc = DeviceContextService();
      switch (mode) {
        case DeviceContextFetchMode.full:
          deviceBlock = AmbientContextCache.instance.buildPromptBlock();
          break;
        case DeviceContextFetchMode.localTimeOnly:
          deviceBlock = svc.getLocalTimeContextBlock();
          break;
        case DeviceContextFetchMode.cachedAmbient:
          deviceBlock = AmbientContextCache.instance.buildPromptBlock();
          break;
        case DeviceContextFetchMode.none:
          final soft = AmbientContextCache.instance.buildPromptBlock().trim();
          if (soft.isNotEmpty) {
            deviceBlock = soft;
          }
          break;
      }
    } catch (e) {
      print('⚠️ Router 设备上下文拉取失败: $e');
    }
    return ConversationContextPack(
      recentTurnLines: base.recentTurnLines,
      userEmotionFromVa: base.userEmotionFromVa,
      vaValuesSummary: base.vaValuesSummary,
      vaTagsSummary: base.vaTagsSummary,
      vaPromptHint: base.vaPromptHint,
      deviceStateLine: base.deviceStateLine,
      environmentSummary: base.environmentSummary,
      deviceContextBlock: deviceBlock,
      idleSinceDescription: base.idleSinceDescription,
    );
  }

  String _describeIdleSince() {
    final t = _lastInteractionTime;
    if (t == null) return '';
    final sec = DateTime.now().difference(t).inSeconds;
    if (sec < 10) return '距上次交互约数秒内';
    if (sec < 60) return '距上次交互约 $sec 秒';
    if (sec < 3600) return '距上次交互约 ${sec ~/ 60} 分钟';
    return '距上次交互超过一小时';
  }

  /// 行走中 / 待机等，供 D 层长度策略
  String _replyLengthModeHint() {
    if (_actionModule.isProcessing) return '行走中';
    if (_ttsInterruptInFlight) return '打断恢复';
    return '待机';
  }

  void _recordContinuousInput(String raw) {
    final now = DateTime.now();
    final t = raw.trim();
    if (t.isEmpty) return;
    final last = _lastInputAt;
    if (last == null || now.difference(last) > _continuousInputGapReset) {
      _continuousInputWindowStart = now;
      _continuousInputCount = 1;
    } else {
      _continuousInputCount += 1;
    }
    _lastInputAt = now;
  }

  bool _shouldForceExitForContinuousInput() {
    final start = _continuousInputWindowStart;
    final last = _lastInputAt;
    if (start == null || last == null) return false;
    if (_continuousInputCount < _continuousInputCountLimit) return false;
    return last.difference(start) >= _continuousInputWindowLimit;
  }

  Future<void> _handleContinuousInputSafetyExit() async {
    print('🧯 命中连续输入保护：高频对话超过阈值，准备安全退出');
    await _speakText(
      "我先帮你停一下，避免持续收音过久。休息一下后再唤醒我，我们继续。",
      ttsExpression: TtsAlignedExpression.textChatSpeaking,
      recordAssistantForTurns: "我先帮你停一下，避免持续收音过久。休息一下后再唤醒我，我们继续。",
      transitionToListeningAfterTts: false,
    );
    await _exitConversationMode(speakExitLine: false);
  }

  void _resetContinuousInputGuard() {
    _continuousInputWindowStart = null;
    _lastInputAt = null;
    _continuousInputCount = 0;
  }

  /// 退出连续对话模式
  Future<void> _exitConversationMode({bool speakExitLine = true}) async {
    if (!_isInConversationMode) return;

    ConversationFlowTracer.orphan(
      '_exitConversationMode_BEGIN speakExitLine=$speakExitLine',
    );
    print("🚪 退出连续对话模式");
    _isInConversationMode = false;
    _isProcessingUserInput = false;
    _resetContinuousInputGuard();

    // 取消超时计时器
    _conversationTimeoutTimer?.cancel();

    // 停止用户监测
    _userDetectionModule.stopUserDetection();

    // 停止 VOSK；勿在此处恢复 sherpa（否则会与下方退出 TTS 同时占用麦克风，易 native 闪退）
    await _stopVoiceRecognition(resumeSherpaKws: false);

    // 重置UI模式
    _uiModule.setProgramMode(ProgramMode.idle);

    try {
      final n = _speechNotifier;
      if (n != null) {
        // ignore: avoid_dynamic_calls
        n.resetSpeechDisplayToWakePrompt();
        // ignore: avoid_dynamic_calls
        n.clearDuplexTtsBargeInMode();
      }
    } catch (_) {}

    // 播放退出语音（播完后再恢复唤醒）
    if (speakExitLine) {
      await _speakText("我先休息了");
    }

    // 清理状态
    _lastUserInput = "";
    // _textQAModule.resetHistory(); // 暂不实现

    // 触发退出回调，启动120秒环境监测计时器
    if (_onConversationExit != null) {
      _onConversationExit!();
      print("🔄 触发对话退出回调，启动120秒环境监测计时器");
    }

    notifyListeners();

    await _resumeSherpaAfterConversationExit();

    print("✅ 已退出连续对话模式");
  }

  /// 强制停止当前活动
  Future<void> forceStop() async {
    print("🛑 强制停止连续对话控制器");

    _conversationTimeoutTimer?.cancel();
    _userDetectionModule.stopUserDetection();
    await _stopVoiceRecognition();

    try {
      final n = _speechNotifier;
      if (n != null) {
        // ignore: avoid_dynamic_calls
        n.clearDuplexTtsBargeInMode();
      }
    } catch (_) {}

    _isProcessingUserInput = false;
    _isTtsPlaying = false;

    notifyListeners();
  }

  // === 环境监测公共接口 ===

  /// 启动环境监测
  void startEnvironmentMonitoring() {
    if (!DebugRuntimeFlags.enableEnvironmentMonitoring) {
      print(
        '════════ 环境监测已关闭（DebugRuntimeFlags.enableEnvironmentMonitoring=false）════════',
      );
      return;
    }
    if (!_isInConversationMode) {
      print("🌍 启动环境监测功能");
      _environModule.startEnvironmentMonitoring();
    } else {
      print("⚠️ 连续对话模式中，无法启动环境监测");
    }
  }

  /// 停止环境监测
  void stopEnvironmentMonitoring() {
    print("🛑 停止环境监测功能");
    _environModule.stopEnvironmentMonitoring();
  }

  /// 获取环境监测状态
  bool get isEnvironmentMonitoring => _environModule.isMonitoring;

  /// 获取环境监测状态描述
  String get environmentMonitorStatus => _environModule.monitorStatus;

  /// 释放资源
  Future<void> dispose() async {
    print("🗑️ 释放连续对话控制器资源");

    await forceStop();

    AmbientContextCache.instance.dispose();

    // 停止环境监测
    _environModule.stopEnvironmentMonitoring();

    await _userDetectionModule.dispose();
    await _imageModule.dispose();
    await _emotionModule.dispose();

    await _ttsService.release();

    super.dispose();
  }
}
