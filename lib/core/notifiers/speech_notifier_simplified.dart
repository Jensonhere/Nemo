import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:voicegpt/core/services/android_voip_audio_route.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';
import 'package:voicegpt/core/services/sherpa_kws_wake_service.dart';
import 'package:voicegpt/core/services/gesture_service.dart';
import 'package:voicegpt/core/llm/llm_router.dart';
import 'package:voicegpt/core/modules/conversation_controller.dart';
import 'package:voicegpt/core/modules/intent_recognition_module.dart';
import 'package:voicegpt/core/modules/plan_executor_controller.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/services/qwen_cloud_asr_client.dart';
import 'package:voicegpt/core/services/qwen_streaming_asr_recorder.dart';
import 'package:voicegpt/core/services/va_pcm_recorder.dart';
import 'package:voicegpt/core/services/va_service_config.dart';
import 'package:voicegpt/core/services/va_session_manager.dart';
import 'package:voicegpt/core/config/debug_runtime_flags.dart';
import 'package:voicegpt/core/debug/conversation_flow_tracer.dart';
import 'package:voicegpt/core/models/owner_voiceprint_verify_result.dart';
import 'package:voicegpt/core/models/owner_voiceprint_sample.dart';
import 'package:voicegpt/core/services/speaker_enrollment_store.dart';
import 'package:voicegpt/core/services/speaker_enrollment_recorder.dart';
import 'package:voicegpt/core/services/speaker_enrollment_audio_player.dart';
import 'package:voicegpt/core/services/sherpa_speaker_embedding_service.dart';
import 'package:voicegpt/core/services/owner_voiceprint_verifier.dart';

/// 声纹注册 UI 阶段（与右下角麦克风显隐联动）。
enum OwnerVoiceprintEnrollUi {
  none,
  capturing,
  extracting,
  success,
  failure,
}

/// 声纹比对场景：聆听定稿输入 vs TTS 打断。
enum OwnerVoiceprintVerifyContext {
  listeningInput,
  bargeIn,
}

/// 简化的语音通知器
/// 只保留核心基础功能：唤醒词检测、环境监测、手势识别基础功能
class SpeechNotifierSimplified with ChangeNotifier {
  // === 核心服务 ===
  final ConversationController _conversationController =
      ConversationController();
  final IntentRecognitionModule _intentModule = IntentRecognitionModule();
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
  bool _idleTimerScheduled = false;

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
  VaSessionManager? _vaSessionManager;
  VaPcmRecorder? _vaPcmRecorder;
  bool _listeningViaQwen = false;
  bool _listeningViaVosk = false;
  bool _isVaRecognitionActive = false;
  Timer? _vaRecognitionDisplayTimer;
  DateTime? _vaRecognitionDisplayStartedAt;
  bool _isListening = false;
  bool _isStartingVoiceRecognition = false;
  final String _voskAssetDir = "assets/cn/vosk-model-small-cn-0.22/";

  static const Duration _vaRecognitionMinDisplayDuration = Duration(seconds: 5);

  static const List<String> _vaVisionKeywords = <String>[
    '心情',
    '情绪',
    '表情',
    '看起来',
    '脸色',
    '状态',
    '难过',
    '伤心',
    '开心',
    '高兴',
    '生气',
    '烦',
    '不开心',
    '我现在看起来',
    '我看起来',
  ];

  final List<Uint8List> _pendingVaAudioChunks = <Uint8List>[];
  static const int _maxPendingVaAudioChunks = 120;
  bool _voskFinalResultConsumed = false;
  String _lastAcceptedVoskFinalText = '';

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

  void _resetPendingVaCapture() {
    _pendingVaAudioChunks.clear();
    _voskFinalResultConsumed = false;
    _lastAcceptedVoskFinalText = '';
  }

  void _bufferPendingVaAudioChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _pendingVaAudioChunks.add(Uint8List.fromList(chunk));
    if (_pendingVaAudioChunks.length > _maxPendingVaAudioChunks) {
      _pendingVaAudioChunks.removeAt(0);
    }
  }

  List<Uint8List> _snapshotPendingVaAudioChunks() {
    return _pendingVaAudioChunks
        .map((chunk) => Uint8List.fromList(chunk))
        .toList(growable: false);
  }

  void _showVaRecognitionDisplay() {
    _vaRecognitionDisplayTimer?.cancel();
    _vaRecognitionDisplayTimer = null;
    _vaRecognitionDisplayStartedAt = DateTime.now();
    if (_isVaRecognitionActive) return;
    _isVaRecognitionActive = true;
    notifyListeners();
  }

  void _hideVaRecognitionDisplayAfterMinimum() {
    final startedAt = _vaRecognitionDisplayStartedAt;
    final elapsed = startedAt == null
        ? _vaRecognitionMinDisplayDuration
        : DateTime.now().difference(startedAt);
    final remaining = _vaRecognitionMinDisplayDuration - elapsed;
    _vaRecognitionDisplayTimer?.cancel();
    if (remaining <= Duration.zero) {
      _vaRecognitionDisplayTimer = null;
      _vaRecognitionDisplayStartedAt = null;
      if (!_isVaRecognitionActive) return;
      _isVaRecognitionActive = false;
      notifyListeners();
      return;
    }

    _vaRecognitionDisplayTimer = Timer(remaining, () {
      _vaRecognitionDisplayTimer = null;
      _vaRecognitionDisplayStartedAt = null;
      if (!_isVaRecognitionActive) return;
      _isVaRecognitionActive = false;
      notifyListeners();
    });
  }

  List<Uint8List> _coalescePendingVaAudioChunks(
    List<Uint8List> chunks, {
    int targetBytes = 128000,
  }) {
    if (chunks.isEmpty) return const <Uint8List>[];
    if (chunks.length == 1) return List<Uint8List>.from(chunks);

    final merged = <Uint8List>[];
    final current = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      if (current.length > 0 && current.length + chunk.length > targetBytes) {
        merged.add(Uint8List.fromList(current.toBytes()));
        current.clear();
      }
      current.add(chunk);
    }
    if (current.length > 0) {
      merged.add(Uint8List.fromList(current.toBytes()));
    }
    return merged;
  }

  Future<Map<String, dynamic>?> _runDeferredVaIfNeeded(
    String text,
    RouterDecision routerDecision,
    List<Uint8List>? audioChunks,
  ) async {
    if (routerDecision.scene != RouterScene.companion) {
      print('ℹ️ [VA] Router 未命中 Companion，跳过 VA');
      return null;
    }

    print('💞 [VA] Router 命中 Companion，开始补跑当前轮 VA');
    final manager = _vaSessionManager ?? VaSessionManager();
    _vaSessionManager = manager;
    _showVaRecognitionDisplay();
    try {
      final vaSid = await manager.startSession();
      if (vaSid == null) {
        print('ℹ️ [VA] 延后启动失败，当前轮降级为仅文本陪伴');
        return null;
      }
      final rawAudioChunks = audioChunks ?? _pendingVaAudioChunks;
      final rawAudioBytes =
          rawAudioChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final mergedChunks = _coalescePendingVaAudioChunks(rawAudioChunks);
      print(
        '🎧 [VA] 回放当前轮音频 rawChunks=${rawAudioChunks.length} '
        'rawBytes=$rawAudioBytes mergedChunks=${mergedChunks.length} sid=$vaSid',
      );
      for (final chunk in mergedChunks) {
        await manager.sendAudioChunk(chunk);
      }
      final normalized = text.trim();
      if (normalized.isNotEmpty) {
        final hit =
            _vaVisionKeywords.any((keyword) => normalized.contains(keyword));
        if (hit) {
          print('🎯 [VA] Router 后命中视觉增强关键词 transcript="$normalized"');
          manager.enableVisionEnhancement();
        }
      }
      final uploaded = await manager.uploadCachedImagesForEmotionBranch();
      print('🖼️ [VA] Router 后统一上传缓存图数量=$uploaded');
      final vaResult = await manager.finishSession();
      print('📝 [VA] 当前轮最终结果=${vaResult?['fusion_summary'] ?? 'none'}');
      return vaResult;
    } catch (e) {
      print('❌ [VA] 延后补跑失败: $e');
      return null;
    } finally {
      await manager.reset();
      if (identical(_vaSessionManager, manager)) {
        _vaSessionManager = null;
      }
      _hideVaRecognitionDisplayAfterMinimum();
    }
  }

  /// Getters
  bool get isInConversationMode => _conversationController.isInConversationMode;
  bool get isProcessingUserInput =>
      _conversationController.isProcessingUserInput;
  bool get isTtsPlaying => _conversationController.isTtsPlaying;
  bool get isWakeUpActive => _isWakeUpActive;
  bool get isListening => _isListening;
  bool get isVaRecognitionActive => _isVaRecognitionActive;

  /// 连续对话里 TTS 结束后拉起主 ASR 的短窗口：此时 isListening 仍为 false，但不应显示「思考中/已暂停」。
  bool get isStartingVoiceRecognition => _isStartingVoiceRecognition;
  bool get isReadyToSend => false;
  bool _multiPersonPushToTalkMode = false;
  bool _pttRecordingActive = false;
  bool _pttFingerPressed = false;
  int _pttHoldGeneration = 0;
  bool get isMultiPersonPushToTalkMode => _multiPersonPushToTalkMode;
  bool get isPttRecordingHold => _pttRecordingActive;
  bool get isPttFingerPressed => _pttFingerPressed;
  bool get skipAutoVoiceRecognitionInConversation =>
      _multiPersonPushToTalkMode &&
      _conversationController.isInConversationMode;

  /// 右上角「主人模式」：所有用户输入（聆听定稿 + TTS 打断）均需通过声纹比对。
  bool _ownerMode = false;

  /// 右上角「主人声纹打断播报」：仅 TTS 播报期间需主人声纹才可打断。
  bool _ownerVoiceprintBargeInMode = false;
  bool _ownerVoiceprintEnrolled = false;
  OwnerVoiceprintEnrollUi _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.none;
  String _ownerVoiceprintEnrollmentHint = '';
  int _ownerVoiceprintCaptureMs = 0;
  SpeakerEnrollmentRecorder? _enrollmentRecorder;
  int _enrollmentGeneration = 0;
  Timer? _ownerVoiceprintResultTimer;

  bool _ownerVoiceprintLibraryOpen = false;
  String? _ownerVoiceprintPlayingId;
  String? _ownerVoiceprintSelectedId;
  OwnerVoiceprintVerifyResult? _lastVoiceprintVerifyResult;
  OwnerVoiceprintVerifyContext? _lastVoiceprintVerifyContext;
  Timer? _voiceprintVerifyDisplayTimer;
  bool _voiceprintVerifyInProgress = false;

  static const int ownerVoiceprintMaxSamples =
      SpeakerEnrollmentStore.maxSamples;

  static const String ownerVoiceprintEnrollmentPrompt = '请你念出：你好小航，请开始陪伴模式';

  bool get isOwnerMode => _ownerMode;
  bool get isOwnerVoiceprintBargeInMode => _ownerVoiceprintBargeInMode;
  bool get hasOwnerVoiceprint => _ownerVoiceprintEnrolled;

  /// 聆听输入或 TTS 打断是否需要声纹闸门。
  bool get _voiceprintGateForBargeIn =>
      _ownerVoiceprintBargeInMode || _ownerMode;
  OwnerVoiceprintEnrollUi get ownerVoiceprintUi => _ownerVoiceprintUi;
  bool get isOwnerVoiceprintEnrolling =>
      _ownerVoiceprintUi == OwnerVoiceprintEnrollUi.capturing ||
      _ownerVoiceprintUi == OwnerVoiceprintEnrollUi.extracting;
  String get ownerVoiceprintEnrollmentHint => _ownerVoiceprintEnrollmentHint;
  int get ownerVoiceprintCaptureMs => _ownerVoiceprintCaptureMs;

  /// 采录 / 提取 / 成功 / 失败状态条（与打断模式无关）。
  bool get showOwnerVoiceprintStatusBanner =>
      _ownerVoiceprintUi != OwnerVoiceprintEnrollUi.none;

  bool get isOwnerVoiceprintLibraryOpen => _ownerVoiceprintLibraryOpen;
  List<OwnerVoiceprintSample> get ownerVoiceprintSamples =>
      SpeakerEnrollmentStore.instance.samplesForUi;
  String? get ownerVoiceprintPlayingId => _ownerVoiceprintPlayingId;
  String? get ownerVoiceprintSelectedId =>
      _ownerVoiceprintSelectedId ??
      SpeakerEnrollmentStore.instance.activeSampleId;
  bool get canAddOwnerVoiceprintSample =>
      SpeakerEnrollmentStore.instance.sampleCount < ownerVoiceprintMaxSamples;
  bool get canDeleteOwnerVoiceprintSample =>
      ownerVoiceprintSelectedId != null &&
      SpeakerEnrollmentStore.instance.sampleCount > 0;

  OwnerVoiceprintVerifyResult? get lastVoiceprintVerifyResult =>
      _lastVoiceprintVerifyResult;

  /// 声纹比对摘要（聆听输入 / TTS 打断）。
  String? get ownerVoiceprintVerifyStatusLabel {
    final r = _lastVoiceprintVerifyResult;
    if (r == null) return null;
    final listening = _lastVoiceprintVerifyContext ==
        OwnerVoiceprintVerifyContext.listeningInput;
    if (_voiceprintVerifyInProgress) {
      return listening ? '🔐 聆听输入声纹比对中…' : '🔐 检测到打断人声，声纹比对中…';
    }
    if (!r.valid || r.bestScore == null) {
      final hint = r.reason ?? '未知';
      return listening ? '🔐 输入被拒：$hint' : '🔐 打断失败：$hint';
    }
    final score = r.bestScore!.toStringAsFixed(3);
    final th = OwnerVoiceprintVerifier.similarityThreshold.toStringAsFixed(2);
    if (r.pass) {
      return listening
          ? '🔐 匹配 $score ≥ $th · 已接受输入'
          : '🔐 匹配 $score ≥ $th · 允许打断';
    }
    return listening ? '🔐 未匹配 $score < $th · 已忽略' : '🔐 未匹配 $score < $th · 忽略';
  }

  bool get isVoiceprintVerifyInProgress => _voiceprintVerifyInProgress;

  bool get ownerVoiceprintEnrollMicIsReregister => _ownerVoiceprintEnrolled;

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
  String get lastRouterDecision => _conversationController.lastRouterDecision;
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
      print(
          "   请确认 assets/sherpa_kws/ 下已放入 sherpa-onnx KWS 模型文件（见 SherpaKwsWakeService 注释）");
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

      _ownerVoiceprintEnrolled = await SpeakerEnrollmentStore.instance.load();
      _ownerVoiceprintSelectedId =
          SpeakerEnrollmentStore.instance.activeSampleId;
      print(
        '🔐 声纹本地状态: ${_ownerVoiceprintEnrolled ? "已注册" : "未注册"}',
      );

      // 健康检查需要常驻：初始 KWS 失败时也负责后续重试和恢复空闲计时器。
      print("💓 第四步：启动唤醒词健康检查");
      _startWakeWordHealthCheck();

      // 只有唤醒词成功时才启动空闲监测；失败时等待健康检查重启成功后再补挂。
      if (wakeWordSuccess) {
        // 启动10秒空闲监测
        print("⏰ 第五步：启动10秒空闲监测");
        _scheduleIdleEnvironmentMonitoring(reason: 'initialize');

        print("✅ 简化版语音通知器初始化完成（唤醒词正常）");
      } else {
        print("⚠️ 简化版语音通知器初始化完成（唤醒词功能受限）");
        print("💡 将通过健康检查继续尝试恢复唤醒词，恢复后再启动空闲环境监测");
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

  static const Duration _pttHoldBeforeRecord = Duration(milliseconds: 140);

  Future<void> multiPersonPttTouchDown() async {
    if (!_multiPersonPushToTalkMode ||
        !_conversationController.isInConversationMode) {
      return;
    }
    if (_pttRecordingActive) return;
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

      if (_isListening) {
        await stopVoiceRecognition(resumeSherpaKws: false);
      }
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
        onPartialText: _onAsrPartialText,
        onUtteranceFinal: (String t) {
          final s = t.trim();
          final pcmSnap = _qwenAsrRecorder?.snapshotUtterancePcmForVerify() ??
              _qwenAsrRecorder?.snapshotBargeInRingForVerify();
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
            final vaAudioChunks = _snapshotPendingVaAudioChunks();
            unawaited(_handleFinalizedUserSpeech(
              s,
              pcmSnap: pcmSnap,
              vaAudioChunks: vaAudioChunks,
            ));
          } else if (!_multiPersonPushToTalkMode) {
            _scheduleRestartAsrIfConversationIdle();
          }
        },
        androidVoipEchoCapture: _sherpaUseVoipMic,
        isTtsPlaying: () => false,
        onSpeechDuringTtsBargeIn: null,
        onSpeechActivity: _pauseConversationTimeoutForUserSpeech,
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

  void _pauseConversationTimeoutForUserSpeech() {
    _conversationController.pauseConversationTimeoutForUserSpeech();
  }

  void _onAsrPartialText(String t) {
    if (t.trim().isNotEmpty) {
      _pauseConversationTimeoutForUserSpeech();
    }
    _speechText = t;
    notifyListeners();
  }

  void _publishVoiceprintVerifyResult(OwnerVoiceprintVerifyResult result) {
    _voiceprintVerifyInProgress = false;
    _lastVoiceprintVerifyResult = result;
    _voiceprintVerifyDisplayTimer?.cancel();
    _voiceprintVerifyDisplayTimer = Timer(const Duration(seconds: 8), () {
      _lastVoiceprintVerifyResult = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext context) {
    _pauseConversationTimeoutForUserSpeech();
    _voiceprintVerifyInProgress = true;
    _lastVoiceprintVerifyContext = context;
    _lastVoiceprintVerifyResult = OwnerVoiceprintVerifyResult.invalid;
    _voiceprintVerifyDisplayTimer?.cancel();
    notifyListeners();
  }

  Future<bool> _verifyOwnerVoiceprintForBargeIn(Float32List snap) async {
    _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext.bargeIn);
    final result = await OwnerVoiceprintVerifier.instance.verifyOwnerDetailed(
      snap,
      fastBargeIn: true,
    );
    _publishVoiceprintVerifyResult(result);
    return result.pass;
  }

  /// 主人模式：定稿 ASR 文本入库前先声纹比对。
  Future<void> _handleFinalizedUserSpeech(
    String input, {
    Float32List? pcmSnap,
    Map<String, dynamic>? vaResult,
    RouterDecision? precomputedRouterDecision,
    List<Uint8List>? vaAudioChunks,
  }) async {
    final s = input.trim();
    if (s.isEmpty) return;

    _pauseConversationTimeoutForUserSpeech();

    if (_ownerMode) {
      if (!_ownerVoiceprintEnrolled) {
        _speechText = '主人模式：请先录入主人声音';
        notifyListeners();
        if (_conversationController.isInConversationMode) {
          _scheduleRestartAsrIfConversationIdle();
        }
        return;
      }

      var snap = pcmSnap ?? Float32List(0);
      if (snap.length < OwnerVoiceprintVerifier.minSamplesForVerify) {
        snap = _qwenAsrRecorder?.snapshotUtterancePcmForVerify() ??
            _qwenAsrRecorder?.snapshotBargeInRingForVerify() ??
            snap;
      }
      if (snap.length < OwnerVoiceprintVerifier.minSamplesForVerify) {
        snap = _sherpaKws?.snapshotBargeInRingForVerify() ?? snap;
      }

      if (snap.isEmpty ||
          snap.length < OwnerVoiceprintVerifier.minSamplesForVerify) {
        _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext.listeningInput);
        _publishVoiceprintVerifyResult(
          const OwnerVoiceprintVerifyResult(
            bestScore: null,
            pass: false,
            valid: false,
            reason: '音频过短或麦克风流未就绪',
          ),
        );
        _speechText = '主人模式：音频过短，请重说';
        notifyListeners();
        if (_conversationController.isInConversationMode) {
          _scheduleRestartAsrIfConversationIdle();
        }
        return;
      }

      _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext.listeningInput);
      _speechText = '🔐 主人声纹比对中…';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
      final result =
          await OwnerVoiceprintVerifier.instance.verifyOwnerDetailed(snap);
      _publishVoiceprintVerifyResult(result);
      if (!result.pass) {
        _speechText = '主人模式：非主人语音，已忽略';
        notifyListeners();
        if (_conversationController.isInConversationMode) {
          _scheduleRestartAsrIfConversationIdle();
        }
        return;
      }
    }

    var nextVaResult = vaResult;
    var nextRouterDecision = precomputedRouterDecision;
    if (nextRouterDecision == null) {
      nextRouterDecision =
          await _conversationController.previewRouterDecision(s);
      print('🧭 [Router][ASR后预判] ${nextRouterDecision.rawJson}');
    }
    nextVaResult ??= await _runDeferredVaIfNeeded(
      s,
      nextRouterDecision,
      vaAudioChunks,
    );

    await _processUserInput(
      s,
      vaResult: nextVaResult,
      precomputedRouterDecision: nextRouterDecision,
    );
  }

  /// VAD 触发后短等环缓冲（打断快路径，避免近 1s 空等）。
  Future<Float32List?> _collectBargeInPcmForVerify() async {
    for (var i = 0; i < 3; i++) {
      final snap = _qwenAsrRecorder?.snapshotBargeInRingForVerify();
      if (snap != null &&
          snap.length >= OwnerVoiceprintVerifier.minSamplesForVerify) {
        return snap;
      }
      if (i < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    final last = _qwenAsrRecorder?.snapshotBargeInRingForVerify();
    if (last != null && last.isNotEmpty) return last;
    return null;
  }

  /// 打开 / 关闭右上角声纹库面板。
  void toggleOwnerVoiceprintLibrary() {
    if (isOwnerVoiceprintEnrolling) return;
    _ownerVoiceprintLibraryOpen = !_ownerVoiceprintLibraryOpen;
    if (_ownerVoiceprintLibraryOpen) {
      _ownerVoiceprintSelectedId =
          SpeakerEnrollmentStore.instance.activeSampleId ??
              (ownerVoiceprintSamples.isNotEmpty
                  ? ownerVoiceprintSamples.first.id
                  : null);
    }
    notifyListeners();
  }

  void closeOwnerVoiceprintLibrary() {
    if (!_ownerVoiceprintLibraryOpen) return;
    _ownerVoiceprintLibraryOpen = false;
    notifyListeners();
  }

  Future<void> selectOwnerVoiceprintSample(String id) async {
    _ownerVoiceprintSelectedId = id;
    final ok = await SpeakerEnrollmentStore.instance.setActiveSample(id);
    if (ok) {
      _ownerVoiceprintEnrolled = SpeakerEnrollmentStore.instance.hasEnrollment;
    }
    notifyListeners();
  }

  Future<void> deleteSelectedOwnerVoiceprintSample() async {
    final id = ownerVoiceprintSelectedId;
    if (id == null) return;
    if (_ownerVoiceprintPlayingId == id) {
      await SpeakerEnrollmentAudioPlayer.instance.stop();
      _ownerVoiceprintPlayingId = null;
    }
    await SpeakerEnrollmentStore.instance.deleteSample(id);
    _ownerVoiceprintEnrolled = SpeakerEnrollmentStore.instance.hasEnrollment;
    _ownerVoiceprintSelectedId = SpeakerEnrollmentStore.instance.activeSampleId;
    if (!_ownerVoiceprintEnrolled) {
      if (_ownerVoiceprintBargeInMode) {
        _ownerVoiceprintBargeInMode = false;
      }
      if (_ownerMode) {
        _ownerMode = false;
      }
      _speechText = '声纹已清空，主人模式与声纹打断已关闭';
    }
    notifyListeners();
  }

  Future<void> playOwnerVoiceprintSample(String id) async {
    final path = await SpeakerEnrollmentStore.instance.wavAbsolutePath(id);
    if (path == null) {
      _speechText = '该条声纹暂无试听文件';
      notifyListeners();
      return;
    }
    _ownerVoiceprintPlayingId = id;
    notifyListeners();
    try {
      await SpeakerEnrollmentAudioPlayer.instance.play(id, path);
    } finally {
      _ownerVoiceprintPlayingId = null;
      notifyListeners();
    }
  }

  /// 从声纹库 [+] 发起新录音（最多 3 条）。
  Future<void> startOwnerVoiceprintEnrollmentFromLibrary() async {
    if (!canAddOwnerVoiceprintSample) {
      _speechText = '最多保存 $ownerVoiceprintMaxSamples 条声纹';
      notifyListeners();
      return;
    }
    await startOwnerVoiceprintEnrollment();
  }

  /// 右上角「主人模式」：聆听与打断输入均需声纹比对。
  Future<void> setOwnerMode(bool enabled) async {
    if (enabled && !_ownerVoiceprintEnrolled) {
      _speechText = '不可使用：请先在右上角录入主人声音';
      notifyListeners();
      return;
    }
    if (_ownerMode == enabled) return;
    _ownerMode = enabled;
    if (enabled &&
        _conversationController.isInConversationMode &&
        _listeningViaQwen) {
      _duplexTtsBargeInEnabled = true;
      _sherpaKws?.setTtsBargeInVadEnabled(false);
    }
    notifyListeners();
  }

  /// 右上角「主人声纹打断播报」：需已录入声纹；未录入时拒绝开启并提示。
  Future<void> setOwnerVoiceprintBargeInMode(bool enabled) async {
    if (enabled && !_ownerVoiceprintEnrolled) {
      _speechText = '不可使用：请先在右上角录入主人声音';
      notifyListeners();
      return;
    }
    if (_ownerVoiceprintBargeInMode == enabled) return;
    _ownerVoiceprintBargeInMode = enabled;
    if (enabled &&
        _conversationController.isInConversationMode &&
        _listeningViaQwen) {
      _duplexTtsBargeInEnabled = true;
      _sherpaKws?.setTtsBargeInVadEnabled(false);
    }
    notifyListeners();
  }

  void _scheduleOwnerVoiceprintResultDismiss() {
    _ownerVoiceprintResultTimer?.cancel();
    _ownerVoiceprintResultTimer = Timer(const Duration(seconds: 4), () {
      if (_ownerVoiceprintUi == OwnerVoiceprintEnrollUi.success ||
          _ownerVoiceprintUi == OwnerVoiceprintEnrollUi.failure) {
        _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.none;
        _ownerVoiceprintEnrollmentHint = '';
        notifyListeners();
      }
    });
  }

  /// 右上角声纹库 [+]：采录 PCM 并提取 embedding；首条成功后自动进入连续对话。
  Future<void> startOwnerVoiceprintEnrollment() async {
    if (isOwnerVoiceprintEnrolling) return;
    if (!canAddOwnerVoiceprintSample) {
      _speechText = '最多保存 $ownerVoiceprintMaxSamples 条声纹，请先删除旧条目';
      notifyListeners();
      return;
    }

    final countBefore = SpeakerEnrollmentStore.instance.sampleCount;
    final arm = ++_enrollmentGeneration;
    _ownerVoiceprintResultTimer?.cancel();
    _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.capturing;
    _ownerVoiceprintCaptureMs = 0;
    _ownerVoiceprintEnrollmentHint = '正在聆听…';
    notifyListeners();

    try {
      if (_isListening) {
        await stopVoiceRecognition(resumeSherpaKws: false);
      }
      _sherpaKws?.setTtsBargeInVadEnabled(false);
      await _sherpaKws?.pause();

      _enrollmentRecorder = SpeakerEnrollmentRecorder(
        androidVoipEchoCapture: _sherpaUseVoipMic,
        onProgress: ({
          required int totalMs,
          required bool speechSeen,
          required int silenceMs,
          required double peakRms,
        }) {
          if (arm != _enrollmentGeneration) return;
          _ownerVoiceprintCaptureMs = totalMs;
          if (speechSeen && silenceMs > 0) {
            _ownerVoiceprintEnrollmentHint =
                '已检测到语音，句尾静音 ${(silenceMs / 1000).toStringAsFixed(1)}s…';
          } else if (speechSeen) {
            _ownerVoiceprintEnrollmentHint = '正在聆听，请念出引导语…';
          } else {
            _ownerVoiceprintEnrollmentHint =
                '正在聆听… ${(totalMs / 1000).toStringAsFixed(1)}s';
          }
          notifyListeners();
        },
      );
      final samples = await _enrollmentRecorder!.capture();
      _enrollmentRecorder = null;

      if (arm != _enrollmentGeneration) return;

      if (samples == null || samples.isEmpty) {
        _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.failure;
        _ownerVoiceprintEnrollmentHint = '采录过短或未检测到有效语音，请重试';
        _scheduleOwnerVoiceprintResultDismiss();
        return;
      }

      _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.extracting;
      _ownerVoiceprintEnrollmentHint = '采录完成，正在提取声纹…';
      notifyListeners();

      final ready = await SherpaSpeakerEmbeddingService.instance.ensureReady();
      if (arm != _enrollmentGeneration) return;
      if (!ready) {
        _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.failure;
        _ownerVoiceprintEnrollmentHint =
            '声纹模型未就绪，请将模型放入 assets/sherpa_speaker/（见 README）';
        _scheduleOwnerVoiceprintResultDismiss();
        return;
      }

      final embedding =
          SherpaSpeakerEmbeddingService.instance.computeFromSamples(samples);
      if (arm != _enrollmentGeneration) return;
      if (embedding == null || embedding.isEmpty) {
        _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.failure;
        _ownerVoiceprintEnrollmentHint = '声纹提取失败，请在安静环境重试';
        _scheduleOwnerVoiceprintResultDismiss();
        return;
      }

      await SpeakerEnrollmentStore.instance.addSample(
        embedding: embedding,
        pcmSamples: samples,
        durationMs: _ownerVoiceprintCaptureMs,
      );
      _ownerVoiceprintEnrolled = SpeakerEnrollmentStore.instance.hasEnrollment;
      _ownerVoiceprintSelectedId =
          SpeakerEnrollmentStore.instance.activeSampleId;
      _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.success;
      _ownerVoiceprintEnrollmentHint =
          '已保存第 ${SpeakerEnrollmentStore.instance.sampleCount} 条声纹';
      _speechText = '主人声纹已保存';
      print(
        '✅ [Speaker] 已保存声纹库 count=${SpeakerEnrollmentStore.instance.sampleCount}',
      );
      notifyListeners();
      if (countBefore == 0 && !_conversationController.isInConversationMode) {
        await _enterConversationAfterVoiceEnrollment();
      }
      _scheduleOwnerVoiceprintResultDismiss();
    } catch (e, st) {
      print('❌ [Speaker] 注册失败: $e\n$st');
      _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.failure;
      _ownerVoiceprintEnrollmentHint = '声纹注册失败，请重试';
      _scheduleOwnerVoiceprintResultDismiss();
    } finally {
      if (arm == _enrollmentGeneration) {
        _enrollmentRecorder = null;
        if (_isWakeUpActive &&
            _sherpaKws != null &&
            !_conversationController.isInConversationMode) {
          try {
            await _sherpaKws!.resume();
          } catch (_) {}
        }
        notifyListeners();
      }
    }
  }

  Future<void> cancelOwnerVoiceprintEnrollment() async {
    _enrollmentGeneration++;
    _ownerVoiceprintResultTimer?.cancel();
    await _enrollmentRecorder?.cancel();
    _enrollmentRecorder = null;
    _ownerVoiceprintUi = OwnerVoiceprintEnrollUi.none;
    _ownerVoiceprintEnrollmentHint = '';
    _ownerVoiceprintCaptureMs = 0;
    notifyListeners();
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
        onSpeechBargeIn: _onSherpaSpeechBargeInWithPcm,
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
      if (_voiceprintGateForBargeIn) {
        print('🎧 [KWS] 主人/声纹打断模式：TTS 期间忽略关键词打断（仅声纹+VAD）');
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
      if (_voiceprintGateForBargeIn) {
        _pauseConversationTimeoutForUserSpeech();
        if (!_ownerVoiceprintEnrolled) return;
        final snap = await _collectBargeInPcmForVerify();
        if (snap == null || snap.isEmpty) {
          _publishVoiceprintVerifyResult(
            const OwnerVoiceprintVerifyResult(
              bestScore: null,
              pass: false,
              valid: false,
              reason: '麦克风流未就绪',
            ),
          );
          return;
        }
        final ok = await _verifyOwnerVoiceprintForBargeIn(snap);
        if (!ok) {
          print('🔐 [Duplex] 人声未通过主人声纹比对');
          return;
        }
        _qwenAsrRecorder?.resetSegmentAfterTtsBargeIn();
        await _conversationController.interruptConversationTtsFromKws(
          ConversationController.kTtsInterruptKeywordOwnerVoiceprint,
        );
        return;
      }
      _qwenAsrRecorder?.resetSegmentAfterTtsBargeIn();
      await _conversationController
          .interruptConversationTtsFromKws('duplex_pcm_vad');
    } finally {
      _ttsBargeInBusy = false;
    }
  }

  /// TTS 期间 Sherpa 能量 VAD：声纹模式下仅主人 embedding 通过才打断。
  void _onSherpaSpeechBargeInWithPcm(Float32List recentPcm) {
    if (_multiPersonPushToTalkMode) return;
    if (!_conversationController.isInConversationMode ||
        !_conversationController.isTtsPlaying) {
      return;
    }

    if (_voiceprintGateForBargeIn) {
      if (!_ownerVoiceprintEnrolled) {
        print('🔐 [VAD] 主人/声纹模式未注册主人，忽略人声');
        return;
      }
      unawaited(_handleOwnerVoiceprintTtsBargeIn(recentPcm));
      return;
    }

    print(
      '🎤 [VAD] 人声活动打断 (voip=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled})',
    );
    unawaited(_handleTtsBargeInKeyword('语音活动'));
  }

  Future<void> _handleOwnerVoiceprintTtsBargeIn(Float32List recentPcm) async {
    if (_ttsBargeInBusy) return;
    _pauseConversationTimeoutForUserSpeech();
    _ttsBargeInBusy = true;
    final kws = _sherpaKws;
    try {
      final snap = kws?.snapshotBargeInRingForVerify() ?? recentPcm;
      if (snap.isEmpty) {
        _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext.bargeIn);
        _publishVoiceprintVerifyResult(
          const OwnerVoiceprintVerifyResult(
            bestScore: null,
            pass: false,
            valid: false,
            reason: '无有效 PCM',
          ),
        );
        kws?.completeBargeInAttempt(interruptGranted: false);
        return;
      }
      _beginVoiceprintVerifyUi(OwnerVoiceprintVerifyContext.bargeIn);
      final result = await OwnerVoiceprintVerifier.instance.verifyOwnerDetailed(
        snap,
        fastBargeIn: true,
      );
      _publishVoiceprintVerifyResult(result);
      final ok = result.pass;
      if (ok) {
        print('🔐 [VAD] 主人声纹通过，允许打断 TTS');
        await _conversationController.interruptConversationTtsFromKws(
          ConversationController.kTtsInterruptKeywordOwnerVoiceprint,
        );
        kws?.completeBargeInAttempt(interruptGranted: true);
      } else {
        print('🔐 [VAD] 本轮人声未通过主人声纹比对');
        kws?.completeBargeInAttempt(interruptGranted: false);
      }
    } finally {
      _ttsBargeInBusy = false;
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
    if (_voiceprintGateForBargeIn && !_ownerVoiceprintEnrolled) {
      print('🎧 [prepareSherpa] 主人/声纹模式未录入：跳过');
      return;
    }
    if (_voiceprintGateForBargeIn) {
      _duplexTtsBargeInEnabled = true;
    }
    // 边播边听：主人/声纹模式必须 TTS 前拉起 Qwen 同麦，否则无法打断。
    if (_duplexTtsBargeInEnabled || _voiceprintGateForBargeIn) {
      if (!_isListening) {
        print('🎧 [prepareSherpa] 边播边听：TTS 前预启动主 ASR');
        await startVoiceRecognition();
      }
      if (_voiceprintGateForBargeIn && _listeningViaQwen) {
        _duplexTtsBargeInEnabled = true;
        _sherpaKws?.setTtsBargeInVadEnabled(false);
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
      _sherpaKws!.setDeferBargeInCooldown(false);
      print('🎧 [prepareSherpa] resume 完成，已开启 TTS 人声 VAD（VOSK 回退路径）');
    } catch (e, st) {
      print('⚠️ [prepareSherpa] 失败: $e\n$st');
    }
  }

  Future<void> _enterConversationAfterVoiceEnrollment() async {
    print('🔐 [Speaker] 声纹录入完成，启动连续对话');
    if (_conversationController.isInConversationMode) {
      if (!_multiPersonPushToTalkMode && !_isListening) {
        unawaited(startVoiceRecognition());
      }
      return;
    }

    _cancelIdleEnvironmentMonitoring();
    _postConversationTimer?.cancel();
    await _stopEnvironmentMonitoring();

    if (Platform.isAndroid) {
      await AndroidVoipAudioRoute.instance.setConversationVoipEnabled(
        true,
        speakerphone: true,
        debugTag: 'voiceprint→conversation',
      );
      _sherpaUseVoipMic = true;
      _sherpaKws?.setAndroidVoipEchoCapture(true);
      if (_sherpaKws != null && _isWakeUpActive) {
        await _sherpaKws!.pause();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await _sherpaKws!.start();
      }
    }

    if (!_multiPersonPushToTalkMode) {
      unawaited(_prewarmAsrAfterWake());
    }

    await _conversationController.enterConversationMode();
    _speechText = '💬 连续对话中';
    notifyListeners();
  }

  Future<void> _onWakeWordEnterConversation() async {
    print("🎤 检测到唤醒词: $_wakePhraseDisplay");
    _wakeWordLock = true;

    final wakeSw = Stopwatch()..start();

    _cancelIdleEnvironmentMonitoring();
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

    // 唤醒命中后并行预热主 ASR，尽量覆盖「首句欢迎语期间用户立刻开口」场景。
    unawaited(_prewarmAsrAfterWake());

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
  void _scheduleIdleEnvironmentMonitoring({required String reason}) {
    if (!DebugRuntimeFlags.enableEnvironmentMonitoring) {
      print(
        '════════ 空闲环境监测未启动（DebugRuntimeFlags.enableEnvironmentMonitoring=false）════════',
      );
      return;
    }
    if (_conversationController.isEnvironmentMonitoring) {
      print("⏰ 空闲环境监测计时器跳过：环境监测已运行 reason=$reason");
      return;
    }
    if (isInConversationMode) {
      print("⏰ 空闲环境监测计时器跳过：连续对话中 reason=$reason");
      return;
    }
    if (_isListening || _isStartingVoiceRecognition || _pttRecordingActive) {
      print(
        "⏰ 空闲环境监测计时器跳过：主麦/按住说话占用中 reason=$reason "
        "listening=$_isListening starting=$_isStartingVoiceRecognition ptt=$_pttRecordingActive",
      );
      return;
    }
    if (_idleTimerScheduled && _idleTimer?.isActive == true) {
      print("⏰ 10秒空闲计时器已在运行，跳过重复启动 reason=$reason");
      return;
    }
    _startIdleTimer(reason: reason);
  }

  void _cancelIdleEnvironmentMonitoring() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleTimerScheduled = false;
  }

  void _startIdleTimer({required String reason}) {
    _cancelIdleEnvironmentMonitoring();
    _idleTimerScheduled = true;
    _idleTimer = Timer(const Duration(seconds: 10), () {
      _idleTimer = null;
      _idleTimerScheduled = false;
      if (!isInConversationMode) {
        print("⏰ 10秒无唤醒词活动，启动环境监测 reason=$reason");
        _startEnvironmentMonitoring();
      } else {
        print("⏰ 10秒空闲计时器触发时仍在连续对话中，跳过环境监测 reason=$reason");
      }
    });
    print("⏰ 10秒空闲计时器已启动 reason=$reason");
  }

  /// 启动退出对话后120秒监测
  void _startPostConversationTimer() {
    _postConversationTimer?.cancel();
    _postConversationTimer = Timer(const Duration(seconds: 120), () {
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
    _cancelIdleEnvironmentMonitoring();
    _conversationController.startEnvironmentMonitoring();

    notifyListeners();
  }

  /// 停止环境监测
  Future<void> _stopEnvironmentMonitoring() async {
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

    _wakeWordHealthCheck =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
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
        _scheduleIdleEnvironmentMonitoring(reason: 'wake_health_ok');
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
        _scheduleIdleEnvironmentMonitoring(reason: 'wake_restart_ok');
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
    _cancelIdleEnvironmentMonitoring();
    _postConversationTimer?.cancel();
    _wakeWordHealthCheck?.cancel();
    _vaRecognitionDisplayTimer?.cancel();
    _vaRecognitionDisplayTimer = null;
    _vaRecognitionDisplayStartedAt = null;

    await _sherpaKws?.stop();
    _sherpaKws = null;

    await _qwenAsrRecorder?.stopWithoutSubmit();
    _qwenAsrRecorder = null;
    await _vaPcmRecorder?.stop(flushRemainder: false);
    _vaPcmRecorder = null;
    await _vaSessionManager?.reset();
    _vaSessionManager = null;
    _listeningViaQwen = false;
    _listeningViaVosk = false;

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
    _cancelIdleEnvironmentMonitoring();
    _postConversationTimer?.cancel();
    _vaRecognitionDisplayTimer?.cancel();
    _vaRecognitionDisplayTimer = null;
    _vaRecognitionDisplayStartedAt = null;
    _isVaRecognitionActive = false;
    await _qwenAsrRecorder?.stopWithoutSubmit();
    _qwenAsrRecorder = null;
    await _vaPcmRecorder?.stop(flushRemainder: false);
    _vaPcmRecorder = null;
    await _vaSessionManager?.reset();
    _vaSessionManager = null;
    _listeningViaQwen = false;
    _listeningViaVosk = false;
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
      if (_conversationController.isInConversationMode &&
          !_conversationController.isProcessingUserInput &&
          !_conversationController.isTtsPlaying) {
        _conversationController.resumeIdleConversationTimeout();
      }
    }));
  }

  /// 启动语音识别监听
  Future<void> startVoiceRecognition() async {
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
      print("🎙️ 语音识别启动中，跳过重复请求");
      return;
    }
    _isStartingVoiceRecognition = true;

    try {
      _resetPendingVaCapture();
      print(
          "🎙️ 启动语音识别 (voipRoute=${AndroidVoipAudioRoute.instance.isVoipRouteEnabled} sherpaVoip=$_sherpaUseVoipMic)");

      _sherpaKws?.setTtsBargeInVadEnabled(false);
      await _sherpaKws?.pause();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final qwenClient = QwenCloudAsrClient();
      print('════════════════ QWEN ASR ENDPOINT ════════════════');
      print('🌐 [QWEN_ASR_BASE_URL] ${qwenClient.baseUrl}');
      print('════════════════════════════════════════════════════');
      print('🌐 [VA_BASE_URL] ${VaServiceConfig.baseUrl}');
      final qwenUp = await qwenClient.healthz();
      print(
          '🩺 [QWEN /healthz] ${qwenUp ? "OK" : "FAIL"} @ ${qwenClient.baseUrl}/healthz');
      if (qwenUp) {
        try {
          _qwenAsrRecorder = QwenStreamingAsrRecorder(
            client: qwenClient,
            onPartialText: _onAsrPartialText,
            onUtteranceFinal: (String t) {
              final s = t.trim();
              final pcmSnap =
                  _qwenAsrRecorder?.snapshotUtterancePcmForVerify() ??
                      _qwenAsrRecorder?.snapshotBargeInRingForVerify();
              ConversationFlowTracer.asr(
                'onUtteranceFinal len=${t.length} trimmedEmpty=${s.isEmpty}',
              );
              _qwenAsrRecorder = null;
              _listeningViaQwen = false;
              _listeningViaVosk = false;
              _isListening = false;
              notifyListeners();
              if (s.isNotEmpty) {
                final vaAudioChunks = _snapshotPendingVaAudioChunks();
                unawaited(_handleFinalizedUserSpeech(
                  s,
                  pcmSnap: pcmSnap,
                  vaAudioChunks: vaAudioChunks,
                ));
              } else {
                _scheduleRestartAsrIfConversationIdle();
              }
              _resetPendingVaCapture();
            },
            onPcmChunkReadyForSidecar: (Uint8List chunk) {
              _bufferPendingVaAudioChunk(chunk);
            },
            androidVoipEchoCapture: _sherpaUseVoipMic,
            isTtsPlaying: () => _conversationController.isTtsPlaying,
            onSpeechDuringTtsBargeIn: () {
              unawaited(_handleDuplexTtsBargeInFromVad());
            },
            onSpeechActivity: _pauseConversationTimeoutForUserSpeech,
          );
          await _qwenAsrRecorder!.start();
          _listeningViaQwen = true;
          _listeningViaVosk = false;
          if (_conversationController.isInConversationMode) {
            _duplexTtsBargeInEnabled = true;
          }
          print('✅ 语音识别：Qwen 云端 ASR（中英混合）');
          _logAsrEngineSelection('Qwen 云端 ASR（healthz 可达，中英混合）');
        } catch (e, st) {
          print('⚠️ Qwen ASR 启动失败，回退 VOSK: $e\n$st');
          _duplexTtsBargeInEnabled = false;
          _qwenAsrRecorder = null;
          await _vaSessionManager?.reset();
          _vaSessionManager = null;
          _listeningViaQwen = false;
          _listeningViaVosk = true;
          _vaPcmRecorder = VaPcmRecorder(
            androidVoipEchoCapture: _sherpaUseVoipMic,
            onChunk: (Uint8List chunk) {
              _bufferPendingVaAudioChunk(chunk);
            },
          );
          try {
            await _vaPcmRecorder!.start();
          } catch (e, st) {
            print('⚠️ [VA][VOSK] 独立录音器启动失败: $e\n$st');
            _vaPcmRecorder = null;
          }
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
        _listeningViaVosk = true;
        _vaPcmRecorder = VaPcmRecorder(
          androidVoipEchoCapture: _sherpaUseVoipMic,
          onChunk: (Uint8List chunk) {
            _bufferPendingVaAudioChunk(chunk);
          },
        );
        try {
          await _vaPcmRecorder!.start();
        } catch (e, st) {
          print('⚠️ [VA][VOSK] 独立录音器启动失败: $e\n$st');
          _vaPcmRecorder = null;
        }
        if (_speechService == null) {
          await _initializeVosk();
        }
        await _speechService!.start();
        _duplexTtsBargeInEnabled = false;
        print('✅ 语音识别：VOSK（备选）');
        _logAsrEngineSelection('VOSK 本地中文（Qwen /healthz 不可达）');
      }

      _isListening = true;
      // 仅在非播报阶段切换到「聆听脸」，避免欢迎语/回复开头先闪可爱02再进说话脸。
      if (_conversationController.isInConversationMode &&
          !_conversationController.isTtsPlaying) {
        _uiModule.showConversationListeningFace();
      }
      notifyListeners();
    } catch (e) {
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
        if (_listeningViaQwen && _qwenAsrRecorder != null) {
          await _qwenAsrRecorder!.stopWithoutSubmit();
          _qwenAsrRecorder = null;
          await _vaPcmRecorder?.stop(flushRemainder: false);
          _vaPcmRecorder = null;
          _listeningViaQwen = false;
          _listeningViaVosk = false;
        } else {
          await _speechService?.stop();
          if (_listeningViaVosk) {
            await _vaPcmRecorder?.stop(flushRemainder: false);
            _vaPcmRecorder = null;
            _listeningViaVosk = false;
          }
        }
        _isListening = false;
      }
      _resetPendingVaCapture();
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
            final normalizedText = text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (_voskFinalResultConsumed) {
              print('ℹ️ [VOSK] 忽略重复 final="$normalizedText"');
              return;
            }
            if (_lastAcceptedVoskFinalText == normalizedText) {
              print('ℹ️ [VOSK] 忽略同文重复 final="$normalizedText"');
              _voskFinalResultConsumed = true;
              return;
            }
            _voskFinalResultConsumed = true;
            _lastAcceptedVoskFinalText = normalizedText;
            _vaSessionManager ??= VaSessionManager();
            _vaSessionManager!.beginSpeechWindowImageBuffering();
            Map<String, dynamic>? vaResult;
            RouterDecision? routerDecision;
            List<Uint8List>? vaAudioChunks;
            if (_listeningViaVosk) {
              try {
                await _vaPcmRecorder?.stop(flushRemainder: true);
                _vaPcmRecorder = null;
                vaAudioChunks = _snapshotPendingVaAudioChunks();
                routerDecision =
                    await _conversationController.previewRouterDecision(text);
                print('🧭 [Router][VOSK后预判] ${routerDecision.rawJson}');
                vaResult = await _runDeferredVaIfNeeded(
                  text,
                  routerDecision,
                  vaAudioChunks,
                );
              } catch (e, st) {
                print('❌ [VA][VOSK] 延后补跑异常: $e\n$st');
              } finally {
                _resetPendingVaCapture();
              }
            }
            print("🎤 语音识别结果: $text");
            await _handleFinalizedUserSpeech(
              text,
              vaResult: vaResult,
              precomputedRouterDecision: routerDecision,
              vaAudioChunks: vaAudioChunks,
            );
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
            _pauseConversationTimeoutForUserSpeech();
            _speechText = text;
            _maybeEnableVaVisionFromTranscript(text);
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
  Future<void> _processUserInput(
    String input, {
    Map<String, dynamic>? vaResult,
    RouterDecision? precomputedRouterDecision,
  }) async {
    if (input.isEmpty) return;

    _speechText = input;
    notifyListeners();

    // 边播边听：连续对话且 Qwen 已启用时，主 ASR 在 TTS 前保持/预拉起，不在此处停麦，
    // 避免「Sherpa 打断 → 再切 Qwen」丢前几个字；否则沿用停麦再处理。
    if (_conversationController.isInConversationMode) {
      // 复杂任务执行中保持 ASR 常开，允许新语音随时打断当前任务。
      final keepAsrForInterrupt =
          _conversationController.isComplexTaskExecuting ||
              _ownerMode ||
              _ownerVoiceprintBargeInMode ||
              _duplexTtsBargeInEnabled;
      if (!_duplexTtsBargeInEnabled && !keepAsrForInterrupt) {
        await stopVoiceRecognition(resumeSherpaKws: false);
      }
    } else {
      await stopVoiceRecognition(resumeSherpaKws: false);
    }

    await _conversationController.processUserInput(
      input,
      vaResult: vaResult,
      precomputedRouterDecision: precomputedRouterDecision,
    );
  }

  /// 兼容性方法：外部调用
  Future<void> processUserInput(String input) async {
    await _processUserInput(input);
  }

  void _maybeEnableVaVisionFromTranscript(String text) {
    final manager = _vaSessionManager;
    if (manager == null || manager.sessionId == null) return;
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    final hit =
        _vaVisionKeywords.any((keyword) => normalized.contains(keyword));
    if (!hit) return;
    print('🎯 [VA] 命中视觉增强关键词 transcript="$normalized"');
    manager.enableVisionEnhancement();
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
