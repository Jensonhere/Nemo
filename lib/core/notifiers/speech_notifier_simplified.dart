import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:voicegpt/core/services/android_voip_audio_route.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';
import 'package:voicegpt/core/services/sherpa_kws_wake_service.dart';
import 'package:voicegpt/core/services/gesture_service.dart';
import 'package:voicegpt/core/modules/conversation_controller.dart';
import 'package:voicegpt/core/modules/plan_executor_controller.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/services/qwen_cloud_asr_client.dart';
import 'package:voicegpt/core/services/qwen_streaming_asr_recorder.dart';
import 'package:voicegpt/core/config/debug_runtime_flags.dart';
import 'package:voicegpt/core/debug/conversation_flow_tracer.dart';

/// 简化的语音通知器
/// 只保留核心基础功能：唤醒词检测、环境监测、手势识别基础功能
class SpeechNotifierSimplified with ChangeNotifier {
  // === 核心服务 ===
  final ConversationController _conversationController =
      ConversationController();
  final UIAnimationModule _uiModule = UIAnimationModule();
  GestureService? _gestureService;

  // === 唤醒词检测（sherpa-onnx KeywordSpotter，默认「你好小航」）===
  SherpaKwsWakeService? _sherpaKws;
  bool _wakeWordLock = false;
  bool _ttsBargeInBusy = false;
  /// Qwen 主麦「边播边听」：TTS 期间不切 Sherpa，用同一条 PCM 做能量 VAD 打断（依赖 VoIP+AEC）。
  bool _duplexTtsBargeInEnabled = false;
  /// 连续对话内 Sherpa 使用 VOICE_COMMUNICATION + VoIP 系统路由（硬件 AEC）
  bool _sherpaUseVoipMic = false;

  static const String _wakePhraseDisplay = '你好小航';

  // === 时间控制计时器 ===
  Timer? _idleTimer; // 10秒空闲计时器
  Timer? _postConversationTimer; // 退出对话后120秒计时器
  Timer? _wakeWordHealthCheck; // 唤醒词健康检查计时器

  // === 手势识别 ===
  bool _isGestureRecognitionActive = false;
  bool _isInGestureRecognitionMode = false;
  String _lastRecognizedGesture = "";

  // === 基础状态 ===
  String _speechText = "等待唤醒词...";
  bool _isWakeUpActive = false;

  // === 语音识别（优先 Qwen 云端中英 ASR，失败则 VOSK）===
  SpeechService? _speechService;
  QwenStreamingAsrRecorder? _qwenAsrRecorder;
  bool _listeningViaQwen = false;
  bool _isListening = false;
  bool _isStartingVoiceRecognition = false;
  final String _voskAssetDir = "assets/cn/vosk-model-small-cn-0.22/";

  static void _logAsrEngineSelection(String engineLabel) {
    const bar =
        '══════════════════════════════════════════════════════════════';
    // ignore: avoid_print
    print(bar);
    // ignore: avoid_print
    print('🎤🎤🎤 当前语音识别引擎: $engineLabel 🎤🎤🎤');
    // ignore: avoid_print
    print(bar);
  }

  /// Getters
  bool get isInConversationMode => _conversationController.isInConversationMode;
  bool get isProcessingUserInput =>
      _conversationController.isProcessingUserInput;
  bool get isTtsPlaying => _conversationController.isTtsPlaying;
  bool get isWakeUpActive => _isWakeUpActive;
  bool get isListening => _isListening;
  /// 连续对话里 TTS 结束后拉起主 ASR 的短窗口：此时 isListening 仍为 false，但不应显示「思考中/已暂停」。
  bool get isStartingVoiceRecognition => _isStartingVoiceRecognition;
  bool get isReadyToSend => false;

  /// 多人对话：按住说话模式（右上角开关）。开启且已在连续对话中时，关闭连续聆听与 TTS 可打断。
  bool _multiPersonPushToTalkMode = false;
  bool _pttRecordingActive = false;
  /// 手指是否在按住 PTT 区域（与是否已真正开麦区分，避免「点一下异步晚到」卡在录音态）。
  bool _pttFingerPressed = false;
  /// 每次按下 / 抬起递增，用于取消未到阈值的「假按下」与在途异步开麦。
  int _pttHoldGeneration = 0;

  bool get isMultiPersonPushToTalkMode => _multiPersonPushToTalkMode;
  bool get isPttRecordingHold => _pttRecordingActive;
  bool get isPttFingerPressed => _pttFingerPressed;

  /// 供 [ConversationController]：此模式下不自动 `startVoiceRecognition`。
  bool get skipAutoVoiceRecognitionInConversation =>
      _multiPersonPushToTalkMode && _conversationController.isInConversationMode;

  bool get isEnvironmentMonitoring =>
      _conversationController.isEnvironmentMonitoring;
  bool get isGestureRecognitionActive => _isGestureRecognitionActive;
  bool get isInGestureRecognitionMode => _isInGestureRecognitionMode;
  String get getTextSpeech => _speechText;
  String get monitorStatus => _conversationController.environmentMonitorStatus;
  String get lastRecognizedGesture => _lastRecognizedGesture;
  bool get forceEnglishTeachingMode =>
      _conversationController.forceEnglishTeachingMode;
  bool get isComplexTaskExecuting =>
      _conversationController.isComplexTaskExecuting;
  String get lastRouterDecision =>
      _conversationController.lastRouterDecision;
  String get lastPlannerPlanDisplay =>
      _conversationController.lastPlannerPlanDisplay;
  PlanExecutionState get planExecutionState =>
      _conversationController.planExecutionState;
  int get planTotalSteps => _conversationController.planTotalSteps;
  int get planCurrentStep => _conversationController.planCurrentStep;
  String get planLastError => _conversationController.planLastError;

  /// 初始化
  Future<void> initialize() async {
    print("🎤 初始化简化版语音通知器");

    bool wakeWordSuccess = false;

    try {
      // 🔴 优先初始化唤醒词检测（必须最先启动）
      print("🎤 第一步：启动唤醒词检测");
      await _initializeSherpaKws();
      wakeWordSuccess = true;
      print("✅ 唤醒词检测已启动");
    } catch (e) {
      wakeWordSuccess = false;
      print("⛔ 唤醒词初始化失败: $e");
      print("   请确认 assets/sherpa_kws/ 下已放入 sherpa-onnx KWS 模型文件（见 SherpaKwsWakeService 注释）");
    }

    try {
      // 初始化UI动画模块
      print("🎨 第二步：初始化UI动画模块");
      _uiModule.initialize();

      // 初始化连续对话控制器
      print("🎮 第三步：初始化连续对话控制器");
      await _conversationController.initialize();

      // 设置语音通知器引用给连续对话控制器
      _conversationController.setSpeechNotifier(this);

      // 设置对话退出回调
      _conversationController.setConversationExitCallback(() {
        _startPostConversationTimer();
      });

      // 只有唤醒词成功时才启动时间控制
      if (wakeWordSuccess) {
        // 启动10秒空闲监测
        print("⏰ 第四步：启动10秒空闲监测");
        _startIdleTimer();

        // 启动唤醒词健康检查（每5秒检查一次）
        print("💓 第五步：启动唤醒词健康检查");
        _startWakeWordHealthCheck();

        print("✅ 简化版语音通知器初始化完成（唤醒词正常）");
      } else {
        print("⚠️ 简化版语音通知器初始化完成（唤醒词功能受限）");
        print("💡 应用可以使用，但无法通过语音唤醒");
      }
    } catch (e) {
      print("❌ 其他模块初始化失败: $e");
    }
  }

  /// 设置蓝牙服务
  void setBluetoothService(MyBluetoothService bluetoothService) {
    _conversationController.setBluetoothService(bluetoothService);
  }

  void setForceEnglishTeachingMode(bool enabled) {
    _conversationController.setForceEnglishTeachingMode(enabled);
    notifyListeners();
  }

  /// 右上角「多人对话」开关：开启后仅能通过底部按住说话发语音，TTS 期间不可打断，播完不再自动聆听。
  Future<void> setMultiPersonPushToTalkMode(bool enabled) async {
    if (_multiPersonPushToTalkMode == enabled) return;
    if (!enabled) {
      _pttHoldGeneration++;
      _pttFingerPressed = false;
      if (_pttRecordingActive) {
        try {
          await _qwenAsrRecorder?.stopWithoutSubmit();
        } catch (_) {}
        _qwenAsrRecorder = null;
        _listeningViaQwen = false;
        _pttRecordingActive = false;
        _isListening = false;
      }
    }
    _multiPersonPushToTalkMode = enabled;
    if (enabled) {
      _duplexTtsBargeInEnabled = false;
      if (_conversationController.isInConversationMode) {
        try {
          await stopVoiceRecognition(resumeSherpaKws: false);
        } catch (_) {}
      }
    } else if (_conversationController.isInConversationMode) {
      try {
        await startVoiceRecognition();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 按住超过该时长才开麦，避免「点一下」误进录音；与微信发语音类似。
  static const Duration _pttHoldBeforeRecord = Duration(milliseconds: 140);

  /// 底部按住说话：按下后需持续按住 [_pttHoldBeforeRecord] 才真正开麦。
  Future<void> multiPersonPttTouchDown() async {
    if (!_multiPersonPushToTalkMode ||
        !_conversationController.isInConversationMode) {
      return;
    }
    if (_pttRecordingActive) return;
    // 流式/整段问答期间 isProcessingUserInput 常为 true，但播报中必须允许按住打断 TTS。
    if (_conversationController.isProcessingUserInput &&
        !_conversationController.isTtsPlaying) {
      return;
    }

    _pttFingerPressed = true;
    notifyListeners();

    final arm = ++_pttHoldGeneration;
    try {
      await Future<void>.delayed(_pttHoldBeforeRecord);
      if (arm != _pttHoldGeneration) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }
      if (!_multiPersonPushToTalkMode ||
          !_conversationController.isInConversationMode) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }
      if (_conversationController.isProcessingUserInput &&
          !_conversationController.isTtsPlaying) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }

      ConversationFlowTracer.asr('ptt_hold_threshold_met');
      if (_conversationController.isTtsPlaying) {
        ConversationFlowTracer.asr('ptt_interrupt_tts_for_hold');
        await _conversationController.interruptConversationTtsFromKws(
          ConversationController.kTtsInterruptKeywordMultiPersonPtt,
        );
        if (arm != _pttHoldGeneration) {
          _pttFingerPressed = false;
          notifyListeners();
          return;
        }
      }

      if (_isListening) await stopVoiceRecognition(resumeSherpaKws: false);
      if (arm != _pttHoldGeneration) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }

      _isStartingVoiceRecognition = true;
      final qwenClient = QwenCloudAsrClient();
      final qwenUp = await qwenClient.healthz();
      if (arm != _pttHoldGeneration) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }
      if (!qwenUp) {
        print('⚠️ [PTT] Qwen ASR 不可达，无法按住说话');
        _speechText = '语音服务不可用';
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }
      _sherpaKws?.setTtsBargeInVadEnabled(false);
      await _sherpaKws?.pause();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (arm != _pttHoldGeneration) {
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }

      _qwenAsrRecorder = QwenStreamingAsrRecorder(
        client: qwenClient,
        onPartialText: (String t) {
          _speechText = t;
          notifyListeners();
        },
        onUtteranceFinal: (String t) {
          final s = t.trim();
          ConversationFlowTracer.asr(
            'ptt_onUtteranceFinal len=${t.length} empty=${s.isEmpty}',
          );
          _pttRecordingActive = false;
          _pttFingerPressed = false;
          _qwenAsrRecorder = null;
          _listeningViaQwen = false;
          _isListening = false;
          _duplexTtsBargeInEnabled = false;
          notifyListeners();
          if (s.isNotEmpty) {
            unawaited(_processUserInput(s));
          } else if (!_multiPersonPushToTalkMode) {
            _scheduleRestartAsrIfConversationIdle();
          }
        },
        androidVoipEchoCapture: _sherpaUseVoipMic,
        isTtsPlaying: () => false,
        onSpeechDuringTtsBargeIn: null,
        silenceAutoFinalize: false,
        maxListenMsOverride: 180000,
      );
      await _qwenAsrRecorder!.start();
      if (arm != _pttHoldGeneration) {
        try {
          await _qwenAsrRecorder?.stopWithoutSubmit();
        } catch (_) {}
        _qwenAsrRecorder = null;
        _listeningViaQwen = false;
        _isListening = false;
        _pttFingerPressed = false;
        notifyListeners();
        return;
      }
      _listeningViaQwen = true;
      _isListening = true;
      _pttRecordingActive = true;
      _duplexTtsBargeInEnabled = false;
      _uiModule.showConversationListeningFace();
      notifyListeners();
      print('✅ [PTT] 已开始录音');
    } catch (e, st) {
      print('❌ [PTT] 启动录音失败: $e\n$st');
      _pttRecordingActive = false;
      _qwenAsrRecorder = null;
      _listeningViaQwen = false;
      _isListening = false;
      _pttFingerPressed = false;
      notifyListeners();
    } finally {
      _isStartingVoiceRecognition = false;
    }
  }

  /// 底部按住说话：松手定稿并送大模型；若在「按住阈值」内松开则取消开麦。
  Future<void> multiPersonPttTouchUp() async {
    if (!_pttFingerPressed && !_pttRecordingActive) {
      return;
    }
    _pttHoldGeneration++;
    final wasRecording = _pttRecordingActive;
    _pttFingerPressed = false;
    notifyListeners();

    if (!wasRecording) {
      ConversationFlowTracer.asr('ptt_touch_up_before_record_cancel');
      return;
    }
    ConversationFlowTracer.asr('ptt_touch_up_finalize');
    try {
      await _qwenAsrRecorder?.finalizeUtteranceForPushToTalk();
    } catch (e, st) {
      print('❌ [PTT] 定稿失败: $e\n$st');
      try {
        await _qwenAsrRecorder?.stopWithoutSubmit();
      } catch (_) {}
      _pttRecordingActive = false;
      _qwenAsrRecorder = null;
      _listeningViaQwen = false;
      _isListening = false;
      notifyListeners();
    }
  }

  /// 设置界面动画回调
  void setInterfaceServiceCallback(Function(String) callback) {
    _uiModule.initialize(animationCallback: callback);
  }

  /// 初始化手势服务
  void initializeGestureService(BuildContext context) {
    _gestureService = GestureService(context);
    print("✅ 手势服务已初始化");
  }

  /// 初始化 sherpa-onnx 唤醒词
  Future<void> _initializeSherpaKws() async {
    try {
      print("🔑 初始化 sherpa-onnx 唤醒（你好小航）...");
      await _sherpaKws?.stop();
      _sherpaKws = SherpaKwsWakeService(
        onKeyword: _onSherpaKeyword,
        onSpeechBargeIn: _onSherpaSpeechOnlyBargeIn,
      );
      final ok = await _sherpaKws!.init();
      if (!ok) {
        _isWakeUpActive = false;
        notifyListeners();
        throw StateError('sherpa KWS 模型未就绪或文件缺失');
      }
      _sherpaKws!.setAndroidVoipEchoCapture(_sherpaUseVoipMic);
      print(
          '🎚️ [VoipRoute] sherpa init 后 setAndroidVoipEchoCapture($_sherpaUseVoipMic)');
      final micOk = await _sherpaKws!.start();
      if (!micOk) {
        _isWakeUpActive = false;
        notifyListeners();
        throw StateError('无法开启麦克风用于唤醒词');
      }
      _isWakeUpActive = true;
      print("✅ 唤醒词检测已启动");
      notifyListeners();
    } catch (e) {
      _isWakeUpActive = false;
      _sherpaKws = null;
      print("❌ 初始化唤醒词检测失败: $e");
      notifyListeners();
      rethrow;
    }
  }

  /// Sherpa KWS：待机仅「你好小航」进对话；对话内 TTS 期间命中则打断 TTS。
  void _onSherpaKeyword(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;

    if (_conversationController.isInConversationMode &&
        _conversationController.isTtsPlaying) {
      if (_multiPersonPushToTalkMode) {
        print('🎧 [KWS] 多人按住说话模式：TTS 期间忽略唤醒/关键词打断');
        return;
      }
      print(
          '🎧 [KWS] 对话内 TTS 命中: $k (voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled} sherpaVoip=$_sherpaUseVoipMic)');
      unawaited(_handleTtsBargeInKeyword(k));
      return;
    }

    if (!_conversationController.isInConversationMode) {
      if (!_isWakePhrase(k)) {
        print('🎧 [KWS] 待机忽略非唤醒词: $k');
        return;
      }
    } else {
      print('⚠️ [KWS] 对话中非 TTS 阶段触发，忽略: $k');
      return;
    }

    if (_wakeWordLock) return;
    unawaited(_onWakeWordEnterConversation());
  }

  bool _isWakePhrase(String keyword) {
    final k = keyword.trim();
    if (k == _wakePhraseDisplay) return true;
    // 兼容关键词词表中可能出现的轻微后缀/别名（如“你好小航啊”）。
    return k.startsWith(_wakePhraseDisplay);
  }

  Future<void> _handleTtsBargeInKeyword(String keyword) async {
    if (_ttsBargeInBusy) return;
    _ttsBargeInBusy = true;
    try {
      await _conversationController.interruptConversationTtsFromKws(keyword);
    } finally {
      _ttsBargeInBusy = false;
    }
  }

  Future<void> _handleDuplexTtsBargeInFromVad() async {
    if (_multiPersonPushToTalkMode) return;
    if (_ttsBargeInBusy) return;
    if (!_conversationController.isInConversationMode ||
        !_conversationController.isTtsPlaying) {
      return;
    }
    _ttsBargeInBusy = true;
    try {
      _qwenAsrRecorder?.resetSegmentAfterTtsBargeIn();
      await _conversationController
          .interruptConversationTtsFromKws('duplex_pcm_vad');
    } finally {
      _ttsBargeInBusy = false;
    }
  }

  /// Sherpa 麦克风流上的能量 VAD：不限固定词条，持续人声即打断 TTS。
  void _onSherpaSpeechOnlyBargeIn() {
    if (_multiPersonPushToTalkMode) return;
    if (_conversationController.isInConversationMode &&
        _conversationController.isTtsPlaying) {
      print(
          '🎤 [VAD] 人声活动打断 (voip=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled})');
      unawaited(_handleTtsBargeInKeyword('语音活动'));
    }
  }

  /// 对话内 TTS 开始前：在 VOSK 已停后恢复 Sherpa（VoIP 模式下为 VOICE_COMMUNICATION 麦）。
  Future<void> prepareSherpaBargeInForConversationTts() async {
    if (!_conversationController.isInConversationMode) {
      print('🎧 [prepareSherpa] 非对话模式，跳过');
      return;
    }
    if (_multiPersonPushToTalkMode) {
      print('🎧 [prepareSherpa] 多人按住说话：不启用 TTS 前打断监听');
      return;
    }
    if (_duplexTtsBargeInEnabled) {
      if (!_isListening) {
        print('🎧 [prepareSherpa] 边播边听：TTS 前预启动主 ASR');
        await startVoiceRecognition();
      }
      print('🎧 [prepareSherpa] 边播边听，跳过 Sherpa resume');
      return;
    }
    if (_isListening) {
      print('🎧 [prepareSherpa] 主 ASR 仍在监听，跳过');
      return;
    }
    if (!_isWakeUpActive || _sherpaKws == null) {
      print('🎧 [prepareSherpa] sherpa 未就绪，跳过');
      return;
    }
    print(
        '🎧 [prepareSherpa] 即将 resume sherpa (voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled} sherpaVoip=$_sherpaUseVoipMic)');
    try {
      // 过大会拖慢首句 TTS；过小可能导致路由未稳就 resume，可按机型微调
      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await _sherpaKws!.resume();
      _sherpaKws!.setTtsBargeInVadEnabled(true);
      print('🎧 [prepareSherpa] resume 完成，已开启 TTS 人声 VAD');
    } catch (e, st) {
      print('⚠️ [prepareSherpa] 失败: $e\n$st');
    }
  }

  Future<void> _onWakeWordEnterConversation() async {
    print("🎤 检测到唤醒词: $_wakePhraseDisplay");
    _wakeWordLock = true;

    final wakeSw = Stopwatch()..start();

    _idleTimer?.cancel();
    _postConversationTimer?.cancel();
    await _stopEnvironmentMonitoring();
    print('⏱️ [Pipeline][Wake] 停环境监测 ${wakeSw.elapsedMilliseconds}ms');

    if (Platform.isAndroid) {
      final routeSw = Stopwatch()..start();
      print(
          '🎚️ [VoipRoute] wake→conversation: MODE_IN_COMMUNICATION + sherpa VOICE_COMMUNICATION');
      await AndroidVoipAudioRoute.instance.setConversationVoipEnabled(
        true,
        speakerphone: true,
        debugTag: 'wake→conversation',
      );
      _sherpaUseVoipMic = true;
      _sherpaKws?.setAndroidVoipEchoCapture(true);
      if (_sherpaKws != null && _isWakeUpActive) {
        await _sherpaKws!.pause();
        // pause 后给音频路由一点时间；适度降低以提升唤醒响应
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final micOk = await _sherpaKws!.start();
        print('🎚️ [VoipRoute] sherpa 已用 VoIP 麦重启 micOk=$micOk');
      }
      print(
          '⏱️ [Pipeline][Wake] Android VoIP+sherpa切换 ${routeSw.elapsedMilliseconds}ms');
    }

    if (!_multiPersonPushToTalkMode) {
      // 唤醒命中后并行预热主 ASR，尽量覆盖「首句欢迎语期间用户立刻开口」场景。
      unawaited(_prewarmAsrAfterWake());
    }

    final convSw = Stopwatch()..start();
    await _conversationController.enterConversationMode();
    convSw.stop();
    wakeSw.stop();
    print(
        '⏱️ [Pipeline][Wake] enterConversation+首句TTS整段 ${convSw.elapsedMilliseconds}ms');
    print(
        '⏱️ [Pipeline][Wake] 唤醒词命中→首句播完总耗时 ${wakeSw.elapsedMilliseconds}ms（含上述各段）',
    );

    Timer(const Duration(seconds: 1), () {
      _wakeWordLock = false;
    });

    notifyListeners();
  }

  Future<void> _prewarmAsrAfterWake() async {
    try {
      if (_isListening || _isStartingVoiceRecognition) return;
      print('🎙️ [WakePrewarm] 命中唤醒后后台预热 ASR');
      await startVoiceRecognition();
    } catch (e, st) {
      print('⚠️ [WakePrewarm] 预热 ASR 失败: $e\n$st');
    }
  }

  /// 启动10秒空闲监测
  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(seconds: 10), () {
      if (!isInConversationMode) {
        print("⏰ 10秒无唤醒词活动，启动环境监测");
        _startEnvironmentMonitoring();
      }
    });
    print("⏰ 10秒空闲计时器已启动");
  }

  /// 启动退出对话后120秒监测
  void _startPostConversationTimer() {
    _postConversationTimer?.cancel();
    _postConversationTimer = Timer(Duration(seconds: 120), () {
      if (!isInConversationMode) {
        print("⏰ 退出对话120秒后，启动环境监测");
        _startEnvironmentMonitoring();
      }
    });
    print("⏰ 退出对话后120秒计时器已启动");
  }

  /// 启动环境监测（使用新的EnvironMonitorModule）
  Future<void> _startEnvironmentMonitoring() async {
    if (!DebugRuntimeFlags.enableEnvironmentMonitoring) {
      // ignore: avoid_print
      print(
        '════════ 环境监测已关闭（DebugRuntimeFlags.enableEnvironmentMonitoring=false）════════',
      );
      return;
    }
    if (isInConversationMode) {
      print("⚠️ 连续对话模式中，跳过环境监测");
      return;
    }

    // 检查唤醒词检测状态
    if (_sherpaKws == null || !_isWakeUpActive) {
      print("⚠️ 唤醒词检测未运行，尝试重启...");
      await restartWakeWordDetection();

      // 重启后再次检查
      if (!_isWakeUpActive) {
        print("❌❌❌ 唤醒词检测激活失败！");
        print("⛔ 禁止启动环境监测（唤醒词是核心功能）");
        print("💡 提示：请检查 assets/sherpa_kws/ 模型是否完整后重启应用");
        return; // 不启动环境监测
      }
    }

    print("🌍 启动环境监测（完整版）");
    print("🎤 确认：唤醒词检测状态 = $_isWakeUpActive");

    // 使用异步启动，不阻塞唤醒词检测
    _conversationController.startEnvironmentMonitoring();

    notifyListeners();
  }

  /// 停止环境监测
  Future<void> _stopEnvironmentMonitoring() async {
    _idleTimer?.cancel();
    _postConversationTimer?.cancel();
    _conversationController.stopEnvironmentMonitoring();
    print("🛑 环境监测已停止");
    notifyListeners();
  }

  /// 启动手势识别
  Future<void> startGestureRecognition() async {
    if (_gestureService == null) {
      print("❌ 手势服务未初始化");
      return;
    }

    try {
      await _gestureService!.initializeCameraAndGestureRecognition();
      _isGestureRecognitionActive = true;

      // 设置UI模式为手势识别
      _uiModule.setProgramMode(ProgramMode.gestureRecognition);

      print("✅ 手势识别已启动");
      notifyListeners();
    } catch (e) {
      print("❌ 启动手势识别失败: $e");
    }
  }

  /// 停止手势识别
  void stopGestureRecognition() {
    if (_gestureService != null) {
      _gestureService!.dispose();
      _isGestureRecognitionActive = false;
      _isInGestureRecognitionMode = false;

      print("🛑 手势识别已停止");
      notifyListeners();
    }
  }

  /// 更新手势识别结果
  void updateGestureRecognition(String gesture, {double? x, double? y}) {
    _lastRecognizedGesture = gesture;
    print("🤚 手势更新: $gesture");
    notifyListeners();
  }

  /// 手势识别命令处理
  Future<void> handleGestureCommand(String command) async {
    if (command == "手势识别") {
      _isInGestureRecognitionMode = true;
      await startGestureRecognition();
    } else if (command == "退出" && _isInGestureRecognitionMode) {
      _isInGestureRecognitionMode = false;
      stopGestureRecognition();
    }
  }

  /// 启动唤醒词健康检查
  void _startWakeWordHealthCheck() {
    _wakeWordHealthCheck?.cancel();
    int consecutiveFailures = 0; // 连续失败计数

    _wakeWordHealthCheck = Timer.periodic(Duration(seconds: 5), (timer) async {
      // 检查唤醒词检测状态
      if (_sherpaKws == null || !_isWakeUpActive) {
        consecutiveFailures++;

        if (consecutiveFailures <= 3) {
          print("⚠️ 【健康检查】检测到唤醒词未运行！尝试重启 ($consecutiveFailures/3)");
          await restartWakeWordDetection();
        } else {
          print("❌ 【健康检查】唤醒词持续失败！");
          print("⛔ 停止自动重启尝试（请检查模型文件与麦克风权限）");
          print("💡 请检查日志中的详细错误信息并修复后重启应用");
          timer.cancel(); // 停止健康检查，避免无限循环
        }
      } else {
        consecutiveFailures = 0; // 重置失败计数
        print("💓 【健康检查】唤醒词检测正常运行");
      }
    });
    print("✅ 唤醒词健康检查已启动（每5秒检查一次）");
  }

  /// 重启唤醒词检测
  Future<void> restartWakeWordDetection() async {
    try {
      print("🔄 开始重启唤醒词检测...");

      await _sherpaKws?.stop();
      _sherpaKws = null;
      print("🛑 已停止旧的 sherpa 唤醒服务");

      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }

      // 重新初始化
      await _initializeSherpaKws();

      // 只有在真正成功时才打印成功日志
      if (_isWakeUpActive) {
        print("✅ 唤醒词检测重启成功");
      }
    } catch (e) {
      print("❌ 重启唤醒词检测失败");
      _isWakeUpActive = false;
      _sherpaKws = null;
      notifyListeners();
      // 不再重新抛出异常，避免健康检查崩溃
    }
  }

  /// 获取当前UI动画路径
  String get currentAnimation => _uiModule.currentAnimation;

  /// 获取UI动画模块
  UIAnimationModule get uiModule => _uiModule;

  /// 清理资源
  Future<void> dispose() async {
    print("🗑️ 清理简化版语音通知器资源");

    _duplexTtsBargeInEnabled = false;
    // 取消所有计时器
    _idleTimer?.cancel();
    _postConversationTimer?.cancel();
    _wakeWordHealthCheck?.cancel();

    await _sherpaKws?.stop();
    _sherpaKws = null;

    await _qwenAsrRecorder?.stopWithoutSubmit();
    _qwenAsrRecorder = null;
    _listeningViaQwen = false;

    if (Platform.isAndroid) {
      _sherpaUseVoipMic = false;
      await AndroidVoipAudioRoute.instance
          .setConversationVoipEnabled(false, debugTag: 'dispose');
    }

    // 停止其他服务
    await _stopEnvironmentMonitoring();
    stopGestureRecognition();

    await _conversationController.dispose();
    _uiModule.dispose();

    super.dispose();
  }

  /// 强制停止所有活动
  Future<void> forceStop() async {
    _duplexTtsBargeInEnabled = false;
    _idleTimer?.cancel();
    _postConversationTimer?.cancel();
    await _qwenAsrRecorder?.stopWithoutSubmit();
    _qwenAsrRecorder = null;
    _listeningViaQwen = false;
    // 注意：不取消健康检查，确保唤醒词始终运行
    await _conversationController.forceStop();
    if (Platform.isAndroid) {
      _sherpaUseVoipMic = false;
      _sherpaKws?.setAndroidVoipEchoCapture(false);
      await AndroidVoipAudioRoute.instance
          .setConversationVoipEnabled(false, debugTag: 'forceStop');
    }
    await _stopEnvironmentMonitoring();
    stopGestureRecognition();
  }

  /// 句末判定触发但无有效文本时，麦已由 [QwenStreamingAsrRecorder] 关闭，需延迟重开听写。
  void _scheduleRestartAsrIfConversationIdle() {
    if (!_conversationController.isInConversationMode) return;
    if (_multiPersonPushToTalkMode) return;
    ConversationFlowTracer.asr(
      'scheduleRestartAsrIfConversationIdle armed delay=180ms',
    );
    unawaited(Future<void>.delayed(const Duration(milliseconds: 180), () async {
      if (!_conversationController.isInConversationMode) return;
      if (_conversationController.isProcessingUserInput) return;
      if (_isListening || _isStartingVoiceRecognition) return;
      ConversationFlowTracer.asr(
        'scheduleRestartAsrIfConversationIdle firing startVoiceRecognition',
      );
      await startVoiceRecognition();
    }));
  }

  /// 启动语音识别监听
  Future<void> startVoiceRecognition() async {
    if (skipAutoVoiceRecognitionInConversation && !_pttRecordingActive) {
      ConversationFlowTracer.asr(
        'startVoiceRecognition SKIP multi_person_push_to_talk',
      );
      print('🎙️ 多人按住说话模式：跳过自动连续聆听');
      return;
    }
    if (_isListening) {
      final qwenStale = _listeningViaQwen && _qwenAsrRecorder == null;
      if (!qwenStale) {
        if (_conversationController.isInConversationMode && _listeningViaQwen) {
          _duplexTtsBargeInEnabled = true;
        }
        ConversationFlowTracer.asr(
          'startVoiceRecognition SKIP already_listening '
          'qwen=$_listeningViaQwen duplex=$_duplexTtsBargeInEnabled',
        );
        print("🎙️ 语音识别已在运行");
        return;
      }
      ConversationFlowTracer.asr(
        'startVoiceRecognition STALE_STATE clearing flags and restarting',
      );
      print('⚠️ Qwen ASR 假运行：监听标志为真但录音器已释放，将重新启动');
      _isListening = false;
      _listeningViaQwen = false;
    }
    if (_isStartingVoiceRecognition) {
      ConversationFlowTracer.asr(
        'startVoiceRecognition SKIP already_starting',
      );
      print("🎙️ 语音识别启动中，跳过重复请求");
      return;
    }
    _isStartingVoiceRecognition = true;

    try {
      ConversationFlowTracer.asr(
        'startVoiceRecognition ENTER voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled} '
        'sherpaVoip=$_sherpaUseVoipMic',
      );
      print(
          "🎙️ 启动语音识别 (voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled} sherpaVoip=$_sherpaUseVoipMic)");

      _sherpaKws?.setTtsBargeInVadEnabled(false);
      await _sherpaKws?.pause();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final qwenClient = QwenCloudAsrClient();
      print('════════════════ QWEN ASR ENDPOINT ════════════════');
      print('🌐 [QWEN_ASR_BASE_URL] ${qwenClient.baseUrl}');
      print('════════════════════════════════════════════════════');
      final qwenUp = await qwenClient.healthz();
      print('🩺 [QWEN /healthz] ${qwenUp ? "OK" : "FAIL"} @ ${qwenClient.baseUrl}/healthz');
      if (qwenUp) {
        try {
          _qwenAsrRecorder = QwenStreamingAsrRecorder(
            client: qwenClient,
            onPartialText: (String t) {
              _speechText = t;
              notifyListeners();
            },
            onUtteranceFinal: (String t) {
              final s = t.trim();
              ConversationFlowTracer.asr(
                'onUtteranceFinal len=${t.length} trimmedEmpty=${s.isEmpty}',
              );
              _qwenAsrRecorder = null;
              _listeningViaQwen = false;
              _isListening = false;
              notifyListeners();
              if (s.isNotEmpty) {
                unawaited(_processUserInput(s));
              } else {
                _scheduleRestartAsrIfConversationIdle();
              }
            },
            androidVoipEchoCapture: _sherpaUseVoipMic,
            isTtsPlaying: () => _conversationController.isTtsPlaying,
            onSpeechDuringTtsBargeIn: () {
              unawaited(_handleDuplexTtsBargeInFromVad());
            },
          );
          await _qwenAsrRecorder!.start();
          _listeningViaQwen = true;
          if (_conversationController.isInConversationMode) {
            _duplexTtsBargeInEnabled = true;
          }
          print('✅ 语音识别：Qwen 云端 ASR（中英混合）');
          _logAsrEngineSelection('Qwen 云端 ASR（healthz 可达，中英混合）');
        } catch (e, st) {
          print('⚠️ Qwen ASR 启动失败，回退 VOSK: $e\n$st');
          _duplexTtsBargeInEnabled = false;
          _qwenAsrRecorder = null;
          _listeningViaQwen = false;
          if (_speechService == null) {
            await _initializeVosk();
          }
          await _speechService!.start();
          _duplexTtsBargeInEnabled = false;
          print('✅ 语音识别：VOSK（备选）');
          _logAsrEngineSelection('VOSK 本地中文（Qwen 启动失败后的回退）');
        }
      } else {
        print('ℹ️ Qwen ASR 不可达（/healthz），使用 VOSK');
        _duplexTtsBargeInEnabled = false;
        _listeningViaQwen = false;
        if (_speechService == null) {
          await _initializeVosk();
        }
        await _speechService!.start();
        _duplexTtsBargeInEnabled = false;
        print('✅ 语音识别：VOSK（备选）');
        _logAsrEngineSelection('VOSK 本地中文（Qwen /healthz 不可达）');
      }

      _isListening = true;
      ConversationFlowTracer.asr(
        'startVoiceRecognition OK listening=$_isListening qwen=$_listeningViaQwen',
      );
      // 仅在非播报阶段切换到「聆听脸」，避免欢迎语/回复开头先闪可爱02再进说话脸。
      if (_conversationController.isInConversationMode &&
          !_conversationController.isTtsPlaying) {
        _uiModule.showConversationListeningFace();
      }
      notifyListeners();
    } catch (e) {
      ConversationFlowTracer.asr('startVoiceRecognition EXCEPTION $e');
      print("❌ 启动语音识别失败: $e");
    } finally {
      _isStartingVoiceRecognition = false;
    }
  }

  /// 停止语音识别监听。
  ///
  /// [resumeSherpaKws] 为 false 时不在此处恢复唤醒监听（连续对话处理 / TTS 期间应保持暂停，
  /// 避免与 VOSK 释放麦克风竞态导致闪退，也避免 TTS 播放时误触发唤醒）。
  Future<void> stopVoiceRecognition({bool resumeSherpaKws = true}) async {
    try {
      if (_isListening) {
        ConversationFlowTracer.asr(
          'stopVoiceRecognition qwen=$_listeningViaQwen resumeSherpa=$resumeSherpaKws',
        );
        if (_listeningViaQwen && _qwenAsrRecorder != null) {
          await _qwenAsrRecorder!.stopWithoutSubmit();
          _qwenAsrRecorder = null;
          _listeningViaQwen = false;
        } else {
          await _speechService?.stop();
        }
        _isListening = false;
      }
      // 退出对话等场景下 VOSK 可能已停，但仍需恢复唤醒监听
      if (resumeSherpaKws && _isWakeUpActive && _sherpaKws != null) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _sherpaKws!.resume();
      }
      notifyListeners();
      print("🔇 语音识别已处理${resumeSherpaKws ? '' : '（唤醒监听保持暂停至退出对话）'}");
    } catch (e) {
      print("❌ 停止语音识别失败: $e");
    }
  }

  /// 对话流程已结束、退出 TTS 播完后再恢复 sherpa 唤醒（避免与扬声器同时抢麦导致 native 闪退）。
  Future<void> resumeSherpaWakeListeningAfterExit() async {
    if (!_isWakeUpActive || _sherpaKws == null) return;
    try {
      // 原 1400ms+400ms 导致退出后约 2s 内无法唤醒；略缩短，若个别机型仍闪退可调大
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (Platform.isAndroid) {
        print(
            '🎚️ [VoipRoute] exit_conversation: 关闭 VoIP 路由并恢复 DEFAULT 麦前 pause sherpa');
        _sherpaUseVoipMic = false;
        _sherpaKws?.setAndroidVoipEchoCapture(false);
        await AndroidVoipAudioRoute.instance.setConversationVoipEnabled(
          false,
          speakerphone: false,
          debugTag: 'exit_conversation',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await _sherpaKws!.resume();
      print(
          "🎤 退出对话完成，已恢复唤醒监听 (sherpaVoip=$_sherpaUseVoipMic voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled})");
    } catch (e, st) {
      print("❌ 恢复唤醒监听失败: $e\n$st");
    }
  }

  /// 初始化VOSK语音识别
  Future<void> _initializeVosk() async {
    try {
      print("🎤 初始化VOSK语音识别服务");

      // 复制VOSK模型到本地
      final modelDir = await _copyAssetDir(_voskAssetDir);

      // 创建VOSK服务
      final plugin = VoskFlutterPlugin.instance();
      final model = await plugin.createModel(modelDir);
      final recognizer = await plugin.createRecognizer(
        model: model,
        sampleRate: 16000,
      );
      _speechService = await plugin.initSpeechService(recognizer);

      // 设置语音识别监听器
      _speechService!.onResult().listen((jsonStr) async {
        try {
          final result = jsonDecode(jsonStr) as Map<String, dynamic>;
          final text = (result['text'] ?? '').toString().trim();

          if (text.isNotEmpty) {
            print("🎤 语音识别结果: $text");
            await _processUserInput(text);
          }
        } catch (e, st) {
          print("❌ VOSK onResult 处理异常: $e\n$st");
        }
      });

      // 部分识别监听器（实时显示）
      _speechService!.onPartial().listen((partial) {
        try {
          final result = jsonDecode(partial) as Map<String, dynamic>;
          final text = (result['partial'] ?? '').toString().trim();
          if (text.isNotEmpty) {
            _speechText = text;
            notifyListeners();
          }
        } catch (e) {
          print("❌ VOSK onPartial 解析异常: $e");
        }
      });

      print("✅ VOSK语音识别服务初始化成功");
    } catch (e) {
      print("❌ 初始化VOSK失败: $e");
      rethrow;
    }
  }

  /// 复制资源目录到本地
  Future<String> _copyAssetDir(String assetDir) async {
    final docDir = await getApplicationDocumentsDirectory();
    final targetDir = Directory('${docDir.path}/vosk-model');

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);

      // 复制模型文件
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      for (String key in manifestMap.keys) {
        if (key.startsWith(assetDir)) {
          final byteData = await rootBundle.load(key);
          final file =
              File('${targetDir.path}/${key.replaceFirst(assetDir, '')}');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(byteData.buffer.asUint8List());
        }
      }

      print("✅ VOSK模型文件已复制到本地");
    }

    return targetDir.path;
  }

  /// 处理用户输入（转发给连续对话控制器）
  Future<void> _processUserInput(String input) async {
    if (input.isEmpty) return;

    ConversationFlowTracer.asr(
      '_processUserInput -> conversationController.processUserInput '
      'len=${input.length}',
    );
    _speechText = input;
    notifyListeners();

    // 边播边听：连续对话且 Qwen 已启用时，主 ASR 在 TTS 前保持/预拉起，不在此处停麦，
    // 避免「Sherpa 打断 → 再切 Qwen」丢前几个字；否则沿用停麦再处理。
    if (_conversationController.isInConversationMode) {
      // 复杂任务执行中保持 ASR 常开，允许新语音随时打断当前任务。
      final keepAsrForInterrupt = _conversationController.isComplexTaskExecuting;
      if (!_duplexTtsBargeInEnabled && !keepAsrForInterrupt) {
        await stopVoiceRecognition(resumeSherpaKws: false);
      }
    } else {
      await stopVoiceRecognition(resumeSherpaKws: false);
    }

    await _conversationController.processUserInput(input);
  }

  /// 兼容性方法：外部调用
  Future<void> processUserInput(String input) async {
    await _processUserInput(input);
  }

  /// 退出连续对话后清空 ASR 展示文案，避免 home 旧版「读词猜表情」把尾稿判成可爱脸
  void resetSpeechDisplayToWakePrompt() {
    _speechText = '等待唤醒词...';
    notifyListeners();
  }

  /// 退出连续对话等场景：关闭边播边听，恢复「TTS 前 Sherpa 打断」策略（VOSK 路径）。
  void clearDuplexTtsBargeInMode() {
    _duplexTtsBargeInEnabled = false;
  }

  /// 完成发送（兼容旧接口）
  void completeSending() {
    // 简化版不需要此功能，保留空实现以兼容
  }

  /// 兼容性方法
  bool get isInappropriateContent => false;
  String? get currentExpression => null;
  bool get isInFollowMode => false;
  String? get currentGesture =>
      _lastRecognizedGesture.isNotEmpty ? _lastRecognizedGesture : null;
}
