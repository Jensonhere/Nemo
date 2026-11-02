import 'dart:async';

import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart'
    show LinearMotionEndKind, MotionInterruptedEvent, MyBluetoothService;
import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/desktop_object_detector.dart';
import 'package:voicegpt/core/services/in_app_log_console.dart';
import 'package:voicegpt/core/services/voice_tts_service.dart';

enum SnapshotTargetType {
  none,
  face,
  person,
}

enum EnvV1ObjectPolicy {
  officeInteractable,
  toyLike,
  largeBackground,
  officeImpossible,
  officeAnimal,
  unknown,
}

enum _ChassisSensorIncidentV1 {
  none,
  frontObstacle,
  rearObstacle,
  frontCliff,
  rearCliff,
  unknown,
}

class SnapshotAlignStatus {
  SnapshotAlignStatus._();

  static const String verifiedFaceCentered = 'verified_face_centered';
  static const String verifiedFaceAcceptable = 'verified_face_acceptable';
  static const String verifiedPersonAcceptable = 'verified_person_acceptable';
  static const String stillOffcenter = 'still_offcenter';
  static const String targetLostAfterNudge = 'target_lost_after_nudge';
  static const String noTarget = 'no_target';
}

class SnapshotAlignResult {
  const SnapshotAlignResult({
    required this.canProceed,
    required this.finalAlignmentStatus,
    required this.targetType,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.confidence = 0,
    this.areaRatio = 0,
    this.humanObservation,
    this.faceObservation,
    this.imagePath,
  });

  final bool canProceed;
  final String finalAlignmentStatus;
  final SnapshotTargetType targetType;
  final double centerX;
  final double centerY;
  final double confidence;
  final double areaRatio;
  final HumanObservation? humanObservation;
  final FaceObservation? faceObservation;
  final String? imagePath;

  SnapshotAlignResult copyWith({
    bool? canProceed,
    String? finalAlignmentStatus,
    SnapshotTargetType? targetType,
    double? centerX,
    double? centerY,
    double? confidence,
    double? areaRatio,
    HumanObservation? humanObservation,
    FaceObservation? faceObservation,
    String? imagePath,
  }) {
    return SnapshotAlignResult(
      canProceed: canProceed ?? this.canProceed,
      finalAlignmentStatus: finalAlignmentStatus ?? this.finalAlignmentStatus,
      targetType: targetType ?? this.targetType,
      centerX: centerX ?? this.centerX,
      centerY: centerY ?? this.centerY,
      confidence: confidence ?? this.confidence,
      areaRatio: areaRatio ?? this.areaRatio,
      humanObservation: humanObservation ?? this.humanObservation,
      faceObservation: faceObservation ?? this.faceObservation,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  static SnapshotAlignResult noTarget({
    HumanObservation? humanObservation,
    String? imagePath,
  }) {
    return SnapshotAlignResult(
      canProceed: false,
      finalAlignmentStatus: SnapshotAlignStatus.noTarget,
      targetType: SnapshotTargetType.none,
      humanObservation: humanObservation,
      imagePath: imagePath,
    );
  }
}

class _ObjectReturnLocalScanStepV1 {
  const _ObjectReturnLocalScanStepV1({
    required this.command,
    required this.turn,
    required this.angleDeg,
    this.returnCenter = false,
  });

  final String command;
  final String turn;
  final int angleDeg;
  final bool returnCenter;
}

class EnvironMonitorModule {
  static const bool _invertOwnerTurnDirection = false;
  static const bool _enableStartSearchSpeechAfterPreLookFail = true;
  static const bool _enableObjectLookAroundAfterOwnerFoundV1 = true;
  static const bool _enableWeakObjectSpeechV1 = true;
  static const bool _useDebugShortObjectLookDelayV1 = true;
  static const bool _enableObjectReturnFullCircleFallbackV1 = true;
  static const int _preLookAroundSweepAngleDeg = 18;
  static const bool _enableObjectForwardProbeV1 = true;
  static const int _objectProbeMaxForwardMmV1 = 80;
  static const int _objectProbeDefaultForwardMmV1 = 60;
  static const int _objectProbeForwardMmV1 = _objectProbeDefaultForwardMmV1;
  static const int _objectProbeSettleMsV1 = 300;
  static const int _objectFoundPauseBeforeSpeechMsV1 = 500;
  static const int _objectFoundPauseAfterSpeechMsV1 = 1500;
  static const int _objectLookProbeCountV1 = 2;
  static const int _objectProbeMaxCountV1 = _objectLookProbeCountV1;
  static const int _objectGenericSpeechMaxPerSessionV1 = 1;
  static const int _objectPerProbeMaxSpeechCountV1 = 1;
  static const bool _enableObjectMicroApproachOnFoundV1 = false;
  static const int _objectMicroApproachMmV1 = 25;
  static const int _objectMicroApproachMaxMmV1 = 30;
  static const int _objectMicroApproachSettleMsV1 = 300;
  static const int _frontCliffBtAutoBackoffMmV1 =
      MyBluetoothService.kFrontSafetyRecoverDistanceMm;
  static const int _frontCliffSupplementalBackoffLargeMmV1 = 50;
  static const int _frontCliffBackoffMmV1 =
      _frontCliffSupplementalBackoffLargeMmV1;
  static const int _frontCliffRecoverSettleMsV1 = 500;
  static const int _frontCliffResumeTurnCapDegV1 = 8;
  static const int _frontCliffResumeTurnMinDegV1 = 3;
  static const int _frontCliffMaxRepeatedByPhaseV1 = 2;
  static const Duration _edgeCautiousDurationV1 = Duration(seconds: 60);
  static const int _edgeCautiousTurnLargeCapDegV1 = 5;
  static const int _edgeCautiousTurnSmallCapDegV1 = 3;
  static const int _edgeCautiousLinearCapMmV1 = 10;
  static const int _objectMinProbeCountBeforeEarlyStopV1 = 2;
  static const int _objectReturnOwnerReacquireMaxAttemptsV1 = 2;
  static const int _objectReturnResearchLocalStepDegV1 = 20;
  static const int _objectReturnResearchWideStepDegV1 = 30;
  static const int _objectReturnResearchWideHalfRoundsV1 = 6;
  static const int _objectReturnResearchWideMaxRoundsV1 =
      _enableObjectReturnFullCircleFallbackV1
          ? _objectReturnResearchWideHalfRoundsV1 * 2
          : _objectReturnResearchWideHalfRoundsV1;
  static const int _objectReturnResearchWideMaxAccumulatedDegV1 =
      _objectReturnResearchWideMaxRoundsV1 * _objectReturnResearchWideStepDegV1;
  static const int _objectReturnFullCircleStepDegV1 = 30;
  static const int _objectReturnFullCircleMaxRoundsV1 = 12;
  static const int _objectReturnFullCircleSettleMsV1 = 300;
  static const int _objectReturnTrackHardAngleDegV1 = 6;
  static const int _objectReturnTrackSoftAngleDegV1 = 3;
  static const int _objectReturnCandidateLocalLeftDegV1 = 8;
  static const int _objectReturnCandidateLocalRightDegV1 = 16;
  static const bool _enableIdleRecenterAfterObjectReturnV1 = true;
  static const int _idleRecenterIntervalMsV1 = 800;
  static const int _idleRecenterSettleMsV1 = 250;
  static const int _idleRecenterMaxNudgesPerSessionV1 = 3;
  static const double _idleRecenterDeadZoneV1 = 0.06;
  static const double _idleRecenterSmallThresholdV1 = 0.15;
  static const int _idleRecenterSmallAngleDegV1 = 3;
  static const int _idleRecenterLargeAngleDegV1 = 6;
  static const int _idleRecenterStableOffsetHitsV1 = 2;
  static const double _reliableHumanConfidence = 0.50;
  static const double _reliableHumanMinAreaRatio = 0.012;
  static const double _ownerTrackDeadZoneV1 = 0.08;
  static const double _ownerTrackSoftZoneV1 = 0.18;
  static const int _ownerTrackMaxLoopsV1 = 4;
  static const int _finalFaceCenterMaxCorrectionRoundsV1 = 2;
  static const double _verifiedFaceCenteredDx = 0.045;
  static const double _verifiedFaceAcceptableDx = 0.10;
  static const double _verifiedPersonAcceptableDx = 0.16;
  static const Duration _realtimeHumanFreshnessV1 = Duration(
    milliseconds: 800,
  );
  static const Duration _ownerTrackSettleV1 = Duration(milliseconds: 180);
  static const Duration _finalStableVerifySettleV1 =
      Duration(milliseconds: 400);
  static const Duration _settleDelay = Duration(milliseconds: 220);
  static const Duration _shortSettleDelay = Duration(milliseconds: 160);
  static const Duration _quietCompanionInterval = Duration(seconds: 45);
  static const Duration _objectLookAroundDelayV1 =
      _useDebugShortObjectLookDelayV1
          ? Duration(seconds: 10)
          : Duration(seconds: 30);
  static const Duration _objectLookAroundPreStartStopSettleV1 =
      Duration(milliseconds: 200);
  static const Duration _ownerReplyWaitTimeoutV1 = Duration(seconds: 8);
  static const Duration _ownerReplyWaitPollIntervalV1 =
      Duration(milliseconds: 250);
  static const double _objectRealtimeCandidateScoreV1 = 0.18;
  static const double _objectRealtimeCandidateAreaV1 = 0.003;
  static const double _objectRealtimeSpeechScoreV1 = 0.30;
  static const double _objectRealtimeSpeechAreaV1 = 0.006;
  static const double _objectSmallAreaMinV1 = 0.003;
  static const double _objectGenericVisualPresenceScoreV1 = 0.25;
  static const double _objectGenericVisualPresenceMinAreaV1 = 0.003;
  static const double _objectGenericVisualPresenceMaxAreaV1 = 0.60;
  static const double _objectSpeechFallbackConfidenceV1 =
      _objectRealtimeSpeechScoreV1;
  static const double _realtimeObjectCandidateConfidenceV1 =
      _objectRealtimeCandidateScoreV1;
  static const double _realtimeObjectCandidateMinAreaRatioV1 =
      _objectRealtimeCandidateAreaV1;
  static const double _realtimeObjectCandidateMaxAreaRatioV1 = 0.60;
  static const int _objectProbeRealtimeCollectMsV1 = 1200;
  static const int _objectRealtimeStableMinHitsV1 = 3;
  static const int _objectRealtimeStableWindowMsV1 = 1200;
  static const int _objectWeakFallbackSilentObserveMsV1 = 800;
  static const Duration _realtimeObjectProbeWaitV1 =
      Duration(milliseconds: _objectProbeRealtimeCollectMsV1);
  static const Set<String> _officeInteractableObjectLabelsV1 = {
    'bottle',
    'wine glass',
    'cup',
    'bowl',
    'book',
    'laptop',
    'mouse',
    'keyboard',
    'cell phone',
    'remote',
    'backpack',
    'handbag',
    'suitcase',
    'clock',
    'vase',
    'potted plant',
    'scissors',
    'toothbrush',
    'apple',
    'banana',
    'orange',
    'teddy bear',
  };
  static const Set<String> _toyLikeObjectLabelsV1 = {
    'teddy bear',
    'sports ball',
    'frisbee',
    'toy',
  };
  static const Set<String> _officeLargeBackgroundLabelsV1 = {
    'tv',
    'chair',
    'couch',
    'dining table',
    'bench',
  };
  static const Set<String> _officeImpossibleObjectLabelsV1 = {
    'airplane',
    'bus',
    'train',
    'truck',
    'boat',
    'motorcycle',
    'bicycle',
    'car',
    'traffic light',
    'fire hydrant',
    'stop sign',
    'parking meter',
    'skis',
    'snowboard',
    'surfboard',
    'skateboard',
    'baseball bat',
    'baseball glove',
    'kite',
    'tennis racket',
    'toilet',
    'sink',
    'refrigerator',
    'oven',
    'microwave',
    'toaster',
    'horse',
    'sheep',
    'cow',
    'elephant',
    'bear',
    'zebra',
    'giraffe',
  };
  static const Set<String> _officeAnimalLabelsV1 = {
    'bird',
    'cat',
    'dog',
  };
  static const List<_ObjectProbePlanV1> _objectProbePlansV1 = [
    _ObjectProbePlanV1(
      turnCommand: '右转',
      turnLabel: 'right',
      turnAngleDeg: 30,
      turnBackCommand: '左转',
    ),
    _ObjectProbePlanV1(
      turnCommand: '左转',
      turnLabel: 'left',
      turnAngleDeg: 30,
      turnBackCommand: '右转',
    ),
  ];

  MyBluetoothService? _bluetoothService;
  VoiceTtsService? _ttsService;
  UIAnimationModule? _uiModule;
  CameraService? _cameraService;

  Timer? _statePollTimer;
  Timer? _quietCompanionTimer;
  Timer? _pendingObjectLookAroundTimerV1;
  Timer? _idleRecenterTimerV1;
  StreamSubscription<List<dynamic>>? _envRealtimeHumanSubscription;
  StreamSubscription<List<dynamic>>? _envRealtimeObjectSubscription;

  bool _isEnvironmentMonitoring = false;
  bool _isAnswering = false;
  bool _isTtsPlaying = false;
  bool _degradedToVoiceExpressionOnly = false;
  bool _envRealtimeHumanRunning = false;
  bool _envRealtimeObjectRunning = false;
  int _objectGenericSpeechCountV1 = 0;
  bool _quietCompanionActiveV1 = false;
  bool _ownerAlignmentActiveV1 = false;
  bool _envV1MotionCommandInFlight = false;
  bool _objectLookAroundExecutedV1 = false;
  bool _objectLookAroundRunningV1 = false;
  bool _envV1EdgeCautiousMode = false;
  String? _pendingObjectLookAroundReasonV1;
  String? _pendingObjectLookAroundOwnerStatusV1;
  bool _objectReturnSafeStopWaitingV1 = false;
  bool _idleRecenterActiveV1 = false;
  bool _idleRecenterNudgeInFlightV1 = false;
  int _idleRecenterNudgeCountV1 = 0;
  int _idleRecenterOffsetHitCountV1 = 0;
  String? _idleRecenterLastDirectionV1;
  String? _objectReturnPendingSafeStopReasonV1;
  String? _lastFrontCliffRecoveredTurnPhaseV1;
  _ChassisSensorIncidentV1 _lastTurnSensorIncidentV1 =
      _ChassisSensorIncidentV1.none;
  String? _lastTurnSensorIncidentPhaseV1;
  DateTime? _envV1EdgeCautiousUntil;
  final Map<String, int> _frontCliffInterruptsByPhaseV1 = <String, int>{};
  HumanObservation? _recentRealtimeHuman;
  DateTime? _recentRealtimeHumanAt;
  DetectedDesktopObject? _recentRealtimeObject;
  DetectedDesktopObject? _recentIgnoredRealtimeObject;
  final List<_RealtimeObjectSampleV1> _recentRealtimeObjectSamplesV1 =
      <_RealtimeObjectSampleV1>[];
  DateTime? _ownerFoundAtV1;
  String _monitorStatus = '环境监测已关闭';
  bool Function()? _isAnsweringProvider;
  bool Function()? _isTtsPlayingProvider;

  void setBluetoothService(MyBluetoothService bluetoothService) {
    _bluetoothService = bluetoothService;
    _envLogV1('🔗 环境监测模块：蓝牙服务已设置');
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
    _isAnsweringProvider = isAnswering;
    _isTtsPlayingProvider = isTtsPlaying;
    _cancelStatePollTimer();
  }

  void startEnvironmentMonitoring() {
    if (_isEnvironmentMonitoring) {
      _envLogV1('[ENV_V1] already_running status=$_monitorStatus');
      return;
    }

    _resetObjectLookAroundSessionV1();
    _restartStatePollTimer();
    _isEnvironmentMonitoring = true;
    _degradedToVoiceExpressionOnly = false;
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
    _objectReturnSafeStopWaitingV1 = false;
    _objectReturnPendingSafeStopReasonV1 = null;
    _lastFrontCliffRecoveredTurnPhaseV1 = null;
    _lastTurnSensorIncidentV1 = _ChassisSensorIncidentV1.none;
    _lastTurnSensorIncidentPhaseV1 = null;
    _frontCliffInterruptsByPhaseV1.clear();
    _monitorStatus = '环境监测 V1 启动';
    _quietCompanionTimer?.cancel();
    _quietCompanionTimer = null;
    unawaited(_runEnvironmentMonitorV1());
  }

  void stopEnvironmentMonitoring() {
    unawaited(_cleanupEnvironmentMonitoring());
  }

  bool get isMonitoring => _isEnvironmentMonitoring;
  String get monitorStatus => _monitorStatus;

  void _envLogV1(String message) {
    print(message);
    InAppLogConsole.instance.add(message);
  }

  Future<void> _runEnvironmentMonitorV1() async {
    _envLogV1('[ENV_V1] start');
    _uiModule?.setProgramMode(ProgramMode.environmentCheck);
    _ownerAlignmentActiveV1 = true;

    try {
      await _ensureCameraService();
      await _startRealtimeHumanDetectionForEnvV1();
      if (!_isEnvironmentMonitoring) return;

      await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');
      _envLogV1('[ENV_V1] start_owner_search_speech');
      await speakWithInterruptProtection('主人，你在这里吗？');
      if (!_isEnvironmentMonitoring) return;

      final preLookFound = await _runPreLookAroundOwnerV1();
      final HumanObservation? found;
      if (preLookFound != null) {
        _envLogV1('[ENV_V1] prelook_found skip_start_search_speech');
        found = preLookFound;
      } else {
        _envLogV1(
          '[ENV_V1] prelook_no_target '
          'start_search_speech=$_enableStartSearchSpeechAfterPreLookFail',
        );
        if (_enableStartSearchSpeechAfterPreLookFail) {
          await speakWithInterruptProtection('主人，我开始找你了。');
        }
        found = await _runSearchOwnerV1();
      }
      if (!_isEnvironmentMonitoring) return;

      final tracked = found == null ? null : await _runTrackOwnerV1(found);
      if (!_isEnvironmentMonitoring) return;

      final confirmed = tracked == null
          ? SnapshotAlignResult.noTarget()
          : await _runConfirmOwnerBySnapshotV1(tracked);
      if (!_isEnvironmentMonitoring) return;

      var finalResult = await _runFinalFaceCenteringV1(confirmed);
      if (!_isEnvironmentMonitoring) return;
      finalResult = await _runStableVerifyIfCenteredV1(finalResult);
      if (!_isEnvironmentMonitoring) return;

      if (finalResult.finalAlignmentStatus ==
          SnapshotAlignStatus.stillOffcenter) {
        finalResult = await _runSilentReacquireAfterFinalOffcenterV1(
          finalResult,
        );
        if (!_isEnvironmentMonitoring) return;
        finalResult = await _runStableVerifyIfCenteredV1(finalResult);
      }
      if (!_isEnvironmentMonitoring) return;

      await _runInteractOwnerV1(finalResult);
      _ownerAlignmentActiveV1 = false;
      if (!_isEnvironmentMonitoring) return;
    } catch (e, st) {
      _monitorStatus = '环境监测 V1 异常: $e';
      _envLogV1('[ENV_V1] error=$e\n$st');
      await _degradeToVoiceExpressionOnly('exception');
    } finally {
      _ownerAlignmentActiveV1 = false;
      await _stopRealtimeHumanDetectionForEnvV1();
      await _disposeCameraService();
      await _enterQuietCompanionModeV1();
    }
  }

  Future<HumanObservation?> _runSearchOwnerV1() async {
    _envLogV1('[ENV_V1_SEARCH] start');
    _monitorStatus = 'SEARCH: 原地找人';

    final initial = await _detectHumanObservationSafe(phase: 'search_initial');
    _envLogV1(
      '[ENV_V1_SEARCH] initial_check hasHuman=${initial.hasHuman} '
      'conf=${_f(initial.confidence)} area=${_f(initial.areaRatio)} '
      'cx=${_f(initial.centerX)}',
    );
    if (_isReliableHumanObservation(initial)) {
      _envLogV1('[ENV_V1_SEARCH] confirmed');
      return initial;
    }

    const sweepPlan = <_TurnStep>[
      _TurnStep('右转', 15),
      _TurnStep('右转', 15),
      _TurnStep('右转', 15),
      _TurnStep('右转', 15),
      _TurnStep('右转', 15),
      _TurnStep('右转', 15),
    ];

    for (final step in sweepPlan) {
      if (!_isEnvironmentMonitoring) return null;
      final tag = step.command == '左转' ? 'turn_left' : 'turn_right';
      _envLogV1('[ENV_V1_SEARCH] $tag angle=${step.angleDeg}');
      final moved = await _safeSendCommandV1(step.command, step.angleDeg);
      if (!moved) {
        _envLogV1(
            '[ENV_V1_SEARCH] abort reason=bluetooth_disconnected/write_failed');
        return null;
      }

      await _safeSendCommandV1('停止', 0);
      await Future<void>.delayed(_settleDelay);

      final candidate = await _detectHumanObservationSafe(
        phase: 'search_sweep',
      );
      _envLogV1(
        '[ENV_V1_SEARCH] candidate conf=${_f(candidate.confidence)} '
        'area=${_f(candidate.areaRatio)} cx=${_f(candidate.centerX)}',
      );
      if (_isReliableHumanObservation(candidate)) {
        _envLogV1('[ENV_V1_SEARCH] confirmed');
        return candidate;
      }
    }

    await _safeSendCommandV1('停止', 0);
    _envLogV1('[ENV_V1_SEARCH] no_target');
    return null;
  }

  Future<HumanObservation?> _runPreLookAroundOwnerV1() async {
    _envLogV1('[ENV_V1_PRELOOK] start');
    _monitorStatus = 'PRELOOK: 原地张望';

    final front = await _detectHumanObservationSafe(phase: 'prelook_front');
    _envLogV1(
      '[ENV_V1_PRELOOK] front_check hasHuman=${front.hasHuman} '
      'conf=${_f(front.confidence)} area=${_f(front.areaRatio)} '
      'cx=${_f(front.centerX)}',
    );
    if (_isReliableHumanObservation(front)) {
      _envLogV1('[ENV_V1_PRELOOK] found phase=front');
      return front;
    }

    final left = await _turnPreLookAndDetectOwnerV1(
      command: '左转',
      angleDeg: _preLookAroundSweepAngleDeg,
      phase: 'left',
    );
    if (left != null) return left;

    final right = await _turnPreLookAndDetectOwnerV1(
      command: '右转',
      angleDeg: _preLookAroundSweepAngleDeg * 2,
      phase: 'right',
    );
    if (right != null) return right;

    final center = await _turnPreLookAndDetectOwnerV1(
      command: '左转',
      angleDeg: _preLookAroundSweepAngleDeg,
      phase: 'center',
    );
    if (center != null) return center;

    _envLogV1('[ENV_V1_PRELOOK] no_target');
    return null;
  }

  Future<HumanObservation?> _turnPreLookAndDetectOwnerV1({
    required String command,
    required int angleDeg,
    required String phase,
  }) async {
    final tag = command == '左转' ? 'turn_left' : 'turn_right';
    _envLogV1('[ENV_V1_PRELOOK] $tag angle=$angleDeg');

    final moved = await _safeSendCommandV1WithPhase(
      command,
      angleDeg,
      phase: 'prelook_$phase',
    );
    if (!moved) {
      _envLogV1('[ENV_V1_PRELOOK] no_target');
      return null;
    }
    if (_consumeFrontCliffTurnRecoveryV1('prelook_$phase')) {
      _envLogV1('[ENV_V1_PRELOOK] resume_after_cliff phase=prelook_$phase');
    }

    await _safeSendCommandV1('停止', 0);
    await Future<void>.delayed(_settleDelay);

    final candidate = await _detectHumanObservationSafe(
      phase: 'prelook_$phase',
    );
    _envLogV1(
      '[ENV_V1_PRELOOK] candidate phase=$phase '
      'conf=${_f(candidate.confidence)} area=${_f(candidate.areaRatio)} '
      'cx=${_f(candidate.centerX)}',
    );
    if (_isReliableHumanObservation(candidate)) {
      _envLogV1('[ENV_V1_PRELOOK] found phase=$phase');
      return candidate;
    }
    return null;
  }

  Future<HumanObservation> _runTrackOwnerV1(
    HumanObservation initial, {
    int maxLoops = _ownerTrackMaxLoopsV1,
    bool objectReturnTrack = false,
  }) async {
    _envLogV1(
      '[ENV_V1_TRACK] start cx=${_f(initial.centerX)} '
      'dx=${_f(initial.centerX - 0.5)} '
      'objectReturnTrack=$objectReturnTrack',
    );
    _monitorStatus = 'TRACK: 人体粗回正';

    HumanObservation? current = initial;
    var lastReliable = initial;

    for (var loop = 0; loop < maxLoops; loop++) {
      var source = loop == 0 ? 'initial' : 'previous';
      final realtime = _getFreshRealtimeHumanV1();
      if (realtime != null) {
        current = realtime;
        source = 'realtime';
      } else if (current == null || !_isReliableHumanObservation(current)) {
        current = await _detectHumanObservationSafe(
          phase: 'track_loop_$loop',
          allowSnapshotFallback: !objectReturnTrack,
        );
        source = objectReturnTrack
            ? 'realtime_required_no_snapshot_fallback'
            : 'realtime_or_snapshot_fallback';
      }

      if (!_isReliableHumanObservation(current)) {
        _envLogV1('[ENV_V1_TRACK] loop=$loop no reliable human, break');
        break;
      }

      lastReliable = current;
      final dx = current.centerX - 0.5;
      final absDx = dx.abs();
      _envLogV1(
        '[ENV_V1_TRACK] loop=$loop source=$source '
        'cx=${_f(current.centerX)} dx=${_f(dx)} absDx=${_f(absDx)}',
      );

      if (absDx <= _ownerTrackDeadZoneV1) {
        _envLogV1(
          '[ENV_V1_TRACK] loop=$loop centered_by_human '
          'absDx=${_f(absDx)}',
        );
        return current;
      }

      final angle = objectReturnTrack
          ? (absDx > _ownerTrackSoftZoneV1
              ? _objectReturnTrackHardAngleDegV1
              : _objectReturnTrackSoftAngleDegV1)
          : (absDx > _ownerTrackSoftZoneV1 ? 12 : 6);
      final direction = _turnDirectionForOwnerDx(dx);
      _envLogV1(
        '[ENV_V1_TRACK] loop=$loop recenter '
        'direction=$direction angle=$angle',
      );

      final moved = await _safeSendCommandV1WithPhase(
        direction,
        angle,
        phase: 'track_recenter',
      );
      if (!moved) {
        _envLogV1('[ENV_V1_TRACK] loop=$loop recenter_failed reason=turn');
        return lastReliable;
      }
      if (_consumeFrontCliffTurnRecoveryV1('track_recenter')) {
        _envLogV1('[ENV_V1_TRACK] resume_after_cliff phase=track_recenter');
      }

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _envLogV1('[ENV_V1_TRACK] loop=$loop recenter_failed reason=stop');
        return lastReliable;
      }
      await Future<void>.delayed(_ownerTrackSettleV1);
      current = null;
    }

    _envLogV1('[ENV_V1_TRACK] finished max_loops_or_no_target');
    return lastReliable;
  }

  Future<SnapshotAlignResult> _runConfirmOwnerBySnapshotV1(
    HumanObservation tracked,
  ) async {
    _monitorStatus = 'CONFIRM: snapshot 视觉确认';
    _envLogV1('[ENV_V1_CONFIRM] capture start');
    await _safeSendCommandV1('停止', 0);
    await Future<void>.delayed(_settleDelay);
    return _captureSnapshotAlignResultV1(tracked);
  }

  Future<SnapshotAlignResult> _captureSnapshotAlignResultV1(
    HumanObservation? tracked,
  ) async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1('[ENV_V1_CONFIRM] target=none reason=camera_unavailable');
        return SnapshotAlignResult.noTarget(humanObservation: tracked);
      }

      final imagePath = await camera.captureImage();
      _envLogV1('[ENV_V1_CONFIRM] imagePath=$imagePath');

      final face = await camera.detectFaceObservationFromImagePath(imagePath);
      _envLogV1(
        '[ENV_V1_CONFIRM] face hasFace=${face.hasFace} '
        'conf=${_f(face.confidence)} cx=${_f(face.centerX)}',
      );

      final person =
          await camera.detectHumanObservationFromImagePath(imagePath);
      _envLogV1(
        '[ENV_V1_CONFIRM] person hasHuman=${person.hasHuman} '
        'conf=${_f(person.confidence)} area=${_f(person.areaRatio)} '
        'cx=${_f(person.centerX)}',
      );

      if (face.hasFace) {
        _envLogV1('[ENV_V1_CONFIRM] target=face');
        return SnapshotAlignResult(
          canProceed: true,
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
          targetType: SnapshotTargetType.face,
          centerX: face.centerX,
          centerY: face.centerY,
          confidence: face.confidence,
          areaRatio: face.areaRatio,
          humanObservation: person.hasHuman ? person : tracked,
          faceObservation: face,
          imagePath: imagePath,
        );
      }

      if (_isReliableHumanObservation(person)) {
        _envLogV1('[ENV_V1_CONFIRM] target=person');
        return SnapshotAlignResult(
          canProceed: true,
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
          targetType: SnapshotTargetType.person,
          centerX: person.centerX,
          centerY: person.centerY,
          confidence: person.confidence,
          areaRatio: person.areaRatio,
          humanObservation: person,
          imagePath: imagePath,
        );
      }

      _envLogV1('[ENV_V1_CONFIRM] target=none');
      return SnapshotAlignResult.noTarget(
        humanObservation: tracked,
        imagePath: imagePath,
      );
    } catch (e) {
      _envLogV1('[ENV_V1_CONFIRM] target=none error=$e');
      return SnapshotAlignResult.noTarget(humanObservation: tracked);
    }
  }

  Future<SnapshotAlignResult> _runFinalFaceCenteringV1(
    SnapshotAlignResult result,
  ) async {
    _envLogV1(
      '[ENV_V1_FINAL_CENTER] start target=${result.targetType.name} '
      'cx=${_f(result.centerX)} dx=${_f(result.centerX - 0.5)}',
    );
    _monitorStatus = 'FINAL_CENTER: snapshot 居中确认';

    var current = result;
    var overshotLastNudge = false;
    for (var round = 0;
        round <= _finalFaceCenterMaxCorrectionRoundsV1;
        round++) {
      final target = current.targetType.name;
      final dx = current.centerX - 0.5;
      final absDx = dx.abs();
      _envLogV1(
        '[ENV_V1_FINAL_CENTER] round=$round target=$target '
        'cx=${_f(current.centerX)} dx=${_f(dx)}',
      );

      if (current.targetType == SnapshotTargetType.none) {
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] decision action=no_target '
          'direction=none angle=0',
        );
        _envLogV1(
            '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.noTarget}');
        return current.copyWith(
          canProceed: false,
          finalAlignmentStatus: SnapshotAlignStatus.noTarget,
        );
      }

      if (current.targetType == SnapshotTargetType.person) {
        final status = absDx <= _verifiedPersonAcceptableDx
            ? SnapshotAlignStatus.verifiedPersonAcceptable
            : SnapshotAlignStatus.stillOffcenter;
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] decision action=person_only '
          'direction=none angle=0',
        );
        _envLogV1('[ENV_V1_FINAL_CENTER] result=$status');
        return current.copyWith(finalAlignmentStatus: status);
      }

      final faceDx =
          (current.faceObservation?.centerX ?? current.centerX) - 0.5;
      final absFaceDx = faceDx.abs();
      _envLogV1(
        '[ENV_V1_FINAL_CENTER] round=$round faceDx=${_f(faceDx)} '
        'absDx=${_f(absFaceDx)}',
      );

      if (absFaceDx <= _verifiedFaceCenteredDx) {
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] decision action=centered '
          'direction=none angle=0',
        );
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.verifiedFaceCentered}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.verifiedFaceCentered,
        );
      }

      if (absFaceDx <= _verifiedFaceAcceptableDx) {
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] decision action=acceptable '
          'direction=none angle=0',
        );
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.verifiedFaceAcceptable}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.verifiedFaceAcceptable,
        );
      }

      if (round >= _finalFaceCenterMaxCorrectionRoundsV1) {
        final updated = _classifyAfterNudge(current);
        _envLogV1('[ENV_V1_FINAL_CENTER] result=$updated');
        return current.copyWith(finalAlignmentStatus: updated);
      }

      final angle = _finalFaceNudgeAngleV1(
        absFaceDx,
        overshotLastNudge: overshotLastNudge,
      );
      final direction = _turnDirectionForOwnerDx(faceDx);
      _envLogV1(
        '[ENV_V1_FINAL_CENTER] round=$round recenter '
        'direction=$direction angle=$angle',
      );

      final moved = await _safeSendCommandV1WithPhase(
        direction,
        angle,
        phase: 'final_center_recenter',
      );
      if (!moved) {
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] result='
          '${SnapshotAlignStatus.stillOffcenter}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
        );
      }

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _envLogV1(
          '[ENV_V1_FINAL_CENTER] result='
          '${SnapshotAlignStatus.stillOffcenter}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
        );
      }
      await Future<void>.delayed(_settleDelay);

      final beforeNudgeDx = faceDx;
      final beforeNudgeAbsDx = absFaceDx;
      current = await _captureSnapshotAlignResultV1(
        current.humanObservation ?? result.humanObservation,
      );
      _envLogV1(
        '[ENV_V1_FINAL_CENTER] verify_after_nudge '
        'hasFace=${current.faceObservation?.hasFace ?? false} '
        'faceCx=${_f(current.faceObservation?.centerX ?? 0.5)} '
        'hasHuman=${current.humanObservation?.hasHuman ?? false} '
        'personCx=${_f(current.humanObservation?.centerX ?? 0.5)}',
      );
      if (current.targetType == SnapshotTargetType.face) {
        final afterNudgeDx =
            (current.faceObservation?.centerX ?? current.centerX) - 0.5;
        final signFlipped = (beforeNudgeDx > 0 && afterNudgeDx < 0) ||
            (beforeNudgeDx < 0 && afterNudgeDx > 0);
        final didNotImprove = afterNudgeDx.abs() >= beforeNudgeAbsDx;
        overshotLastNudge = signFlipped && didNotImprove;
        if (overshotLastNudge) {
          _envLogV1(
            '[ENV_V1_FINAL_CENTER] overshoot_detected '
            'beforeDx=${_f(beforeNudgeDx)} '
            'afterDx=${_f(afterNudgeDx)} next_angle_limited=true',
          );
        }
      } else {
        overshotLastNudge = false;
      }
    }

    final updated = _classifyAfterNudge(current);
    _envLogV1('[ENV_V1_FINAL_CENTER] result=$updated');
    return current.copyWith(finalAlignmentStatus: updated);
  }

  Future<SnapshotAlignResult> _runStableVerifyIfCenteredV1(
    SnapshotAlignResult result,
  ) async {
    if (result.finalAlignmentStatus !=
        SnapshotAlignStatus.verifiedFaceCentered) {
      return result;
    }
    return _finalStableVerifyOwnerFaceV1(result);
  }

  Future<SnapshotAlignResult> _finalStableVerifyOwnerFaceV1(
    SnapshotAlignResult result,
  ) async {
    _envLogV1(
      '[ENV_V1_STABLE_VERIFY] start '
      'status=${result.finalAlignmentStatus}',
    );

    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      _envLogV1(
          '[ENV_V1_STABLE_VERIFY] result=still_offcenter reason=stop_failed');
      return result.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }

    _envLogV1(
      '[ENV_V1_STABLE_VERIFY] stop_and_settle '
      'ms=${_finalStableVerifySettleV1.inMilliseconds}',
    );
    await Future<void>.delayed(_finalStableVerifySettleV1);
    if (!_isEnvironmentMonitoring) return result;

    final verified = await _captureStableVerifySnapshotV1(result);
    if (verified.faceObservation?.hasFace != true) {
      return verified;
    }

    final faceDx =
        (verified.faceObservation?.centerX ?? verified.centerX) - 0.5;
    final absFaceDx = faceDx.abs();
    final stableStatus = _stableVerifyStatusForFaceDxV1(absFaceDx);
    if (stableStatus != null) {
      _envLogV1(
        '[ENV_V1_STABLE_VERIFY] result='
        '${stableStatus == SnapshotAlignStatus.verifiedFaceCentered ? 'confirmed_centered' : 'downgrade_acceptable'}',
      );
      return verified.copyWith(finalAlignmentStatus: stableStatus);
    }

    _envLogV1('[ENV_V1_STABLE_VERIFY] result=large_offset_repair_needed');
    return _repairStableVerifyLargeOffsetV1(verified, faceDx);
  }

  Future<SnapshotAlignResult> _captureStableVerifySnapshotV1(
    SnapshotAlignResult previous,
  ) async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_STABLE_VERIFY] result=still_offcenter '
          'reason=camera_unavailable',
        );
        return previous.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
          targetType: SnapshotTargetType.none,
          faceObservation: const FaceObservation(hasFace: false),
        );
      }

      final imagePath = await camera.captureImage();
      _envLogV1('[ENV_V1_STABLE_VERIFY] snapshot imagePath=$imagePath');

      final face = await camera.detectFaceObservationFromImagePath(imagePath);
      final faceDx = face.centerX - 0.5;
      _envLogV1(
        '[ENV_V1_STABLE_VERIFY] face hasFace=${face.hasFace} '
        'cx=${_f(face.centerX)} dx=${_f(faceDx)} '
        'absDx=${_f(faceDx.abs())}',
      );

      if (!face.hasFace) {
        _envLogV1(
            '[ENV_V1_STABLE_VERIFY] result=still_offcenter reason=face_lost');
        return previous.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
          targetType: SnapshotTargetType.none,
          faceObservation: face,
          imagePath: imagePath,
        );
      }

      return previous.copyWith(
        targetType: SnapshotTargetType.face,
        centerX: face.centerX,
        centerY: face.centerY,
        confidence: face.confidence,
        areaRatio: face.areaRatio,
        faceObservation: face,
        imagePath: imagePath,
      );
    } catch (e) {
      _envLogV1('[ENV_V1_STABLE_VERIFY] result=still_offcenter error=$e');
      return previous.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
        targetType: SnapshotTargetType.none,
        faceObservation: const FaceObservation(hasFace: false),
      );
    }
  }

  String? _stableVerifyStatusForFaceDxV1(double absFaceDx) {
    if (absFaceDx <= _verifiedFaceCenteredDx) {
      return SnapshotAlignStatus.verifiedFaceCentered;
    }
    if (absFaceDx <= _verifiedFaceAcceptableDx) {
      return SnapshotAlignStatus.verifiedFaceAcceptable;
    }
    return null;
  }

  Future<SnapshotAlignResult> _repairStableVerifyLargeOffsetV1(
    SnapshotAlignResult verified,
    double faceDx,
  ) async {
    final absFaceDx = faceDx.abs();
    final angle = absFaceDx > _ownerTrackSoftZoneV1 ? 6 : 3;
    final direction = _turnDirectionForOwnerDx(faceDx);
    _envLogV1(
      '[ENV_V1_STABLE_VERIFY] repair direction=$direction '
      'angle=$angle',
    );

    final moved = await _safeSendCommandV1WithPhase(
      direction,
      angle,
      phase: 'stable_verify_repair',
    );
    if (!moved) {
      _envLogV1('[ENV_V1_STABLE_VERIFY] repair_result=still_offcenter');
      return verified.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }

    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      _envLogV1('[ENV_V1_STABLE_VERIFY] repair_result=still_offcenter');
      return verified.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }

    _envLogV1(
      '[ENV_V1_STABLE_VERIFY] stop_and_settle '
      'ms=${_finalStableVerifySettleV1.inMilliseconds}',
    );
    await Future<void>.delayed(_finalStableVerifySettleV1);
    if (!_isEnvironmentMonitoring) return verified;

    final repaired = await _captureStableVerifySnapshotV1(verified);
    final repairedFace = repaired.faceObservation;
    if (repairedFace?.hasFace != true) {
      _envLogV1(
        '[ENV_V1_STABLE_VERIFY] repair_result='
        '${SnapshotAlignStatus.stillOffcenter}',
      );
      return repaired.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }

    final repairedDx = repairedFace!.centerX - 0.5;
    final repairedStatus = _stableVerifyStatusForFaceDxV1(repairedDx.abs());
    final finalStatus = repairedStatus ?? SnapshotAlignStatus.stillOffcenter;
    _envLogV1('[ENV_V1_STABLE_VERIFY] repair_result=$finalStatus');
    return repaired.copyWith(finalAlignmentStatus: finalStatus);
  }

  int _finalFaceNudgeAngleV1(
    double absFaceDx, {
    required bool overshotLastNudge,
  }) {
    if (overshotLastNudge) {
      return absFaceDx > _ownerTrackSoftZoneV1 ? 3 : 2;
    }
    return absFaceDx > _ownerTrackSoftZoneV1 ? 6 : 3;
  }

  Future<SnapshotAlignResult> _runSilentReacquireAfterFinalOffcenterV1(
    SnapshotAlignResult previous,
  ) async {
    if (!_isEnvironmentMonitoring) return previous;

    _envLogV1('[ENV_V1_FINAL_RECOVER] start reason=still_offcenter');
    HumanObservation? seed = _getFreshRealtimeHumanV1();
    final previousHuman = previous.humanObservation;
    if (seed == null &&
        previousHuman != null &&
        _isReliableHumanObservation(previousHuman)) {
      seed = previousHuman;
    }
    seed ??= await _detectHumanObservationSafe(
      phase: 'final_reacquire_seed',
      allowSnapshotFallback: true,
    );

    if (!_isReliableHumanObservation(seed)) {
      _envLogV1('[ENV_V1_FINAL_RECOVER] abort reason=no_reliable_human');
      return previous;
    }

    final tracked = await _runTrackOwnerV1(seed, maxLoops: 2);
    if (!_isEnvironmentMonitoring) return previous;

    final confirmed = await _runConfirmOwnerBySnapshotV1(tracked);
    if (!_isEnvironmentMonitoring) return confirmed;

    final recovered = await _runFinalFaceCenteringV1(confirmed);
    _envLogV1(
      '[ENV_V1_FINAL_RECOVER] result='
      '${recovered.finalAlignmentStatus}',
    );
    return recovered;
  }

  String _classifyAfterNudge(SnapshotAlignResult verified) {
    if (verified.targetType == SnapshotTargetType.face) {
      final faceDx =
          (verified.faceObservation?.centerX ?? verified.centerX) - 0.5;
      if (faceDx.abs() <= _verifiedFaceCenteredDx) {
        return SnapshotAlignStatus.verifiedFaceCentered;
      }
      if (faceDx.abs() <= _verifiedFaceAcceptableDx) {
        return SnapshotAlignStatus.verifiedFaceAcceptable;
      }
      return SnapshotAlignStatus.stillOffcenter;
    }

    final person = verified.humanObservation;
    if (person != null && _isReliableHumanObservation(person)) {
      final personDx = person.centerX - 0.5;
      if (personDx.abs() <= _verifiedPersonAcceptableDx) {
        return SnapshotAlignStatus.verifiedPersonAcceptable;
      }
      return SnapshotAlignStatus.stillOffcenter;
    }

    return SnapshotAlignStatus.targetLostAfterNudge;
  }

  Future<void> _runInteractOwnerV1(SnapshotAlignResult result) async {
    _monitorStatus = 'INTERACT: 陪伴互动';
    final status = result.finalAlignmentStatus;
    final isStrictlyCentered =
        status == SnapshotAlignStatus.verifiedFaceCentered;
    final greetingLine = _greetingLineForStatus(status);

    if (greetingLine != null) {
      _envLogV1(
        '[ENV_V1_INTERACT] owner_seen status=$status '
        'strictCentered=$isStrictlyCentered',
      );
      await _sendImmediateStopV1(phase: 'owner_seen_interact');
      if (!_isEnvironmentMonitoring) return;

      await _loadExpression('assets/emotion/face2/可爱/02/可爱 02.json');
      _envLogV1('[ENV_V1_INTERACT] speak_owner_seen text=$greetingLine');
      await speakWithInterruptProtection(greetingLine);
      if (!_isEnvironmentMonitoring) return;

      const companionInvite = '要不要和我说句话？';
      _envLogV1(
          '[ENV_V1_INTERACT] speak_companion_invite text=$companionInvite');
      await speakWithInterruptProtection(companionInvite);
      if (!_isEnvironmentMonitoring) return;

      final waitResult = await _waitOwnerReplyBeforeCompanionV1(
        timeout: _ownerReplyWaitTimeoutV1,
      );
      if (waitResult != 'no_response') {
        _cancelPendingObjectLookAroundTimerV1(reason: waitResult);
        return;
      }

      const quietCompanionLine = '那我就在这儿陪你啦。';
      _envLogV1(
        '[ENV_V1_INTERACT] speak_quiet_companion '
        'text=$quietCompanionLine',
      );
      await speakWithInterruptProtection(quietCompanionLine);
      if (!_isEnvironmentMonitoring) return;

      _envLogV1('[ENV_V1_INTERACT] enter_owner_found_hold');
      _checkAndScheduleObjectLookAroundAfterOwnerFoundV1(
        status: status,
        strictCentered: isStrictlyCentered,
      );
    } else {
      _envLogV1(
        '[ENV_V1_INTERACT] status=$status '
        'speak_skipped reason=not_aligned',
      );
      await _loadExpression('assets/emotion/face2/眨眼.json');
      _checkAndScheduleObjectLookAroundAfterOwnerFoundV1(
        status: status,
        strictCentered: isStrictlyCentered,
      );
    }

    if (!_isEnvironmentMonitoring) return;
    _envLogV1('[ENV_V1_INTERACT] enter_quiet_companion');
  }

  Future<String> _waitOwnerReplyBeforeCompanionV1({
    required Duration timeout,
  }) async {
    _envLogV1(
      '[ENV_V1_INTERACT] wait_owner_reply start '
      'timeoutMs=${timeout.inMilliseconds}',
    );

    final stopped = await _sendImmediateStopV1(
      phase: 'wait_owner_reply_start',
    );
    if (!stopped && !_isBluetoothConnectedV1()) {
      _envLogV1(
        '[ENV_V1_INTERACT] wait_owner_reply canceled '
        'reason=bluetooth_disconnected',
      );
      return 'bluetooth_disconnected';
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_isEnvironmentMonitoring) {
        _envLogV1(
          '[ENV_V1_INTERACT] wait_owner_reply canceled reason=env_stopped',
        );
        return 'env_stopped';
      }
      if (!_isBluetoothConnectedV1()) {
        _envLogV1(
          '[ENV_V1_INTERACT] wait_owner_reply canceled '
          'reason=bluetooth_disconnected',
        );
        return 'bluetooth_disconnected';
      }
      if (_isChatOrWakeActiveV1()) {
        _envLogV1(
          '[ENV_V1_INTERACT] wait_owner_reply canceled reason=chat_started',
        );
        return 'chat_started';
      }

      final remaining = deadline.difference(DateTime.now());
      final delay = remaining < _ownerReplyWaitPollIntervalV1
          ? remaining
          : _ownerReplyWaitPollIntervalV1;
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
    }

    _envLogV1('[ENV_V1_INTERACT] wait_owner_reply timeout no_response');
    final finalStopped = await _sendImmediateStopV1(
      phase: 'wait_owner_reply_no_response',
    );
    if (!finalStopped && !_isBluetoothConnectedV1()) {
      _envLogV1(
        '[ENV_V1_INTERACT] wait_owner_reply canceled '
        'reason=bluetooth_disconnected',
      );
      return 'bluetooth_disconnected';
    }
    return 'no_response';
  }

  bool _isChatOrWakeActiveV1() {
    _refreshExternalActivityStateV1();
    return _isAnswering;
  }

  bool _isBluetoothConnectedV1() {
    final service = _bluetoothService;
    return service != null && service.isConnected;
  }

  bool _checkAndScheduleObjectLookAroundAfterOwnerFoundV1({
    required String status,
    required bool strictCentered,
  }) {
    _envLogV1(
      '[ENV_V1_OBJECT_DELAY] schedule_check status=$status '
      'strictCentered=$strictCentered '
      'enable=$_enableObjectLookAroundAfterOwnerFoundV1',
    );

    if (!_enableObjectLookAroundAfterOwnerFoundV1) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=feature_disabled status=$status',
      );
      return false;
    }

    if (status == SnapshotAlignStatus.verifiedPersonAcceptable) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=person_only_not_strict_enough status=$status',
      );
      return false;
    }

    final reason = _objectLookAroundScheduleReasonForStatusV1(status);
    if (reason == null) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=status_not_owner_seen status=$status',
      );
      return false;
    }

    if (_objectLookAroundExecutedV1) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=already_executed status=$status',
      );
      return false;
    }
    if (_objectLookAroundRunningV1) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=already_running status=$status',
      );
      return false;
    }

    _scheduleObjectLookAroundAfterOwnerFoundV1(
      reason: reason,
      ownerStatus: status,
    );
    return true;
  }

  String? _objectLookAroundScheduleReasonForStatusV1(String status) {
    if (status == SnapshotAlignStatus.verifiedFaceCentered) {
      return 'owner_found_hold_started_centered';
    }
    if (status == SnapshotAlignStatus.verifiedFaceAcceptable) {
      return 'owner_found_hold_started_acceptable';
    }
    return null;
  }

  void _scheduleObjectLookAroundAfterOwnerFoundV1({
    required String reason,
    required String ownerStatus,
  }) {
    _ownerFoundAtV1 = DateTime.now();
    _pendingObjectLookAroundReasonV1 = reason;
    _pendingObjectLookAroundOwnerStatusV1 = ownerStatus;
    _envLogV1(
      '[ENV_V1_INTERACT] owner_found_hold still for '
      '${_objectLookAroundDelayV1.inSeconds}s before object '
      'look-around',
    );

    _cancelPendingObjectLookAroundTimerV1(reason: 'reschedule_owner_found');
    _pendingObjectLookAroundTimerV1 = Timer(
      _objectLookAroundDelayV1,
      () => unawaited(_handleObjectLookAroundDelayElapsedV1()),
    );
    _envLogV1(
      '[ENV_V1_OBJECT_DELAY] scheduled '
      'delay=${_objectLookAroundDelayV1.inSeconds}s '
      'reason=$reason',
    );
  }

  Future<void> _handleObjectLookAroundDelayElapsedV1() async {
    _pendingObjectLookAroundTimerV1 = null;
    _refreshExternalActivityStateV1();

    final skipReason = _objectLookAroundDelaySkipReasonV1();
    final allowed = skipReason == null;
    final ownerFoundAt = _ownerFoundAtV1;
    final heldMs = ownerFoundAt == null
        ? 0
        : DateTime.now().difference(ownerFoundAt).inMilliseconds;
    if (!allowed) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] elapsed allowed=false '
        'reason=$skipReason heldMs=$heldMs',
      );
      return;
    }

    _envLogV1('[ENV_V1_OBJECT_DELAY] elapsed allowed=true heldMs=$heldMs');
    _envLogV1('[ENV_V1_OBJECT_DELAY] elapsed start object look-around');
    final hadCameraService = _cameraService != null;
    _stopIdleRecenterAfterObjectReturnV1(reason: 'object_look_started');
    _objectLookAroundRunningV1 = true;
    _quietCompanionActiveV1 = false;

    try {
      final stopped = await _sendImmediateStopV1(phase: 'object_look_start');
      if (!stopped) {
        _envLogV1('[ENV_V1_OBJECT_DELAY] skipped reason=pre_start_stop_failed');
        return;
      }

      var cancelReason = _objectLookAroundStartCancelReasonV1();
      if (cancelReason != null) {
        _logObjectLookAroundStartCanceledV1(cancelReason);
        return;
      }

      await _speakBeforeObjectLookAroundV1();
      cancelReason = _objectLookAroundStartCancelReasonV1();
      if (cancelReason != null) {
        _logObjectLookAroundStartCanceledV1(cancelReason);
        return;
      }

      final stoppedAfterSpeech = await _sendImmediateStopV1(
        phase: 'object_look_after_speech',
      );
      if (!stoppedAfterSpeech) {
        _envLogV1(
          '[ENV_V1_OBJECT_DELAY] skipped reason=post_speech_stop_failed',
        );
        return;
      }
      await Future<void>.delayed(_objectLookAroundPreStartStopSettleV1);
      cancelReason = _objectLookAroundStartCancelReasonV1();
      if (cancelReason != null) {
        _logObjectLookAroundStartCanceledV1(cancelReason);
        return;
      }

      await _ensureCameraService();
      if (!_isEnvironmentMonitoring) return;
      _objectLookAroundExecutedV1 = true;
      await _runObjectLookAroundAfterOwnerFoundV1(
        reason: _pendingObjectLookAroundReasonV1 ??
            'owner_found_hold_reason_unknown',
        ownerStatus: _pendingObjectLookAroundOwnerStatusV1 ?? 'unknown',
      );
    } catch (e, st) {
      _envLogV1('[ENV_V1_OBJECT_DELAY] start_failed error=$e\n$st');
    } finally {
      _objectLookAroundRunningV1 = false;
      if (_isEnvironmentMonitoring) {
        if (!hadCameraService && !_idleRecenterActiveV1) {
          await _disposeCameraService();
        }
        await _enterQuietCompanionModeV1();
      }
    }
  }

  String? _objectLookAroundDelaySkipReasonV1() {
    if (!_enableObjectLookAroundAfterOwnerFoundV1) {
      return 'feature_disabled';
    }
    if (_objectLookAroundExecutedV1) {
      return 'already_executed';
    }
    if (_objectLookAroundRunningV1) {
      return 'already_running';
    }
    if (!_isEnvironmentMonitoring) {
      return 'env_monitoring_stopped';
    }
    if (!_quietCompanionActiveV1) {
      return 'not_quiet_companion';
    }
    if (_isAnswering) {
      return 'chat_active';
    }
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      return 'bluetooth_disconnected';
    }
    if (_envV1MotionCommandInFlight) {
      return 'motion_in_flight';
    }
    if (_ownerAlignmentActiveV1) {
      return 'owner_alignment_active';
    }
    return null;
  }

  void _cancelPendingObjectLookAroundTimerV1({required String reason}) {
    final timer = _pendingObjectLookAroundTimerV1;
    if (timer == null) return;
    timer.cancel();
    _pendingObjectLookAroundTimerV1 = null;
    _pendingObjectLookAroundReasonV1 = null;
    _pendingObjectLookAroundOwnerStatusV1 = null;
    _envLogV1('[ENV_V1_OBJECT_DELAY] canceled reason=$reason');
  }

  void _cancelPendingObjectLookAroundIfInterruptedV1() {
    if (_pendingObjectLookAroundTimerV1 == null) return;
    if (!_isEnvironmentMonitoring) {
      _cancelPendingObjectLookAroundTimerV1(
        reason: 'env_monitoring_stopped',
      );
      return;
    }
    if (_isAnswering) {
      _cancelPendingObjectLookAroundTimerV1(reason: 'chat_started');
      return;
    }
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _cancelPendingObjectLookAroundTimerV1(
        reason: 'bluetooth_disconnected',
      );
    }
  }

  void _resetObjectLookAroundSessionV1() {
    _cancelPendingObjectLookAroundTimerV1(reason: 'new_session');
    _stopIdleRecenterAfterObjectReturnV1(reason: 'new_session');
    _ownerFoundAtV1 = null;
    _objectLookAroundExecutedV1 = false;
    _objectLookAroundRunningV1 = false;
    _pendingObjectLookAroundReasonV1 = null;
    _pendingObjectLookAroundOwnerStatusV1 = null;
    _objectReturnSafeStopWaitingV1 = false;
    _objectReturnPendingSafeStopReasonV1 = null;
    _lastFrontCliffRecoveredTurnPhaseV1 = null;
    _frontCliffInterruptsByPhaseV1.clear();
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
    _envV1MotionCommandInFlight = false;
  }

  Future<bool> _sendImmediateStopV1({required String phase}) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _envLogV1(
        '[ENV_V1_OBJECT_DELAY] stop skipped '
        'phase=$phase reason=bluetooth_disconnected',
      );
      return false;
    }

    try {
      _envV1MotionCommandInFlight = true;
      await service.sendCommand('停止', 0);
      _envLogV1('[ENV_V1_OBJECT_DELAY] stop sent phase=$phase');
      return true;
    } catch (e) {
      _envLogV1('[ENV_V1_OBJECT_DELAY] stop failed phase=$phase error=$e');
      return false;
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  String? _objectLookAroundStartCancelReasonV1() {
    _refreshExternalActivityStateV1();
    if (!_isEnvironmentMonitoring) {
      return 'env_monitoring_stopped';
    }
    if (_isAnswering) {
      return 'chat_active';
    }
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      return 'bluetooth_disconnected';
    }
    return null;
  }

  void _logObjectLookAroundStartCanceledV1(String reason) {
    final logReason =
        reason == 'chat_active' ? 'chat_started_before_object_start' : reason;
    _envLogV1('[ENV_V1_OBJECT_DELAY] canceled reason=$logReason');
  }

  Future<void> _speakBeforeObjectLookAroundV1() async {
    const text = '我去找找有没有别的好玩的。';
    _envLogV1('[ENV_V1_OBJECT_DELAY] speak_before_object text=$text');
    try {
      final tts = _ttsService;
      if (tts == null) {
        throw StateError('tts_service_unavailable');
      }
      _envLogV1('🎤 环境监测 V1 语音播报: $text');
      await tts.speak(text);
      _envLogV1('[ENV_V1_OBJECT_DELAY] speak_before_object done');
    } catch (e) {
      _envLogV1('[ENV_V1_OBJECT_DELAY] speak_before_object failed error=$e');
    }
  }

  Future<void> _runObjectLookAroundAfterOwnerFoundV1({
    required String reason,
    required String ownerStatus,
  }) async {
    if (!_isEnvironmentMonitoring) return;

    _monitorStatus = 'OBJECT_LOOK: 锚定式物体探索';
    _envLogV1(
      '[ENV_V1_OBJECT] start mode=anchored_probe '
      'reason=$reason ownerStatus=$ownerStatus',
    );
    await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');

    final detector = DesktopObjectDetector();
    var forceReturnResearch = false;
    var foundAnyObject = false;
    var microApproachUsed = false;
    var objectLookAborted = false;
    var objectLookFinished = false;
    _objectGenericSpeechCountV1 = 0;
    DetectedDesktopObject? bestObject;
    String? bestObjectSource;
    try {
      if (!_enableObjectForwardProbeV1) {
        _envLogV1('[ENV_V1_OBJECT] skipped reason=forward_probe_disabled');
        return;
      }
      await _startRealtimeObjectDetectionForEnvV1();

      final forwardMm = _boundedObjectProbeForwardMmV1();
      final probePlans =
          _objectProbePlansV1.take(_objectProbeMaxCountV1).toList();
      _envLogV1(
        '[ENV_V1_OBJECT] probe_plan count=${probePlans.length} '
        'mode=anchored realtime_candidate_snapshot_confirm',
      );
      for (var i = 0; i < probePlans.length; i++) {
        if (!_isEnvironmentMonitoring) return;
        final index = i + 1;
        final probeResult = await _runAnchoredObjectProbeV1(
          detector,
          probePlans[i],
          index: index,
          total: probePlans.length,
          forwardMm: forwardMm,
          allowMicroApproach: !microApproachUsed,
          sessionGenericSpeechCount: _objectGenericSpeechCountV1,
        );
        foundAnyObject = foundAnyObject || probeResult.foundObject;
        microApproachUsed = microApproachUsed || probeResult.usedMicroApproach;
        _objectGenericSpeechCountV1 += probeResult.genericSpeechCountDelta;

        final candidate = probeResult.bestObject;
        if (candidate != null &&
            (bestObject == null ||
                candidate.confidence > bestObject.confidence)) {
          bestObject = candidate;
          bestObjectSource = probeResult.bestSource;
          _envLogV1(
            '[ENV_V1_OBJECT] best_object label=${candidate.label} '
            'score=${_f(candidate.confidence)} '
            'source=${bestObjectSource ?? 'unknown'}',
          );
        }
        if (!probeResult.shouldContinue) {
          forceReturnResearch = !probeResult.restoredToAnchor;
          objectLookAborted = !probeResult.finishedGracefully;
          break;
        }

        if (bestObject != null &&
            index >= _objectMinProbeCountBeforeEarlyStopV1) {
          _envLogV1(
            '[ENV_V1_OBJECT] early_stop '
            'reason=generic_visual_presence_found',
          );
          break;
        }
        if (bestObject != null && index < probePlans.length) {
          _envLogV1(
            '[ENV_V1_OBJECT] continue '
            'reason=low_confidence_or_min_probes_not_reached',
          );
        }
      }

      if (!foundAnyObject && !objectLookAborted) {
        _envLogV1(
          '[ENV_V1_OBJECT] no_object_found probes=${probePlans.length} '
          'speech_skipped=true',
        );
      }
      objectLookFinished = !objectLookAborted;
    } finally {
      await _stopRealtimeObjectDetectionForEnvV1(
        reason: objectLookFinished ? 'object_look_finished' : 'cleanup/aborted',
      );
      await detector.close();
      if (_isEnvironmentMonitoring) {
        await _safeSendCommandV1('停止', 0);
      }
    }

    if (!_isEnvironmentMonitoring) return;
    final safetyReasonAfterObjectLook = _objectReturnSafetyStopReasonV1();
    if (safetyReasonAfterObjectLook != null) {
      final finalResult = await _enterObjectReturnSafeStopWaitForOwnerV1(
        reason: safetyReasonAfterObjectLook,
        lastResult: SnapshotAlignResult.noTarget(),
      );
      _envLogV1(
        '[ENV_V1_OBJECT] stopped reason=safe_stop_wait_for_owner '
        'return_status=${finalResult.finalAlignmentStatus}',
      );
      return;
    }
    final readyForOwnerReturn = await _returnToOwnerAfterObjectLookV1(
      0,
      '左转',
    );
    if (!readyForOwnerReturn && !forceReturnResearch) {
      _envLogV1(
        '[ENV_V1_OBJECT] stopped reason=return_owner_prepare_failed',
      );
      return;
    }

    final finalResult = await _reconfirmOwnerAfterObjectLookV1(
      forceResearch: forceReturnResearch,
    );
    if (_objectReturnSafeStopWaitingV1) {
      _envLogV1(
        '[ENV_V1_OBJECT] stopped reason=safe_stop_wait_for_owner '
        'return_status=${finalResult.finalAlignmentStatus}',
      );
      return;
    }
    if (finalResult.finalAlignmentStatus !=
        SnapshotAlignStatus.verifiedFaceCentered) {
      _envLogV1(
        '[ENV_V1_OBJECT] return_pending_until_centered '
        'status=${finalResult.finalAlignmentStatus}',
      );
      return;
    }
    _envLogV1(
      '[ENV_V1_OBJECT] done final_status='
      '${finalResult.finalAlignmentStatus}',
    );
  }

  int _boundedObjectProbeForwardMmV1() {
    if (_objectProbeForwardMmV1 > _objectProbeMaxForwardMmV1) {
      return _objectProbeMaxForwardMmV1;
    }
    return _objectProbeForwardMmV1;
  }

  Future<_ObjectProbeRunResultV1> _runAnchoredObjectProbeV1(
    DesktopObjectDetector detector,
    _ObjectProbePlanV1 plan, {
    required int index,
    required int total,
    required int forwardMm,
    required bool allowMicroApproach,
    required int sessionGenericSpeechCount,
  }) async {
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] start index=$index/$total '
      'turn=${plan.turnLabel} angle=${plan.turnAngleDeg} '
      'forwardMm=$forwardMm',
    );
    _clearRealtimeObjectCandidateV1();
    var probeSpeechCount = 0;
    var genericSpeechCountDelta = 0;

    final turnedOut = await _safeSendCommandV1WithPhase(
      plan.turnCommand,
      plan.turnAngleDeg,
      phase: 'object_probe_turn_out',
    );
    if (!turnedOut) {
      if (_consumeTurnSensorIncidentV1(
        'object_probe_turn_out',
        logPrefix: '[ENV_V1_OBJECT_PROBE]',
      )) {
        await _safeSendCommandV1('停止', 0);
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] object_look_continue '
          'reason=turn_sensor_interrupt_not_fatal',
        );
        return const _ObjectProbeRunResultV1(
          restoredToAnchor: true,
          foundObject: false,
          shouldContinue: true,
        );
      }
      await _failObjectProbeV1(
        phase: 'turn_out',
        index: index,
        error: 'send_failed',
      );
      return const _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: false,
        shouldContinue: false,
      );
    }
    _envLogV1('[ENV_V1_OBJECT_PROBE] turn_out done index=$index');

    final movedForward = await _sendLinearMotionWithSafetyGuardV1(
      '前进',
      forwardMm,
      phase: 'probe_forward',
      index: index,
    );
    if (!movedForward.success) {
      if (movedForward.safeStopRequired) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] motion_paused_keep_monitoring '
          'phase=forward obstacle=${_sensorIncidentNameV1(movedForward.incident)} '
          'code=${_sensorIncidentCodeV1(movedForward.incident)}',
        );
        return _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: false,
          shouldContinue: false,
          finishedGracefully: true,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      if (_isNonFatalSensorIncidentV1(movedForward.incident)) {
        return _handleObjectProbeForwardSensorIncidentV1(
          detector,
          plan,
          index: index,
          incident: movedForward.incident,
          sessionGenericSpeechCount:
              sessionGenericSpeechCount + genericSpeechCountDelta,
          probeSpeechCount: probeSpeechCount,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      if (movedForward.cliffDetected) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] motion_paused_keep_monitoring '
          'phase=forward reason=cliff_detected',
        );
        return const _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: false,
          shouldContinue: true,
        );
      }
      await _failObjectProbeV1(
        phase: 'forward',
        index: index,
        error: movedForward.error,
      );
      final restored = await _restoreObjectProbeAfterFailedForwardV1(
        plan,
        index: index,
        forwardMm: forwardMm,
      );
      return _ObjectProbeRunResultV1(
        restoredToAnchor: restored,
        foundObject: false,
        shouldContinue: false,
      );
    }
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] forward done index=$index mm=$forwardMm',
    );

    final stoppedAfterForward = await _safeSendCommandV1('停止', 0);
    if (!stoppedAfterForward) {
      await _failObjectProbeV1(
        phase: 'forward_stop',
        index: index,
        error: 'stop_failed',
      );
      return const _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: false,
        shouldContinue: false,
      );
    }
    await Future<void>.delayed(
      const Duration(milliseconds: _objectProbeSettleMsV1),
    );

    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] collect_realtime start index=$index '
      'durationMs=$_objectProbeRealtimeCollectMsV1',
    );
    final realtimeAnalysis = await _collectRealtimeObjectCandidateForProbeV1(
      phase: 'probe_$index',
      timeout: _realtimeObjectProbeWaitV1,
    );
    final result = await _captureAndDetectObjectProbeSnapshotV1(detector);
    final snapshotObject =
        result == null ? null : _firstNonPersonObjectV1(result);
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] snapshot_confirm '
      'hasObject=${snapshotObject != null} '
      'label=${snapshotObject?.label ?? 'none'} '
      'score=${_f(snapshotObject?.confidence ?? 0)}',
    );
    final decision = _decideObjectProbeCandidateV1(
      snapshotObject: snapshotObject,
      realtimeAnalysis: realtimeAnalysis,
    );
    final object = decision.object;
    final mergeSource = decision.source;
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] merged_result found=${object != null} '
      'source=$mergeSource '
      'label=${decision.logObject?.label ?? 'none'} '
      'policy=${_objectPolicyNameV1(decision.policy)} '
      'score=${_f(decision.logObject?.confidence ?? 0)} '
      'area=${_f(decision.logObject?.areaRatio ?? 0)} '
      'hits=${decision.realtimeHits} reason=${decision.reason}',
    );
    var foundObject = false;
    var usedMicroApproach = false;
    DetectedDesktopObject? bestObject;
    String? bestSource;
    if (object == null && mergeSource == 'realtime_low_only') {
      await _speakObjectObservationV1(
        decision,
        probeIndex: index,
        sessionGenericSpeechCount:
            sessionGenericSpeechCount + genericSpeechCountDelta,
        probeSpeechCount: probeSpeechCount,
      );
    }
    if (object != null) {
      foundObject = true;
      bestObject = object;
      bestSource = 'probe_${index}_$mergeSource';
      await _safeSendCommandV1('停止', 0);
      await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] found source=$bestSource '
        'label=${object.label} score=${_f(object.confidence)} '
        'pauseBeforeSpeechMs=$_objectFoundPauseBeforeSpeechMsV1 '
        'pauseAfterSpeechMs=$_objectFoundPauseAfterSpeechMsV1',
      );
      await Future<void>.delayed(
        const Duration(milliseconds: _objectFoundPauseBeforeSpeechMsV1),
      );
      final spokenMode = await _speakObjectObservationV1(
        decision,
        probeIndex: index,
        sessionGenericSpeechCount:
            sessionGenericSpeechCount + genericSpeechCountDelta,
        probeSpeechCount: probeSpeechCount,
      );
      if (spokenMode != _ObjectSpeechModeV1.none) {
        probeSpeechCount++;
        if (_isGenericObjectSpeechModeV1(spokenMode)) {
          genericSpeechCountDelta++;
        }
        await Future<void>.delayed(
          const Duration(milliseconds: _objectFoundPauseAfterSpeechMsV1),
        );
      } else if (_shouldSilentObserveObjectDecisionV1(decision)) {
        _envLogV1(
          '[ENV_V1_OBJECT] object_interact silent_observe '
          'ms=$_objectWeakFallbackSilentObserveMsV1 '
          'reason=generic_speech_already_spoken',
        );
        await Future<void>.delayed(
          const Duration(milliseconds: _objectWeakFallbackSilentObserveMsV1),
        );
      }

      if (_enableObjectMicroApproachOnFoundV1 &&
          object.confidence >= _objectSpeechFallbackConfidenceV1) {
        final microResult = await _runObjectMicroApproachConfirmV1(
          detector,
          beforeObject: object,
          allowMicroApproach: allowMicroApproach,
        );
        usedMicroApproach = microResult.usedMicroApproach;
        if (microResult.cliffDetected) {
          _envLogV1(
            '[ENV_V1_OBJECT_PROBE] motion_paused_keep_monitoring '
            'phase=micro reason=cliff_detected',
          );
          return _ObjectProbeRunResultV1(
            restoredToAnchor: false,
            foundObject: foundObject,
            shouldContinue: true,
            bestObject: bestObject,
            bestSource: bestSource,
            usedMicroApproach: usedMicroApproach,
            genericSpeechCountDelta: genericSpeechCountDelta,
          );
        }
        final confirmedObject = microResult.confirmedObject;
        if (confirmedObject != null &&
            confirmedObject.confidence >= bestObject.confidence) {
          bestObject = confirmedObject;
          bestSource = 'micro_confirm';
        }
      } else if (!_enableObjectMicroApproachOnFoundV1) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] skipped reason=feature_disabled '
          'label=${object.label} score=${_f(object.confidence)}',
        );
      } else {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] skipped reason=realtime_weak_candidate '
          'label=${object.label} score=${_f(object.confidence)}',
        );
      }
    }

    final movedBackward = await _sendLinearMotionWithSafetyGuardV1(
      '后退',
      forwardMm,
      phase: 'probe_backward',
      index: index,
    );
    if (!movedBackward.success) {
      if (movedBackward.safeStopRequired) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] motion_paused_keep_monitoring '
          'phase=backward obstacle=${_sensorIncidentNameV1(movedBackward.incident)} '
          'code=${_sensorIncidentCodeV1(movedBackward.incident)}',
        );
        return _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: foundObject,
          shouldContinue: false,
          finishedGracefully: true,
          bestObject: bestObject,
          bestSource: bestSource,
          usedMicroApproach: usedMicroApproach,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      if (_isNonFatalSensorIncidentV1(movedBackward.incident)) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] backward_interrupted '
          'obstacle=${_sensorIncidentNameV1(movedBackward.incident)} '
          'code=${_sensorIncidentCodeV1(movedBackward.incident)} '
          'action=stop_keep_monitoring',
        );
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] anchor_restore_partial '
          'reason=${_sensorIncidentNameV1(movedBackward.incident)}',
        );
        await _safeSendCommandV1('停止', 0);
        return _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: foundObject,
          shouldContinue: true,
          bestObject: bestObject,
          bestSource: bestSource,
          usedMicroApproach: usedMicroApproach,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      if (movedBackward.cliffDetected) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] motion_paused_keep_monitoring '
          'phase=backward reason=cliff_detected',
        );
        return _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: foundObject,
          shouldContinue: true,
          bestObject: bestObject,
          bestSource: bestSource,
          usedMicroApproach: usedMicroApproach,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      await _failObjectProbeV1(
        phase: 'backward',
        index: index,
        error: movedBackward.error,
      );
      return _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: foundObject,
        shouldContinue: false,
        bestObject: bestObject,
        bestSource: bestSource,
        usedMicroApproach: usedMicroApproach,
        genericSpeechCountDelta: genericSpeechCountDelta,
      );
    }
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] backward done index=$index mm=$forwardMm',
    );

    final stoppedAfterBackward = await _safeSendCommandV1('停止', 0);
    if (!stoppedAfterBackward) {
      await _failObjectProbeV1(
        phase: 'backward_stop',
        index: index,
        error: 'stop_failed',
      );
      return _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: foundObject,
        shouldContinue: false,
        bestObject: bestObject,
        bestSource: bestSource,
        usedMicroApproach: usedMicroApproach,
        genericSpeechCountDelta: genericSpeechCountDelta,
      );
    }

    final turnedBack = await _safeSendCommandV1WithPhase(
      plan.turnBackCommand,
      plan.turnAngleDeg,
      phase: 'object_probe_turn_back',
    );
    if (!turnedBack) {
      if (_consumeTurnSensorIncidentV1(
        'object_probe_turn_back',
        logPrefix: '[ENV_V1_OBJECT_PROBE]',
      )) {
        await _safeSendCommandV1('停止', 0);
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] anchor_restore_partial '
          'reason=turn_sensor_interrupt',
        );
        return _ObjectProbeRunResultV1(
          restoredToAnchor: false,
          foundObject: foundObject,
          shouldContinue: true,
          bestObject: bestObject,
          bestSource: bestSource,
          usedMicroApproach: usedMicroApproach,
          genericSpeechCountDelta: genericSpeechCountDelta,
        );
      }
      await _failObjectProbeV1(
        phase: 'turn_back',
        index: index,
        error: 'send_failed',
      );
      return _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: foundObject,
        shouldContinue: false,
        bestObject: bestObject,
        bestSource: bestSource,
        usedMicroApproach: usedMicroApproach,
        genericSpeechCountDelta: genericSpeechCountDelta,
      );
    }
    _envLogV1('[ENV_V1_OBJECT_PROBE] turn_back done index=$index');

    final stoppedAtAnchor = await _safeSendCommandV1('停止', 0);
    if (!stoppedAtAnchor) {
      await _failObjectProbeV1(
        phase: 'turn_back',
        index: index,
        error: 'stop_failed',
      );
      return _ObjectProbeRunResultV1(
        restoredToAnchor: false,
        foundObject: foundObject,
        shouldContinue: false,
        bestObject: bestObject,
        bestSource: bestSource,
        usedMicroApproach: usedMicroApproach,
        genericSpeechCountDelta: genericSpeechCountDelta,
      );
    }
    await Future<void>.delayed(_settleDelay);
    _envLogV1('[ENV_V1_OBJECT_PROBE] restored_to_anchor index=$index');
    return _ObjectProbeRunResultV1(
      restoredToAnchor: true,
      foundObject: foundObject,
      shouldContinue: !foundObject,
      finishedGracefully: foundObject,
      bestObject: bestObject,
      bestSource: bestSource,
      usedMicroApproach: usedMicroApproach,
      genericSpeechCountDelta: genericSpeechCountDelta,
    );
  }

  Future<_ObjectMicroConfirmResultV1> _runObjectMicroApproachConfirmV1(
    DesktopObjectDetector detector, {
    required DetectedDesktopObject beforeObject,
    required bool allowMicroApproach,
  }) async {
    _envLogV1(
      '[ENV_V1_OBJECT] micro_confirm before '
      'label=${beforeObject.label} score=${_f(beforeObject.confidence)}',
    );
    if (!_enableObjectMicroApproachOnFoundV1) {
      _envLogV1('[ENV_V1_OBJECT_MICRO] skipped reason=feature_disabled');
      return const _ObjectMicroConfirmResultV1();
    }
    if (!allowMicroApproach) {
      _envLogV1(
        '[ENV_V1_OBJECT_MICRO] skipped reason=session_micro_already_used',
      );
      return const _ObjectMicroConfirmResultV1();
    }
    if (!_hasReliableObjectCliffGuardV1()) {
      _envLogV1(
        '[ENV_V1_OBJECT_MICRO] skipped reason=no_cliff_guard_available',
      );
      return const _ObjectMicroConfirmResultV1();
    }

    final approachMm = _boundedObjectMicroApproachMmV1();
    _envLogV1('[ENV_V1_OBJECT_MICRO] start mm=$approachMm reason=object_found');
    final movedForward = await _sendLinearMotionWithSafetyGuardV1(
      '前进',
      approachMm,
      phase: 'micro_approach',
    );
    if (!movedForward.success) {
      if (movedForward.safeStopRequired) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] motion_paused_keep_monitoring '
          'obstacle=${_sensorIncidentNameV1(movedForward.incident)} '
          'code=${_sensorIncidentCodeV1(movedForward.incident)}',
        );
        await _safeSendCommandV1('停止', 0);
        return const _ObjectMicroConfirmResultV1(
          usedMicroApproach: true,
          cliffDetected: true,
        );
      }
      if (_isNonFatalSensorIncidentV1(movedForward.incident)) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] interrupted '
          'obstacle=${_sensorIncidentNameV1(movedForward.incident)} '
          'code=${_sensorIncidentCodeV1(movedForward.incident)} '
          'action=skip_micro_keep_monitoring',
        );
        await _safeSendCommandV1('停止', 0);
        return const _ObjectMicroConfirmResultV1(usedMicroApproach: true);
      }
      if (movedForward.cliffDetected) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] motion_paused_keep_monitoring '
          'reason=cliff_detected',
        );
        return const _ObjectMicroConfirmResultV1(
          usedMicroApproach: true,
          cliffDetected: true,
        );
      }
      _envLogV1(
        '[ENV_V1_OBJECT_MICRO] aborted reason=${movedForward.error}',
      );
      return const _ObjectMicroConfirmResultV1(usedMicroApproach: true);
    }
    _envLogV1('[ENV_V1_OBJECT_MICRO] forward done mm=$approachMm');

    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      _envLogV1('[ENV_V1_OBJECT_MICRO] aborted reason=stop_failed');
      return const _ObjectMicroConfirmResultV1(usedMicroApproach: true);
    }
    await Future<void>.delayed(
      const Duration(milliseconds: _objectMicroApproachSettleMsV1),
    );

    final result = await _captureAndDetectObjectMicroSnapshotV1(detector);
    final confirmedObject =
        result == null ? null : _firstNonPersonObjectV1(result);
    _envLogV1(
      '[ENV_V1_OBJECT] micro_confirm after '
      'label=${confirmedObject?.label ?? 'none'} '
      'score=${_f(confirmedObject?.confidence ?? 0)}',
    );

    final movedBackward = await _sendLinearMotionWithSafetyGuardV1(
      '后退',
      approachMm,
      phase: 'micro_backward',
    );
    if (!movedBackward.success) {
      if (movedBackward.safeStopRequired) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] motion_paused_keep_monitoring '
          'obstacle=${_sensorIncidentNameV1(movedBackward.incident)} '
          'code=${_sensorIncidentCodeV1(movedBackward.incident)}',
        );
        await _safeSendCommandV1('停止', 0);
        return _ObjectMicroConfirmResultV1(
          usedMicroApproach: true,
          cliffDetected: true,
          confirmedObject: confirmedObject,
        );
      }
      if (_isNonFatalSensorIncidentV1(movedBackward.incident)) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] backward_interrupted '
          'obstacle=${_sensorIncidentNameV1(movedBackward.incident)} '
          'code=${_sensorIncidentCodeV1(movedBackward.incident)} '
          'action=stop_keep_monitoring',
        );
        await _safeSendCommandV1('停止', 0);
        return _ObjectMicroConfirmResultV1(
          usedMicroApproach: true,
          confirmedObject: confirmedObject,
        );
      }
      if (movedBackward.cliffDetected) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] motion_paused_keep_monitoring '
          'reason=cliff_detected',
        );
        return _ObjectMicroConfirmResultV1(
          usedMicroApproach: true,
          cliffDetected: true,
          confirmedObject: confirmedObject,
        );
      }
      _envLogV1(
        '[ENV_V1_OBJECT_MICRO] aborted reason=${movedBackward.error}',
      );
      return _ObjectMicroConfirmResultV1(
        usedMicroApproach: true,
        confirmedObject: confirmedObject,
      );
    }
    _envLogV1('[ENV_V1_OBJECT_MICRO] backward done mm=$approachMm');
    await _safeSendCommandV1('停止', 0);

    return _ObjectMicroConfirmResultV1(
      usedMicroApproach: true,
      confirmedObject: confirmedObject,
    );
  }

  bool _hasReliableObjectCliffGuardV1() {
    return true;
  }

  int _boundedObjectMicroApproachMmV1() {
    if (_objectMicroApproachMmV1 > _objectMicroApproachMaxMmV1) {
      return _objectMicroApproachMaxMmV1;
    }
    return _objectMicroApproachMmV1;
  }

  Future<ObjectDetectionSnapshotResult?> _captureAndDetectObjectMicroSnapshotV1(
    DesktopObjectDetector detector,
  ) async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_OBJECT_MICRO] snapshot skipped reason=camera_unavailable',
        );
        return null;
      }

      final imagePath = await camera.captureImage();
      _envLogV1('[ENV_V1_OBJECT_MICRO] snapshot imagePath=$imagePath');
      final result = await detector.detectDesktopObjectsFromImagePath(
        imagePath,
        minAreaRatio: _objectSmallAreaMinV1,
        maxAreaRatio: _realtimeObjectCandidateMaxAreaRatioV1,
      );
      final topObject = _firstNonPersonObjectV1(result);
      _envLogV1(
        '[ENV_V1_OBJECT_MICRO] detect hasObject=${result.hasObject} '
        'label=${topObject?.label ?? 'none'} '
        'score=${_f(topObject?.confidence ?? 0)} '
        'reason=${result.reason}',
      );
      return result;
    } catch (e) {
      _envLogV1('[ENV_V1_OBJECT_MICRO] detect hasObject=false error=$e');
      return null;
    }
  }

  Future<_LinearMotionGuardResultV1> _sendLinearMotionWithSafetyGuardV1(
    String command,
    int mm, {
    required String phase,
    int? index,
  }) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _envLogV1('[ENV_V1_CHASSIS] unavailable reason=disconnected');
      await _degradeToVoiceExpressionOnly('disconnected');
      return const _LinearMotionGuardResultV1(
        success: false,
        error: 'bluetooth_disconnected',
      );
    }

    try {
      _envV1MotionCommandInFlight = true;
      final effectiveMm = _edgeCautiousLinearDistanceV1(mm, phase: phase);
      final feedback = await service.sendLinearMotionAndAwaitFeedback(
        command,
        effectiveMm,
        timeout: const Duration(seconds: 8),
      );
      if (feedback.kind == LinearMotionEndKind.completed) {
        return const _LinearMotionGuardResultV1(success: true);
      }
      if (feedback.kind == LinearMotionEndKind.interrupted) {
        final incident = _sensorIncidentFromObstacleTypeV1(
          feedback.obstacleType,
        );
        final obstacle = _sensorIncidentNameV1(incident);
        final cliffDetected = _isCliffObstacleTypeV1(feedback.obstacleType);
        if (cliffDetected) {
          if (command == '后退') {
            _envLogV1(
              '[ENV_V1_CLIFF] interrupted command=$command '
              'distanceMm=$effectiveMm phase=$phase '
              'obstacle=0x${feedback.obstacleType.toRadixString(16)}',
            );
            if (!_isRearCliffObstacleTypeV1(feedback.obstacleType)) {
              _envLogV1('[ENV_V1_CLIFF] backward_interrupted phase=$phase');
              _markObjectReturnSafetyStopReasonV1(
                'backward_interrupted_by_cliff',
              );
              await _safeSendCommandV1('停止', 0);
              return _LinearMotionGuardResultV1(
                success: false,
                incident: incident,
                cliffDetected: true,
                safeStopRequired: true,
                error: 'backward_interrupted_by_cliff',
              );
            }
          }

          final recovered = await _recoverFromFrontCliffV1(
            phase: phase,
            interruptedCommand: command,
            interruptedDistanceMm: effectiveMm,
            obstacleType: feedback.obstacleType,
          );
          if (!recovered) {
            _markObjectReturnSafetyStopReasonV1(
              'cliff_recover_failed',
            );
            return _LinearMotionGuardResultV1(
              success: false,
              incident: incident,
              cliffDetected: true,
              safeStopRequired: true,
              error: 'cliff_recover_failed',
            );
          }
          if (command == '前进') {
            _envLogV1(
              '[ENV_V1_CLIFF] forward_interrupted '
              'phase=$phase distanceMm=$effectiveMm',
            );
          }
          return _LinearMotionGuardResultV1(
            success: true,
            incident: incident,
            cliffDetected: true,
            recoverySucceeded: true,
            error: 'cliff_recovered',
          );
        }
        if (_isEdgeCautiousActiveV1()) {
          await _markEdgeRiskSafeStopV1(
            reason: 'unknown_obstacle_after_cliff_recover',
            phase: phase,
          );
          return _LinearMotionGuardResultV1(
            success: false,
            incident: incident,
            safeStopRequired: true,
            error:
                'motion_interrupted_0x${feedback.obstacleType.toRadixString(16)}',
          );
        }
        await _safeSendCommandV1('停止', 0);
        _envLogV1(
          '[ENV_V1_CHASSIS] motion_interrupted_nonfatal '
          'phase=$phase command=$command obstacle=$obstacle '
          'code=0x${feedback.obstacleType.toRadixString(16)}',
        );
        return _LinearMotionGuardResultV1(
          success: false,
          incident: incident,
          error:
              'motion_interrupted_0x${feedback.obstacleType.toRadixString(16)}',
        );
      }

      await _safeSendCommandV1('停止', 0);
      return const _LinearMotionGuardResultV1(
        success: false,
        error: 'motion_timed_out',
      );
    } catch (e) {
      _envLogV1(
        '[ENV_V1_CHASSIS] linear_motion_failed '
        'phase=$phase command=$command mm=$mm error=$e',
      );
      await _degradeToVoiceExpressionOnly('linear_motion_failed');
      return _LinearMotionGuardResultV1(
        success: false,
        error: 'linear_motion_exception:$e',
      );
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  bool _isCliffObstacleTypeV1(int obstacleType) {
    return obstacleType == 0x03 || obstacleType == 0x04;
  }

  bool _isFrontCliffObstacleTypeV1(int obstacleType) {
    return obstacleType == 0x03;
  }

  bool _isRearCliffObstacleTypeV1(int obstacleType) {
    return obstacleType == 0x04;
  }

  _ChassisSensorIncidentV1 _sensorIncidentFromObstacleTypeV1(
    int obstacleType,
  ) {
    switch (obstacleType) {
      case 0x01:
        return _ChassisSensorIncidentV1.frontObstacle;
      case 0x02:
        return _ChassisSensorIncidentV1.rearObstacle;
      case 0x03:
        return _ChassisSensorIncidentV1.frontCliff;
      case 0x04:
        return _ChassisSensorIncidentV1.rearCliff;
      default:
        return _ChassisSensorIncidentV1.unknown;
    }
  }

  String _sensorIncidentNameV1(_ChassisSensorIncidentV1 incident) {
    switch (incident) {
      case _ChassisSensorIncidentV1.frontObstacle:
        return 'front_obstacle';
      case _ChassisSensorIncidentV1.rearObstacle:
        return 'rear_obstacle';
      case _ChassisSensorIncidentV1.frontCliff:
        return 'front_cliff';
      case _ChassisSensorIncidentV1.rearCliff:
        return 'rear_cliff';
      case _ChassisSensorIncidentV1.unknown:
        return 'unknown';
      case _ChassisSensorIncidentV1.none:
        return 'none';
    }
  }

  String _sensorIncidentCodeV1(_ChassisSensorIncidentV1 incident) {
    switch (incident) {
      case _ChassisSensorIncidentV1.frontObstacle:
        return '0x1';
      case _ChassisSensorIncidentV1.rearObstacle:
        return '0x2';
      case _ChassisSensorIncidentV1.frontCliff:
        return '0x3';
      case _ChassisSensorIncidentV1.rearCliff:
        return '0x4';
      case _ChassisSensorIncidentV1.unknown:
      case _ChassisSensorIncidentV1.none:
        return 'unknown';
    }
  }

  bool _isNonFatalSensorIncidentV1(_ChassisSensorIncidentV1 incident) {
    return incident == _ChassisSensorIncidentV1.frontObstacle ||
        incident == _ChassisSensorIncidentV1.rearObstacle ||
        incident == _ChassisSensorIncidentV1.frontCliff ||
        incident == _ChassisSensorIncidentV1.rearCliff;
  }

  bool _isFrontCliffAutoBackoffByBluetoothV1() {
    return MyBluetoothService.kEnableFrontSafetyRecover;
  }

  bool _isRearCliffAutoBackoffByBluetoothV1() {
    return MyBluetoothService.kEnableRearSafetyRecover;
  }

  bool _isEdgeCautiousActiveV1() {
    if (!_envV1EdgeCautiousMode) {
      return false;
    }
    final until = _envV1EdgeCautiousUntil;
    if (until != null && DateTime.now().isAfter(until)) {
      _envV1EdgeCautiousMode = false;
      _envV1EdgeCautiousUntil = null;
      _envLogV1('[ENV_V1_EDGE] cautious_mode exit reason=expired');
      return false;
    }
    return true;
  }

  void _enterEdgeCautiousModeV1({required String reason}) {
    _envV1EdgeCautiousMode = true;
    _envV1EdgeCautiousUntil = DateTime.now().add(_edgeCautiousDurationV1);
    _envLogV1(
      '[ENV_V1_EDGE] cautious_mode enter '
      'durationSec=${_edgeCautiousDurationV1.inSeconds} '
      'reason=$reason',
    );
  }

  String _edgePhaseLabelV1(String phase) {
    if (phase == 'probe_forward') {
      return 'object_probe_forward';
    }
    if (phase == 'probe_backward') {
      return 'object_probe_backward';
    }
    if (phase == 'object_return_full_circle_scan') {
      return 'object_return_scan';
    }
    if (phase == 'object_return_candidate_local_search') {
      return 'object_return_local_search';
    }
    return phase;
  }

  int _edgeCautiousTurnAngleV1(int angleDeg, {required String phase}) {
    if (!_isEdgeCautiousActiveV1() || angleDeg <= 3) {
      return angleDeg;
    }
    final cap = angleDeg <= 6
        ? _edgeCautiousTurnSmallCapDegV1
        : _edgeCautiousTurnLargeCapDegV1;
    final capped = angleDeg > cap ? cap : angleDeg;
    if (capped != angleDeg) {
      _envLogV1(
        '[ENV_V1_EDGE] cautious cap turnAngle '
        'original=$angleDeg capped=$capped '
        'phase=${_edgePhaseLabelV1(phase)}',
      );
    }
    return capped;
  }

  int _edgeCautiousLinearDistanceV1(int distanceMm, {required String phase}) {
    if (!_isEdgeCautiousActiveV1() ||
        distanceMm <= _edgeCautiousLinearCapMmV1) {
      return distanceMm;
    }
    _envLogV1(
      '[ENV_V1_EDGE] cautious cap linearDistance '
      'original=$distanceMm capped=$_edgeCautiousLinearCapMmV1 '
      'phase=${_edgePhaseLabelV1(phase)}',
    );
    return _edgeCautiousLinearCapMmV1;
  }

  bool _isBluetoothEdgeRiskHighV1() {
    final service = _bluetoothService;
    return service != null &&
        (service.edgeRiskHigh ||
            service.wheelMayBeOffTable ||
            service.lastSafetyRecoverFailed);
  }

  Future<bool> _waitForBluetoothSafetyRecoverIdleV1({
    required int obstacleType,
  }) async {
    final service = _bluetoothService;
    if (service == null) {
      return true;
    }
    final observedAfter = DateTime.now().subtract(
      const Duration(milliseconds: 300),
    );
    bool recoveryObserved() {
      final recoverAt = service.lastSafetyRecoverAt;
      return service.isSafetyRecovering ||
          (service.lastSafetyRecoverObstacleType == obstacleType &&
              recoverAt != null &&
              !recoverAt.isBefore(observedAfter));
    }

    final startDeadline = DateTime.now().add(
      const Duration(milliseconds: 700),
    );
    while (!recoveryObserved() && DateTime.now().isBefore(startDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (!recoveryObserved()) {
      return false;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (service.isSafetyRecovering && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return !service.isSafetyRecovering;
  }

  Future<void> _markEdgeRiskSafeStopV1({
    required String reason,
    required String phase,
  }) async {
    _envLogV1(
      '[ENV_V1_SAFE_STOP] reason=$reason '
      'action=motion_paused_keep_monitoring '
      'phase=${_edgePhaseLabelV1(phase)}',
    );
    _markObjectReturnSafetyStopReasonV1(reason);
    await _safeSendCommandV1('停止', 0);
    _envLogV1(
      '[ENV_V1] keep_alive_after_safe_stop active=$_isEnvironmentMonitoring',
    );
  }

  void _logContinueAfterEdgeRecoverV1(String phase) {
    if (phase.startsWith('object_probe') || phase.startsWith('probe_')) {
      _envLogV1('[ENV_V1_OBJECT] continue_after_edge_recover cautious=true');
      return;
    }
    if (phase.startsWith('object_return') || phase == 'final_center_recenter') {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] continue_after_edge_recover cautious=true',
      );
    }
  }

  Future<bool> _recoverFromFrontCliffV1({
    required String phase,
    required String interruptedCommand,
    required int obstacleType,
    int? interruptedAngleDeg,
    int? interruptedDistanceMm,
    int backoffMm = _frontCliffBackoffMmV1,
  }) async {
    if (!_isCliffObstacleTypeV1(obstacleType)) {
      _envLogV1(
        '[ENV_V1_CLIFF] recover failed phase=$phase '
        'reason=not_cliff obstacle=0x${obstacleType.toRadixString(16)}',
      );
      return false;
    }

    final isFrontCliff = _isFrontCliffObstacleTypeV1(obstacleType);
    final isRearCliff = _isRearCliffObstacleTypeV1(obstacleType);
    final recoveredReason =
        isRearCliff ? 'rear_cliff_recovered' : 'front_cliff_recovered';
    final cautiousReason = isRearCliff ? 'rear_cliff' : 'front_cliff';
    final angleText =
        interruptedAngleDeg == null ? '' : ' angle=$interruptedAngleDeg';
    final distanceText = interruptedDistanceMm == null
        ? ''
        : ' distanceMm=$interruptedDistanceMm';
    _envLogV1(
      '[ENV_V1_CLIFF] interrupted command=$interruptedCommand'
      '$angleText$distanceText phase=$phase '
      'obstacle=0x${obstacleType.toRadixString(16)}',
    );
    _envLogV1(
      '[ENV_V1_CLIFF] recover start phase=$phase backoffMm=$backoffMm',
    );

    final bluetoothOwnsBackoff =
        (isFrontCliff && _isFrontCliffAutoBackoffByBluetoothV1()) ||
            (isRearCliff && _isRearCliffAutoBackoffByBluetoothV1());
    if (bluetoothOwnsBackoff) {
      _envLogV1('[ENV_V1_CLIFF] stop_owner=bluetooth_service');
    } else {
      if (!await _safeSendCommandV1('停止', 0)) {
        _envLogV1(
            '[ENV_V1_CLIFF] recover failed phase=$phase reason=stop_failed');
        _markObjectReturnSafetyStopReasonV1('stop_failed');
        return false;
      }
      _envLogV1('[ENV_V1_CLIFF] stop sent');
    }

    var totalBackoffMm = 0;
    if (bluetoothOwnsBackoff) {
      _envLogV1('[ENV_V1_CLIFF] backoff_owner=bluetooth_service');
      _envLogV1('[ENV_V1_CLIFF] duplicate_backoff_prevented=true');
      final btRecoverIdle = await _waitForBluetoothSafetyRecoverIdleV1(
        obstacleType: obstacleType,
      );
      if (!btRecoverIdle || _isBluetoothEdgeRiskHighV1()) {
        await _markEdgeRiskSafeStopV1(
          reason: 'wheel_may_be_off_table',
          phase: phase,
        );
        return false;
      }
      totalBackoffMm += isRearCliff
          ? MyBluetoothService.kRearSafetyRecoverDistanceMm
          : _frontCliffBtAutoBackoffMmV1;
    } else {
      _envLogV1('[ENV_V1_CLIFF] backoff_owner=env_v1');
      final backedOff = await _sendCliffBackoffSafeV1(
        phase: phase,
        command: isRearCliff ? '前进' : '后退',
        mm: backoffMm,
        failureReason: isRearCliff
            ? 'rear_cliff_recover_failed'
            : 'front_cliff_recover_failed',
      );
      if (!backedOff) {
        return false;
      }
      totalBackoffMm += backoffMm;
      _envLogV1('[ENV_V1_CLIFF] recover backoff mm=$backoffMm');
    }

    await _safeSendCommandV1('停止', 0);
    _envLogV1('[ENV_V1_CLIFF] recover stop_after_backoff');
    await Future<void>.delayed(
      const Duration(milliseconds: _frontCliffRecoverSettleMsV1),
    );
    _envLogV1('[ENV_V1_CLIFF] recover totalBackoffMm~=$totalBackoffMm');
    _envLogV1(
      '[ENV_V1_CLIFF] recover settleMs=$_frontCliffRecoverSettleMsV1',
    );
    _envLogV1('[ENV_V1_CLIFF] recover done phase=$phase');
    _envLogV1('[ENV_V1_EDGE] $recoveredReason keep_monitoring=true');
    _enterEdgeCautiousModeV1(reason: cautiousReason);
    _logContinueAfterEdgeRecoverV1(phase);
    return true;
  }

  Future<bool> _sendCliffBackoffSafeV1({
    required String phase,
    required String command,
    required int mm,
    required String failureReason,
  }) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _envLogV1(
        '[ENV_V1_CLIFF] recover failed '
        'phase=$phase reason=bluetooth_disconnected',
      );
      _markObjectReturnSafetyStopReasonV1('bluetooth_disconnected');
      return false;
    }

    final feedback = await service.sendLinearMotionAndAwaitFeedback(
      command,
      mm,
      timeout: const Duration(seconds: 8),
    );
    if (feedback.kind == LinearMotionEndKind.completed) {
      return true;
    }

    if (feedback.kind == LinearMotionEndKind.interrupted &&
        _isCliffObstacleTypeV1(feedback.obstacleType)) {
      _envLogV1('[ENV_V1_CLIFF] backoff_interrupted phase=$phase');
      _markObjectReturnSafetyStopReasonV1('backoff_not_safe');
      await _safeSendCommandV1('停止', 0);
      return false;
    }

    _envLogV1(
      '[ENV_V1_CLIFF] recover failed phase=$phase reason=$failureReason',
    );
    _markObjectReturnSafetyStopReasonV1(failureReason);
    await _safeSendCommandV1('停止', 0);
    return false;
  }

  Future<_ObjectProbeRunResultV1> _handleObjectProbeForwardSensorIncidentV1(
    DesktopObjectDetector detector,
    _ObjectProbePlanV1 plan, {
    required int index,
    required _ChassisSensorIncidentV1 incident,
    required int sessionGenericSpeechCount,
    required int probeSpeechCount,
    required int genericSpeechCountDelta,
  }) async {
    final obstacle = _sensorIncidentNameV1(incident);
    final code = _sensorIncidentCodeV1(incident);
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] forward_interrupted '
      'obstacle=$obstacle code=$code action=skip_forward_keep_monitoring',
    );
    await _safeSendCommandV1('停止', 0);

    if (incident == _ChassisSensorIncidentV1.frontObstacle) {
      final realtimeCandidate = _recentRealtimeObject;
      if (realtimeCandidate != null) {
        final policy = _objectPolicyForV1(realtimeCandidate);
        if (_isRealtimeGenericCandidateV1(realtimeCandidate)) {
          _logGenericVisualObjectCandidateV1(
            '[ENV_V1_OBJECT] generic_visual_candidate',
            realtimeCandidate,
          );
          _envLogV1(
            '[ENV_V1_OBJECT_PROBE] realtime_candidate_on_obstacle '
            'label=${realtimeCandidate.label} '
            'policy=${_objectPolicyNameV1(policy)}',
          );
          final decision = _ObjectProbeDecisionV1(
            object: realtimeCandidate,
            source: 'generic_visual_presence',
            speechMode: _ObjectSpeechModeV1.genericVisualPresence,
            reason: 'front_obstacle_with_generic_visual_presence',
            realtimeHits: _recentRealtimeObjectSamplesV1.length,
            policy: policy,
          );
          _envLogV1(
            '[ENV_V1_OBJECT_PROBE] merged_result found=true '
            'source=${decision.source} label=${realtimeCandidate.label}',
          );
          final spokenMode = await _speakObjectObservationV1(
            decision,
            probeIndex: index,
            sessionGenericSpeechCount: sessionGenericSpeechCount,
            probeSpeechCount: probeSpeechCount,
          );
          var nextGenericDelta = genericSpeechCountDelta;
          if (_isGenericObjectSpeechModeV1(spokenMode)) {
            nextGenericDelta++;
          }

          final restored = await _turnBackObjectProbeAfterSensorIncidentV1(
            plan,
            index: index,
            reason: 'front_obstacle_candidate',
          );
          return _ObjectProbeRunResultV1(
            restoredToAnchor: restored,
            foundObject: true,
            shouldContinue: false,
            finishedGracefully: true,
            bestObject: realtimeCandidate,
            bestSource: decision.source,
            genericSpeechCountDelta: nextGenericDelta,
          );
        }
      }

      final snapshot = await _captureAndDetectObjectProbeSnapshotV1(detector);
      final snapshotObject =
          snapshot == null ? null : _firstNonPersonObjectV1(snapshot);
      if (snapshotObject != null) {
        final policy = _objectPolicyForV1(snapshotObject);
        if (_isGenericVisualObjectPresenceV1(snapshotObject)) {
          _logGenericVisualObjectCandidateV1(
            '[ENV_V1_OBJECT_PROBE] snapshot_generic_visual_candidate',
            snapshotObject,
          );
          final decision = _ObjectProbeDecisionV1(
            object: snapshotObject,
            source: 'generic_visual_presence',
            speechMode: _ObjectSpeechModeV1.genericVisualPresence,
            reason: '${obstacle}_with_generic_visual_presence',
            policy: policy,
          );
          _envLogV1(
            '[ENV_V1_OBJECT_PROBE] merged_result found=true '
            'source=${decision.source} label=${snapshotObject.label}',
          );
          final spokenMode = await _speakObjectObservationV1(
            decision,
            probeIndex: index,
            sessionGenericSpeechCount: sessionGenericSpeechCount,
            probeSpeechCount: probeSpeechCount,
          );
          var nextGenericDelta = genericSpeechCountDelta;
          if (_isGenericObjectSpeechModeV1(spokenMode)) {
            nextGenericDelta++;
          }

          final restored = await _turnBackObjectProbeAfterSensorIncidentV1(
            plan,
            index: index,
            reason: 'forward_interrupt_candidate',
          );
          return _ObjectProbeRunResultV1(
            restoredToAnchor: restored,
            foundObject: true,
            shouldContinue: false,
            finishedGracefully: true,
            bestObject: snapshotObject,
            bestSource: decision.source,
            genericSpeechCountDelta: nextGenericDelta,
          );
        }
      }
    }

    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] object_look_continue '
      'reason=${obstacle}_not_fatal',
    );
    final restored = await _turnBackObjectProbeAfterSensorIncidentV1(
      plan,
      index: index,
      reason: obstacle,
    );
    return _ObjectProbeRunResultV1(
      restoredToAnchor: restored,
      foundObject: false,
      shouldContinue: true,
      genericSpeechCountDelta: genericSpeechCountDelta,
    );
  }

  Future<bool> _turnBackObjectProbeAfterSensorIncidentV1(
    _ObjectProbePlanV1 plan, {
    required int index,
    required String reason,
  }) async {
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] restore_after_sensor_incident '
      'start index=$index reason=$reason',
    );
    final turnedBack = await _safeSendCommandV1WithPhase(
      plan.turnBackCommand,
      plan.turnAngleDeg,
      phase: 'object_probe_turn_back',
    );
    if (!turnedBack) {
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] anchor_restore_partial '
        'reason=$reason',
      );
      await _safeSendCommandV1('停止', 0);
      return false;
    }
    await _safeSendCommandV1('停止', 0);
    await Future<void>.delayed(_settleDelay);
    _envLogV1('[ENV_V1_OBJECT_PROBE] restored_to_anchor index=$index');
    return true;
  }

  Future<bool> _restoreObjectProbeAfterFailedForwardV1(
    _ObjectProbePlanV1 plan, {
    required int index,
    required int forwardMm,
  }) async {
    var restored = true;
    final movedBackward = await _safeSendCommandV1('后退', forwardMm);
    if (movedBackward) {
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] backward done index=$index mm=$forwardMm',
      );
    } else {
      restored = false;
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] failed phase=backward '
        'index=$index error=recover_after_forward_failed',
      );
    }

    final turnedBack = await _safeSendCommandV1WithPhase(
      plan.turnBackCommand,
      plan.turnAngleDeg,
      phase: 'object_probe_turn_back',
    );
    if (turnedBack) {
      _envLogV1('[ENV_V1_OBJECT_PROBE] turn_back done index=$index');
    } else {
      restored = false;
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] failed phase=turn_back '
        'index=$index error=recover_after_forward_failed',
      );
    }

    await _safeSendCommandV1('停止', 0);
    if (restored) {
      _envLogV1('[ENV_V1_OBJECT_PROBE] restored_to_anchor index=$index');
    }
    return restored;
  }

  Future<void> _failObjectProbeV1({
    required String phase,
    required int index,
    required String error,
  }) async {
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] failed phase=$phase '
      'index=$index error=$error',
    );
    await _safeSendCommandV1('停止', 0);
  }

  Future<ObjectDetectionSnapshotResult?> _captureAndDetectObjectProbeSnapshotV1(
    DesktopObjectDetector detector,
  ) async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_OBJECT_PROBE] snapshot skipped reason=camera_unavailable',
        );
        return null;
      }

      final imagePath = await camera.captureImage();
      _envLogV1('[ENV_V1_OBJECT_PROBE] snapshot imagePath=$imagePath');

      final result =
          await detector.detectDesktopObjectsFromImagePath(imagePath);
      final topObject = _firstNonPersonObjectV1(result);
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] detect hasObject=${result.hasObject} '
        'label=${topObject?.label ?? 'none'} '
        'score=${_f(topObject?.confidence ?? 0)} '
        'reason=${result.reason}',
      );
      return result;
    } catch (e) {
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] detect hasObject=false error=$e',
      );
      return null;
    }
  }

  _ObjectProbeDecisionV1 _decideObjectProbeCandidateV1({
    required DetectedDesktopObject? snapshotObject,
    required _RealtimeObjectProbeAnalysisV1 realtimeAnalysis,
  }) {
    if (snapshotObject != null) {
      final snapshotPolicy = _objectPolicyForV1(snapshotObject);
      _logObjectLabelPolicyV1(snapshotObject, snapshotPolicy);
      if (_isGenericVisualObjectPresenceV1(snapshotObject)) {
        _logGenericVisualObjectCandidateV1(
          '[ENV_V1_OBJECT_PROBE] snapshot_generic_visual_candidate',
          snapshotObject,
        );
        return _ObjectProbeDecisionV1(
          object: snapshotObject,
          source: 'generic_visual_presence',
          speechMode: _ObjectSpeechModeV1.genericVisualPresence,
          reason: 'non_person_visual_presence',
          realtimeHits: realtimeAnalysis.bestHits,
          policy: snapshotPolicy,
        );
      }
    }

    final realtimeCandidate =
        realtimeAnalysis.stableCandidate ?? realtimeAnalysis.bestLowCandidate;
    if (realtimeCandidate != null) {
      final realtimePolicy =
          realtimeAnalysis.bestPolicy ?? _objectPolicyForV1(realtimeCandidate);
      _logObjectLabelPolicyV1(realtimeCandidate, realtimePolicy);
      if (_isRealtimeGenericCandidateV1(realtimeCandidate)) {
        _logGenericVisualObjectCandidateV1(
          '[ENV_V1_OBJECT] generic_visual_candidate',
          realtimeCandidate,
        );
        return _ObjectProbeDecisionV1(
          object: realtimeCandidate,
          source: 'generic_visual_presence',
          speechMode: _ObjectSpeechModeV1.genericVisualPresence,
          reason: 'non_person_visual_presence',
          realtimeHits: realtimeAnalysis.bestHits,
          policy: realtimePolicy,
        );
      }
    }

    if (snapshotObject != null) {
      final snapshotPolicy = _objectPolicyForV1(snapshotObject);
      _logIgnoredObjectV1(snapshotObject, snapshotPolicy);
      return _ObjectProbeDecisionV1(
        object: null,
        source: 'no_object_found',
        speechMode: _ObjectSpeechModeV1.none,
        reason: 'no_generic_visual_presence',
        realtimeHits: realtimeAnalysis.bestHits,
        rejectedObject: snapshotObject,
        policy: snapshotPolicy,
      );
    }

    if (realtimeCandidate != null) {
      final realtimePolicy =
          realtimeAnalysis.bestPolicy ?? _objectPolicyForV1(realtimeCandidate);
      return _ObjectProbeDecisionV1(
        object: null,
        source: 'no_object_found',
        speechMode: _ObjectSpeechModeV1.none,
        reason: 'no_generic_visual_presence',
        realtimeHits: realtimeAnalysis.bestHits,
        rejectedObject: realtimeCandidate,
        policy: realtimePolicy,
      );
    }

    return _ObjectProbeDecisionV1(
      object: null,
      source: 'none',
      speechMode: _ObjectSpeechModeV1.none,
      reason: 'no_object',
      realtimeHits: realtimeAnalysis.bestHits,
    );
  }

  EnvV1ObjectPolicy _objectPolicyForV1(DetectedDesktopObject object) {
    final label = _normalizeObjectLabelV1(object.label);
    if (_officeImpossibleObjectLabelsV1.contains(label)) {
      return EnvV1ObjectPolicy.officeImpossible;
    }
    if (_officeAnimalLabelsV1.contains(label)) {
      return EnvV1ObjectPolicy.officeAnimal;
    }
    if (_officeLargeBackgroundLabelsV1.contains(label)) {
      return EnvV1ObjectPolicy.largeBackground;
    }
    if (_toyLikeObjectLabelsV1.contains(label)) {
      return EnvV1ObjectPolicy.toyLike;
    }
    if (_officeInteractableObjectLabelsV1.contains(label)) {
      return EnvV1ObjectPolicy.officeInteractable;
    }
    return EnvV1ObjectPolicy.unknown;
  }

  bool _isObjectEligibleForObjectLookV1(
    DetectedDesktopObject object,
  ) {
    return _isGenericVisualObjectPresenceV1(object);
  }

  bool _isObjectPolicyInteractiveV1(EnvV1ObjectPolicy policy) {
    return policy == EnvV1ObjectPolicy.officeInteractable ||
        policy == EnvV1ObjectPolicy.toyLike;
  }

  bool _isRealtimeGenericCandidateV1(
    DetectedDesktopObject object,
  ) {
    return _isGenericVisualObjectPresenceV1(
      object,
      minConfidence: _objectGenericVisualPresenceScoreV1,
    );
  }

  bool _isGenericVisualObjectPresenceV1(
    DetectedDesktopObject object, {
    double minConfidence = _objectGenericVisualPresenceScoreV1,
  }) {
    return !_isPersonObjectLabelV1(object.label) &&
        object.confidence >= minConfidence &&
        object.width > 0 &&
        object.height > 0 &&
        object.areaRatio >= _objectGenericVisualPresenceMinAreaV1 &&
        object.areaRatio <= _objectGenericVisualPresenceMaxAreaV1 &&
        object.centerX >= 0.0 &&
        object.centerX <= 1.0 &&
        object.centerY >= 0.0 &&
        object.centerY <= 1.0;
  }

  void _logObjectLabelPolicyV1(
    DetectedDesktopObject object,
    EnvV1ObjectPolicy policy,
  ) {
    final genericVisualPresence = _isGenericVisualObjectPresenceV1(object);
    final action = genericVisualPresence
        ? 'generic_visual_presence'
        : _objectPolicyActionV1(policy);
    _envLogV1(
      '[ENV_V1_OBJECT] label_policy label=${object.label} '
      'policy=${_objectPolicyNameV1(policy)} '
      'action=$action '
      'score=${_f(object.confidence)} area=${_f(object.areaRatio)}',
    );
  }

  void _logIgnoredObjectV1(
    DetectedDesktopObject object,
    EnvV1ObjectPolicy policy,
  ) {
    final reason = _objectDecisionReasonForPolicyV1(policy);
    _envLogV1(
      '[ENV_V1_OBJECT] ignored_object label=${object.label} '
      'policy=${_objectPolicyNameV1(policy)} '
      'score=${_f(object.confidence)} area=${_f(object.areaRatio)} '
      'reason=$reason',
    );
  }

  void _logGenericVisualObjectCandidateV1(
    String prefix,
    DetectedDesktopObject object,
  ) {
    _envLogV1(
      '$prefix label=${object.label} score=${_f(object.confidence)} '
      'area=${_f(object.areaRatio)} reason=non_person_visual_presence',
    );
  }

  String _objectPolicyNameV1(EnvV1ObjectPolicy policy) {
    switch (policy) {
      case EnvV1ObjectPolicy.officeInteractable:
        return 'office_interactable';
      case EnvV1ObjectPolicy.toyLike:
        return 'toy_like';
      case EnvV1ObjectPolicy.largeBackground:
        return 'large_background';
      case EnvV1ObjectPolicy.officeImpossible:
        return 'office_impossible';
      case EnvV1ObjectPolicy.officeAnimal:
        return 'office_animal';
      case EnvV1ObjectPolicy.unknown:
        return 'unknown';
    }
  }

  String _objectPolicyActionV1(EnvV1ObjectPolicy policy) {
    switch (policy) {
      case EnvV1ObjectPolicy.officeInteractable:
      case EnvV1ObjectPolicy.toyLike:
        return 'allow';
      case EnvV1ObjectPolicy.largeBackground:
        return 'log_only';
      case EnvV1ObjectPolicy.officeImpossible:
      case EnvV1ObjectPolicy.officeAnimal:
        return 'hard_block';
      case EnvV1ObjectPolicy.unknown:
        return 'ignored';
    }
  }

  String _objectDecisionReasonForPolicyV1(EnvV1ObjectPolicy policy) {
    switch (policy) {
      case EnvV1ObjectPolicy.officeInteractable:
      case EnvV1ObjectPolicy.toyLike:
        return 'not_stable_or_low_score';
      case EnvV1ObjectPolicy.largeBackground:
        return 'large_background';
      case EnvV1ObjectPolicy.officeImpossible:
        return 'office_impossible';
      case EnvV1ObjectPolicy.officeAnimal:
        return 'office_animal';
      case EnvV1ObjectPolicy.unknown:
        return 'unknown_label';
    }
  }

  DetectedDesktopObject? _firstNonPersonObjectV1(
    ObjectDetectionSnapshotResult result,
  ) {
    DetectedDesktopObject? firstNonPerson;
    for (final object in result.objects) {
      if (!_isPersonObjectLabelV1(object.label)) {
        firstNonPerson ??= object;
        if (_isObjectEligibleForObjectLookV1(object)) {
          return object;
        }
      }
    }
    return firstNonPerson;
  }

  Future<_ObjectSpeechModeV1> _speakObjectObservationV1(
    _ObjectProbeDecisionV1 decision, {
    required int probeIndex,
    required int sessionGenericSpeechCount,
    required int probeSpeechCount,
  }) async {
    if (!_enableWeakObjectSpeechV1) {
      _envLogV1(
          '[ENV_V1_OBJECT] object_speech skipped reason=feature_disabled');
      return _ObjectSpeechModeV1.none;
    }
    final object = decision.object;
    if (object == null) {
      final rejected = decision.rejectedObject;
      final reason = decision.source == 'realtime_low_only' &&
              _isObjectPolicyInteractiveV1(decision.policy)
          ? 'realtime_low_candidate_not_stable'
          : decision.reason;
      _envLogV1(
        '[ENV_V1_OBJECT] object_speech skipped reason=$reason '
        'label=${rejected?.label ?? 'none'} '
        'policy=${_objectPolicyNameV1(decision.policy)} '
        'source=${decision.source} probe=$probeIndex',
      );
      return _ObjectSpeechModeV1.none;
    }
    if (probeSpeechCount >= _objectPerProbeMaxSpeechCountV1) {
      _envLogV1(
        '[ENV_V1_OBJECT] object_speech skipped '
        'reason=probe_speech_limit_reached index=$probeIndex '
        'count=$probeSpeechCount',
      );
      return _ObjectSpeechModeV1.none;
    }

    final label = object.label.trim();
    final score = object.confidence;
    if (_isPersonObjectLabelV1(label)) {
      _envLogV1(
        '[ENV_V1_OBJECT] object_speech skipped '
        'reason=person label=$label score=${_f(score)}',
      );
      return _ObjectSpeechModeV1.none;
    }

    if (decision.speechMode == _ObjectSpeechModeV1.genericVisualPresence) {
      if (sessionGenericSpeechCount >= _objectGenericSpeechMaxPerSessionV1) {
        _envLogV1(
          '[ENV_V1_OBJECT] object_speech skipped '
          'reason=generic_speech_already_spoken probe=$probeIndex',
        );
        return _ObjectSpeechModeV1.none;
      }
      const text = '我好像看到一个小东西。';
      _envLogV1(
        '[ENV_V1_OBJECT] object_speech mode=generic_visual_presence '
        'reason=${decision.reason} label=$label score=${_f(score)} text=$text',
      );
      await speakWithInterruptProtection(text);
      _envLogV1(
        '[ENV_V1_OBJECT] object_interact silent_observe '
        'ms=$_objectWeakFallbackSilentObserveMsV1 '
        'reason=generic_visual_presence',
      );
      await Future<void>.delayed(
        const Duration(milliseconds: _objectWeakFallbackSilentObserveMsV1),
      );
      return _ObjectSpeechModeV1.genericVisualPresence;
    }

    _envLogV1(
      '[ENV_V1_OBJECT] object_speech skipped '
      'reason=${decision.reason} source=${decision.source} probe=$probeIndex',
    );
    return _ObjectSpeechModeV1.none;
  }

  bool _shouldSilentObserveObjectDecisionV1(
    _ObjectProbeDecisionV1 decision,
  ) {
    return _isGenericObjectSpeechModeV1(decision.speechMode) &&
        _objectGenericSpeechCountV1 >= _objectGenericSpeechMaxPerSessionV1;
  }

  bool _isGenericObjectSpeechModeV1(_ObjectSpeechModeV1 mode) {
    return mode == _ObjectSpeechModeV1.genericVisualPresence;
  }

  String _normalizeObjectLabelV1(String label) {
    return label.toLowerCase().trim();
  }

  bool _isPersonObjectLabelV1(String label) {
    final normalized = _normalizeObjectLabelV1(label);
    return normalized == 'person' ||
        normalized == 'people' ||
        normalized == '人';
  }

  Future<bool> _returnToOwnerAfterObjectLookV1(
    int accumulatedTurnDeg,
    String returnDirection,
  ) async {
    final boundedTurnDeg = accumulatedTurnDeg < 0 ? 0 : accumulatedTurnDeg;
    _monitorStatus = 'OBJECT_RETURN: 回到主人方向';
    final stoppedBeforeSpeech = await _safeSendCommandV1('停止', 0);
    if (!stoppedBeforeSpeech) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] approximate_return failed reason=pre_speech_stop',
      );
      return false;
    }

    const returnText = '主人，我回来找你啦。';
    _envLogV1('[ENV_V1_OBJECT_RETURN] speak_return_owner text=$returnText');
    await speakWithInterruptProtection(returnText);
    if (!_isEnvironmentMonitoring) {
      return false;
    }
    if (!_isBluetoothConnectedV1()) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] approximate_return failed '
        'reason=bluetooth_disconnected_after_speech',
      );
      return false;
    }
    final stoppedAfterSpeech = await _safeSendCommandV1('停止', 0);
    if (!stoppedAfterSpeech) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] approximate_return failed reason=post_speech_stop',
      );
      return false;
    }

    if (boundedTurnDeg <= 0) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] return_owner_approx skipped '
        'reason=anchor_probe_restored',
      );
      return true;
    }

    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] return_owner_approx start '
      'accumulated=$boundedTurnDeg direction=$returnDirection',
    );

    final moved = await _safeSendCommandV1WithPhase(
      returnDirection,
      boundedTurnDeg,
      phase: 'object_return_approx',
    );
    if (!moved) {
      _envLogV1('[ENV_V1_OBJECT_RETURN] approximate_return failed reason=turn');
      return false;
    }
    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      _envLogV1('[ENV_V1_OBJECT_RETURN] approximate_return failed reason=stop');
      return false;
    }
    await Future<void>.delayed(_settleDelay);
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] approximate_return done '
      'accumulated=$boundedTurnDeg',
    );
    return true;
  }

  Future<SnapshotAlignResult> _reconfirmOwnerAfterObjectLookV1({
    bool forceResearch = false,
  }) async {
    return _runObjectReturnUntilFaceCenteredV1(forceResearch: forceResearch);
  }

  Future<SnapshotAlignResult> _runObjectReturnUntilFaceCenteredV1({
    required bool forceResearch,
  }) async {
    _monitorStatus = 'OBJECT_RETURN: 强制回主人居中';
    _stopIdleRecenterAfterObjectReturnV1(reason: 'object_return_started');
    _objectReturnSafeStopWaitingV1 = false;
    _objectReturnPendingSafeStopReasonV1 = null;
    _envLogV1('[ENV_V1_OBJECT_RETURN] must_center_before_done=true');
    if (forceResearch) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] force_research_ignored '
        'reason=direct_full_circle_scan',
      );
    }
    await _restartRealtimeHumanDetectionForObjectReturnV1();

    final safetyReason = _objectReturnSafetyStopReasonV1();
    if (safetyReason != null) {
      return _enterObjectReturnSafeStopWaitForOwnerV1(
        reason: safetyReason,
        lastResult: SnapshotAlignResult.noTarget(),
      );
    }

    final finalResult = await _runObjectReturnFullCircleScanV1();
    if (_isObjectReturnSuccessfulStatusV1(finalResult.finalAlignmentStatus)) {
      await _finishObjectReturnSuccessV1(finalResult);
      return finalResult;
    }

    final afterScanSafetyReason = _objectReturnSafetyStopReasonV1();
    if (afterScanSafetyReason != null) {
      return _enterObjectReturnSafeStopWaitForOwnerV1(
        reason: afterScanSafetyReason,
        lastResult: finalResult,
      );
    }

    _envLogV1(
      '[ENV_V1_OBJECT_RETURN_SCAN] full_circle_done '
      'rounds=$_objectReturnFullCircleMaxRoundsV1 centered=false',
    );
    return _enterObjectReturnSafeStopWaitForOwnerV1(
      reason: 'full_circle_no_centered_owner',
      lastResult: finalResult,
    );
  }

  Future<SnapshotAlignResult> _runObjectReturnFullCircleScanV1() async {
    _monitorStatus = 'OBJECT_RETURN: 360度分段找主人';
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN_SCAN] start mode=full_circle_segmented '
      'stepDeg=$_objectReturnFullCircleStepDegV1 '
      'maxRounds=$_objectReturnFullCircleMaxRoundsV1',
    );

    var accumulatedDeg = 0;
    var lastResult = SnapshotAlignResult.noTarget();

    for (var round = 1; round <= _objectReturnFullCircleMaxRoundsV1; round++) {
      if (!_isEnvironmentMonitoring) return lastResult;

      final safetyReason = _objectReturnSafetyStopReasonV1();
      if (safetyReason != null) {
        _objectReturnPendingSafeStopReasonV1 = safetyReason;
        return lastResult;
      }

      final nextAccumulated = accumulatedDeg + _objectReturnFullCircleStepDegV1;
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] '
        'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
        'turn=right angle=$_objectReturnFullCircleStepDegV1 '
        'accumulated=$nextAccumulated',
      );
      final moved = await _safeSendCommandV1WithPhase(
        '右转',
        _objectReturnFullCircleStepDegV1,
        phase: 'object_return_full_circle_scan',
      );
      if (!moved) {
        if (_consumeTurnSensorIncidentV1(
          'object_return_full_circle_scan',
          logPrefix: '[ENV_V1_OBJECT_RETURN]',
        )) {
          await _safeSendCommandV1('停止', 0);
          continue;
        }
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_SCAN] turn_failed round=$round',
        );
        _markObjectReturnMovementSafetyStopReasonV1();
        return lastResult;
      }
      if (_consumeFrontCliffTurnRecoveryV1(
        'object_return_full_circle_scan',
      )) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_SCAN] resume_after_cliff round=$round',
        );
      }
      accumulatedDeg = nextAccumulated;

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_SCAN] stop_failed round=$round',
        );
        _markObjectReturnMovementSafetyStopReasonV1();
        return lastResult;
      }
      await Future<void>.delayed(
        const Duration(milliseconds: _objectReturnFullCircleSettleMsV1),
      );

      lastResult = await _detectAndAlignObjectReturnFullCircleCandidateV1(
        round: round,
      );
      if (_isObjectReturnSuccessfulStatusV1(lastResult.finalAlignmentStatus)) {
        return lastResult;
      }
      if (_shouldRunObjectReturnCandidateLocalSearchV1(lastResult)) {
        lastResult = await _runObjectReturnCandidateLocalSearchV1(
          round: round,
          lastResult: lastResult,
        );
        if (_isObjectReturnSuccessfulStatusV1(
          lastResult.finalAlignmentStatus,
        )) {
          return lastResult;
        }
      }
      _logObjectReturnContinueStatusV1(lastResult.finalAlignmentStatus);
    }

    await _safeSendCommandV1('停止', 0);
    return lastResult;
  }

  Future<SnapshotAlignResult> _detectAndAlignObjectReturnFullCircleCandidateV1({
    required int round,
  }) async {
    final realtime = _getFreshRealtimeHumanV1();
    if (realtime != null) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] '
        'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
        'detect source=realtime hasHuman=${realtime.hasHuman} '
        'cx=${_f(realtime.centerX)} conf=${_f(realtime.confidence)}',
      );
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] candidate_found '
        'round=$round source=realtime hasHuman=${realtime.hasHuman} '
        'hasFace=false cx=${_f(realtime.centerX)} '
        'conf=${_f(realtime.confidence)}',
      );
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] stop_scan reason=candidate_found',
      );
      await _safeSendCommandV1('停止', 0);
      return _alignAndLogObjectReturnScanCandidateV1(
        realtime,
        round: round,
        source: 'object_return_full_circle_scan_realtime',
        hasHumanAtScan: realtime.hasHuman,
      );
    }

    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_SCAN] '
          'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
          'detect hasHuman=false hasFace=false reason=camera_unavailable',
        );
        return SnapshotAlignResult.noTarget();
      }

      final imagePath = await camera.captureImage();
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] '
        'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
        'snapshot imagePath=$imagePath',
      );
      final face = await camera.detectFaceObservationFromImagePath(imagePath);
      final human = await camera.detectHumanObservationFromImagePath(imagePath);
      final hasReliableHuman = _isReliableHumanObservation(human);
      final candidateCx = face.hasFace ? face.centerX : human.centerX;
      final candidateConf = face.hasFace ? face.confidence : human.confidence;
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] '
        'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
        'detect source=snapshot hasHuman=${human.hasHuman} '
        'hasFace=${face.hasFace} '
        'cx=${_f(candidateCx)} conf=${_f(candidateConf)}',
      );
      if (!_isEnvironmentMonitoring) {
        return SnapshotAlignResult.noTarget(
          humanObservation: human.hasHuman ? human : null,
          imagePath: imagePath,
        );
      }

      if (!face.hasFace && !hasReliableHuman) {
        return SnapshotAlignResult.noTarget(
          humanObservation: human.hasHuman ? human : null,
          imagePath: imagePath,
        );
      }

      final candidateLogPrefix = face.hasFace
          ? '[ENV_V1_OBJECT_RETURN_SCAN] face_candidate_found'
          : '[ENV_V1_OBJECT_RETURN_SCAN] candidate_found';
      _envLogV1(
        '$candidateLogPrefix round=$round source=snapshot '
        'hasHuman=${human.hasHuman} hasFace=${face.hasFace} '
        'cx=${_f(candidateCx)} conf=${_f(candidateConf)}',
      );
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] stop_scan reason=candidate_found',
      );
      await _safeSendCommandV1('停止', 0);

      if (face.hasFace) {
        final faceCandidate = SnapshotAlignResult(
          canProceed: true,
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
          targetType: SnapshotTargetType.face,
          centerX: face.centerX,
          centerY: face.centerY,
          confidence: face.confidence,
          areaRatio: face.areaRatio,
          humanObservation: human.hasHuman ? human : null,
          faceObservation: face,
          imagePath: imagePath,
        );
        return _alignAndLogObjectReturnScanFaceCandidateV1(
          faceCandidate,
          round: round,
          hasHumanAtScan: human.hasHuman,
        );
      }

      return _alignAndLogObjectReturnScanCandidateV1(
        human,
        round: round,
        source: 'object_return_full_circle_scan_human',
        hasHumanAtScan: human.hasHuman,
      );
    } catch (e) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_SCAN] '
        'round=$round/$_objectReturnFullCircleMaxRoundsV1 '
        'detect_failed error=$e',
      );
      return SnapshotAlignResult.noTarget();
    }
  }

  Future<SnapshotAlignResult> _alignAndLogObjectReturnScanCandidateV1(
    HumanObservation human, {
    required int round,
    required String source,
    required bool hasHumanAtScan,
  }) async {
    final finalResult = await _alignObjectReturnCandidateV1(
      human,
      source: source,
      objectReturnTrack: true,
    );
    _logObjectReturnScanCandidateAlignedV1(
      round: round,
      hasHuman: hasHumanAtScan,
      hasFace: finalResult.targetType == SnapshotTargetType.face ||
          finalResult.faceObservation?.hasFace == true,
      status: finalResult.finalAlignmentStatus,
    );
    return finalResult;
  }

  Future<SnapshotAlignResult> _alignAndLogObjectReturnScanFaceCandidateV1(
    SnapshotAlignResult faceCandidate, {
    required int round,
    required bool hasHumanAtScan,
  }) async {
    final finalResult = await _alignObjectReturnFaceDirectV1(
      faceCandidate,
      source: 'object_return_scan_face_direct',
    );
    _logObjectReturnScanCandidateAlignedV1(
      round: round,
      hasHuman: hasHumanAtScan,
      hasFace: true,
      status: finalResult.finalAlignmentStatus,
    );
    return finalResult;
  }

  Future<SnapshotAlignResult> _runObjectReturnOwnerReacquireAttemptsV1() async {
    _monitorStatus = 'OBJECT_RETURN: 视觉重确认主人';
    var lastResult = SnapshotAlignResult.noTarget();
    var failureReason = 'max_attempts';

    for (var attempt = 1;
        attempt <= _objectReturnOwnerReacquireMaxAttemptsV1;
        attempt++) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] owner_reacquire start '
        'attempt=$attempt/$_objectReturnOwnerReacquireMaxAttemptsV1',
      );

      final human = await _detectHumanObservationSafe(
        phase: 'object_return_reacquire_$attempt',
      );
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] human hasHuman=${human.hasHuman} '
        'conf=${_f(human.confidence)} cx=${_f(human.centerX)}',
      );

      if (!_isEnvironmentMonitoring) {
        return SnapshotAlignResult.noTarget(humanObservation: human);
      }
      final safetyReason = _objectReturnSafetyStopReasonV1();
      if (safetyReason != null) {
        _objectReturnPendingSafeStopReasonV1 = safetyReason;
        return SnapshotAlignResult.noTarget(
          humanObservation: human.hasHuman ? human : null,
        );
      }
      if (!_isReliableHumanObservation(human)) {
        lastResult = SnapshotAlignResult.noTarget(
          humanObservation: human.hasHuman ? human : null,
        );
        failureReason = 'no_reliable_human';
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN] final_status='
          '${lastResult.finalAlignmentStatus}',
        );
        _logObjectReturnContinueStatusV1(lastResult.finalAlignmentStatus);
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN] owner_reacquire failed '
          'reason=$failureReason',
        );
        break;
      }

      final finalResult = await _alignObjectReturnCandidateV1(
        human,
        source: 'owner_reacquire',
      );
      lastResult = finalResult;

      final status = finalResult.finalAlignmentStatus;
      _envLogV1('[ENV_V1_OBJECT_RETURN] final_status=$status');
      _envLogV1('[ENV_V1_OBJECT_RETURN] attempt=$attempt status=$status');

      if (status == SnapshotAlignStatus.verifiedFaceCentered) {
        return finalResult;
      }

      _logObjectReturnContinueStatusV1(status);

      failureReason = status;
      if (attempt < _objectReturnOwnerReacquireMaxAttemptsV1) {
        continue;
      }
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] owner_reacquire failed '
        'reason=$failureReason',
      );
      break;
    }

    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] owner_reacquire failed '
      'reason=$failureReason last_status=${lastResult.finalAlignmentStatus}',
    );
    return lastResult;
  }

  Future<SnapshotAlignResult> _alignObjectReturnCandidateV1(
    HumanObservation human, {
    required String source,
    bool objectReturnTrack = false,
  }) async {
    _envLogV1('[ENV_V1_OBJECT_RETURN] track start source=$source');
    final tracked = await _runTrackOwnerV1(
      human,
      maxLoops: 2,
      objectReturnTrack: objectReturnTrack,
    );
    if (!_isEnvironmentMonitoring) {
      return SnapshotAlignResult.noTarget(humanObservation: tracked);
    }

    _envLogV1('[ENV_V1_OBJECT_RETURN] confirm start source=$source');
    final confirmed = await _runConfirmOwnerBySnapshotV1(tracked);
    if (!_isEnvironmentMonitoring) {
      return confirmed;
    }

    _envLogV1('[ENV_V1_OBJECT_RETURN] final_center start source=$source');
    var finalResult = await _runFinalFaceCenteringV1(confirmed);
    if (!_isEnvironmentMonitoring) {
      return finalResult;
    }
    finalResult = await _runStableVerifyIfCenteredV1(finalResult);
    return finalResult;
  }

  Future<SnapshotAlignResult> _alignObjectReturnFaceDirectV1(
    SnapshotAlignResult faceCandidate, {
    required String source,
  }) async {
    _envLogV1('[ENV_V1_OBJECT_RETURN] final_center start source=$source');
    var finalResult = await _runFinalFaceCenteringV1(faceCandidate);
    if (!_isEnvironmentMonitoring) {
      return finalResult;
    }
    finalResult = await _runStableVerifyIfCenteredV1(finalResult);
    if (!_isObjectReturnSuccessfulStatusV1(finalResult.finalAlignmentStatus) &&
        finalResult.targetType == SnapshotTargetType.none) {
      finalResult = finalResult.copyWith(
        humanObservation:
            finalResult.humanObservation ?? faceCandidate.humanObservation,
        faceObservation: faceCandidate.faceObservation,
      );
    }
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] final_status='
      '${finalResult.finalAlignmentStatus}',
    );
    return finalResult;
  }

  void _logObjectReturnScanCandidateAlignedV1({
    required int round,
    required bool hasHuman,
    required bool hasFace,
    required String status,
  }) {
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN_SCAN] candidate_aligned '
      'round=$round hasHuman=$hasHuman hasFace=$hasFace status=$status',
    );
    _envLogV1('[ENV_V1_OBJECT_RETURN] final_status=$status');
  }

  bool _isObjectReturnCandidateFailureStatusV1(String status) {
    return status == SnapshotAlignStatus.verifiedFaceAcceptable ||
        status == SnapshotAlignStatus.verifiedPersonAcceptable ||
        status == SnapshotAlignStatus.noTarget ||
        status == SnapshotAlignStatus.stillOffcenter ||
        status == SnapshotAlignStatus.targetLostAfterNudge;
  }

  bool _shouldRunObjectReturnCandidateLocalSearchV1(
    SnapshotAlignResult result,
  ) {
    if (!_isObjectReturnCandidateFailureStatusV1(
      result.finalAlignmentStatus,
    )) {
      return false;
    }
    if (result.targetType != SnapshotTargetType.none) {
      return true;
    }
    if (result.faceObservation?.hasFace == true) {
      return true;
    }
    final human = result.humanObservation;
    return human != null && _isReliableHumanObservation(human);
  }

  Future<SnapshotAlignResult> _runObjectReturnCandidateLocalSearchV1({
    required int round,
    required SnapshotAlignResult lastResult,
  }) async {
    var result = lastResult;
    final steps = <_ObjectReturnLocalScanStepV1>[
      const _ObjectReturnLocalScanStepV1(
        command: '左转',
        turn: 'left',
        angleDeg: _objectReturnCandidateLocalLeftDegV1,
      ),
      const _ObjectReturnLocalScanStepV1(
        command: '右转',
        turn: 'right',
        angleDeg: _objectReturnCandidateLocalRightDegV1,
      ),
      const _ObjectReturnLocalScanStepV1(
        command: '左转',
        turn: 'left',
        angleDeg: _objectReturnCandidateLocalLeftDegV1,
        returnCenter: true,
      ),
    ];

    for (var i = 0; i < steps.length; i++) {
      if (!_isEnvironmentMonitoring) return result;
      final safetyReason = _objectReturnSafetyStopReasonV1();
      if (safetyReason != null) {
        _objectReturnPendingSafeStopReasonV1 = safetyReason;
        return result;
      }

      final step = steps[i];
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_LOCAL] round=$round step=${i + 1}/${steps.length} '
        'turn=${step.turn} angle=${step.angleDeg}'
        '${step.returnCenter ? ' return_center' : ''}',
      );
      final moved = await _safeSendCommandV1WithPhase(
        step.command,
        step.angleDeg,
        phase: 'object_return_candidate_local_search',
      );
      if (!moved) {
        if (_consumeTurnSensorIncidentV1(
          'object_return_candidate_local_search',
          logPrefix: '[ENV_V1_OBJECT_RETURN]',
        )) {
          await _safeSendCommandV1('停止', 0);
          continue;
        }
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_LOCAL] failed reason=turn_failed',
        );
        _markObjectReturnMovementSafetyStopReasonV1();
        return result;
      }
      if (_consumeFrontCliffTurnRecoveryV1(
        'object_return_candidate_local_search',
      )) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_LOCAL] resume_after_cliff round=$round',
        );
      }

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_LOCAL] failed reason=stop_failed',
        );
        _markObjectReturnMovementSafetyStopReasonV1();
        return result;
      }
      await Future<void>.delayed(
        const Duration(milliseconds: _objectReturnFullCircleSettleMsV1),
      );

      result = await _detectAndAlignObjectReturnLocalCandidateV1(
        round: round,
        stepIndex: i + 1,
      );
      if (_isObjectReturnSuccessfulStatusV1(result.finalAlignmentStatus)) {
        return result;
      }
    }

    _envLogV1(
      '[ENV_V1_OBJECT_RETURN_LOCAL] failed reason=no_centered_owner round=$round',
    );
    return result;
  }

  Future<SnapshotAlignResult> _detectAndAlignObjectReturnLocalCandidateV1({
    required int round,
    required int stepIndex,
  }) async {
    final realtime = _getFreshRealtimeHumanV1();
    if (realtime != null) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_LOCAL] round=$round step=$stepIndex '
        'detect source=realtime hasHuman=${realtime.hasHuman} '
        'cx=${_f(realtime.centerX)} conf=${_f(realtime.confidence)}',
      );
      return _alignObjectReturnCandidateV1(
        realtime,
        source: 'object_return_candidate_local_realtime',
        objectReturnTrack: true,
      );
    }

    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN_LOCAL] round=$round step=$stepIndex '
          'detect source=snapshot hasHuman=false hasFace=false '
          'reason=camera_unavailable',
        );
        return SnapshotAlignResult.noTarget();
      }
      final imagePath = await camera.captureImage();
      final face = await camera.detectFaceObservationFromImagePath(imagePath);
      final human = await camera.detectHumanObservationFromImagePath(imagePath);
      final hasReliableHuman = _isReliableHumanObservation(human);
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_LOCAL] round=$round step=$stepIndex '
        'detect source=snapshot hasHuman=${human.hasHuman} '
        'hasFace=${face.hasFace} '
        'cx=${_f(face.hasFace ? face.centerX : human.centerX)} '
        'conf=${_f(face.hasFace ? face.confidence : human.confidence)}',
      );
      if (face.hasFace) {
        return _alignObjectReturnFaceDirectV1(
          SnapshotAlignResult(
            canProceed: true,
            finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
            targetType: SnapshotTargetType.face,
            centerX: face.centerX,
            centerY: face.centerY,
            confidence: face.confidence,
            areaRatio: face.areaRatio,
            humanObservation: human.hasHuman ? human : null,
            faceObservation: face,
            imagePath: imagePath,
          ),
          source: 'object_return_local_face_direct',
        );
      }
      if (hasReliableHuman) {
        return _alignObjectReturnCandidateV1(
          human,
          source: 'object_return_candidate_local_human',
          objectReturnTrack: true,
        );
      }
      return SnapshotAlignResult.noTarget(
        humanObservation: human.hasHuman ? human : null,
        imagePath: imagePath,
      );
    } catch (e) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN_LOCAL] round=$round step=$stepIndex '
        'detect_failed error=$e',
      );
      return SnapshotAlignResult.noTarget();
    }
  }

  Future<SnapshotAlignResult> _runObjectReturnResearchOwnerV1({
    required String reason,
    required int cycle,
  }) async {
    _envLogV1('[ENV_V1_OBJECT_RESEARCH] start reason=$reason cycle=$cycle');

    final localResult = await _runObjectReturnResearchLocalV1();
    if (!_isEnvironmentMonitoring ||
        _objectReturnSafetyStopReasonV1() != null ||
        _isObjectReturnSuccessfulStatusV1(localResult.finalAlignmentStatus)) {
      return localResult;
    }

    final wideResult = await _runObjectReturnResearchWideV1();
    if (!_isEnvironmentMonitoring ||
        _objectReturnSafetyStopReasonV1() != null ||
        _isObjectReturnSuccessfulStatusV1(wideResult.finalAlignmentStatus)) {
      return wideResult;
    }

    await _safeSendCommandV1('停止', 0);
    _envLogV1('[ENV_V1_OBJECT_RESEARCH] failed no_target');
    return wideResult;
  }

  Future<SnapshotAlignResult> _runObjectReturnResearchLocalV1() async {
    _envLogV1('[ENV_V1_OBJECT_RETURN] local_search start');
    _envLogV1('[ENV_V1_OBJECT_RESEARCH] level=local step=center_check');
    var result = await _detectAndAlignObjectReturnResearchCandidateV1(
      level: 'local',
    );
    if (_isObjectReturnSuccessfulStatusV1(result.finalAlignmentStatus)) {
      return result;
    }

    var turned = await _turnObjectReturnResearchLocalV1(
      command: '左转',
      turn: 'left',
      angleDeg: _objectReturnResearchLocalStepDegV1,
    );
    if (!turned) return result;
    result = await _detectAndAlignObjectReturnResearchCandidateV1(
      level: 'local',
    );
    if (_isObjectReturnSuccessfulStatusV1(result.finalAlignmentStatus)) {
      return result;
    }

    turned = await _turnObjectReturnResearchLocalV1(
      command: '右转',
      turn: 'right',
      angleDeg: _objectReturnResearchLocalStepDegV1 * 2,
    );
    if (!turned) return result;
    result = await _detectAndAlignObjectReturnResearchCandidateV1(
      level: 'local',
    );
    if (_isObjectReturnSuccessfulStatusV1(result.finalAlignmentStatus)) {
      return result;
    }

    turned = await _turnObjectReturnResearchLocalV1(
      command: '左转',
      turn: 'left',
      angleDeg: _objectReturnResearchLocalStepDegV1,
      returnCenter: true,
    );
    if (!turned) return result;
    return _detectAndAlignObjectReturnResearchCandidateV1(level: 'local');
  }

  Future<bool> _turnObjectReturnResearchLocalV1({
    required String command,
    required String turn,
    required int angleDeg,
    bool returnCenter = false,
  }) async {
    _envLogV1(
      '[ENV_V1_OBJECT_RESEARCH] level=local turn=$turn '
      'angle=$angleDeg${returnCenter ? ' return_center' : ''}',
    );
    final moved = await _safeSendCommandV1WithPhase(
      command,
      angleDeg,
      phase: 'object_return_research_local',
    );
    if (!moved) {
      if (_consumeTurnSensorIncidentV1(
        'object_return_research_local',
        logPrefix: '[ENV_V1_OBJECT_RETURN]',
      )) {
        await _safeSendCommandV1('停止', 0);
        return true;
      }
      _envLogV1('[ENV_V1_OBJECT_RESEARCH] failed reason=local_turn_failed');
      _markObjectReturnMovementSafetyStopReasonV1();
      return false;
    }
    if (_consumeFrontCliffTurnRecoveryV1('object_return_research_local')) {
      _envLogV1(
        '[ENV_V1_OBJECT_RESEARCH] resume_after_cliff '
        'level=local turn=$turn',
      );
    }
    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      _envLogV1('[ENV_V1_OBJECT_RESEARCH] failed reason=local_stop_failed');
      _markObjectReturnMovementSafetyStopReasonV1();
      return false;
    }
    await Future<void>.delayed(_settleDelay);
    return _isEnvironmentMonitoring;
  }

  Future<SnapshotAlignResult> _runObjectReturnResearchWideV1() async {
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] wide_search start '
      'maxDeg=$_objectReturnResearchWideMaxAccumulatedDegV1',
    );
    var accumulatedDeg = 0;
    var lastResult = SnapshotAlignResult.noTarget();

    for (var round = 1;
        round <= _objectReturnResearchWideMaxRoundsV1;
        round++) {
      if (!_isEnvironmentMonitoring) return lastResult;
      if (accumulatedDeg >= _objectReturnResearchWideMaxAccumulatedDegV1) {
        break;
      }

      const turnDeg = _objectReturnResearchWideStepDegV1;
      final nextAccumulated = accumulatedDeg + turnDeg;
      _envLogV1(
        '[ENV_V1_OBJECT_RESEARCH] level=wide '
        'round=$round/$_objectReturnResearchWideMaxRoundsV1 '
        'turn=right angle=$turnDeg accumulated=$nextAccumulated',
      );
      final moved = await _safeSendCommandV1WithPhase(
        '右转',
        turnDeg,
        phase: 'object_return_research_wide',
      );
      if (!moved) {
        if (_consumeTurnSensorIncidentV1(
          'object_return_research_wide',
          logPrefix: '[ENV_V1_OBJECT_RETURN]',
        )) {
          await _safeSendCommandV1('停止', 0);
          continue;
        }
        _envLogV1('[ENV_V1_OBJECT_RESEARCH] failed reason=wide_turn_failed');
        _markObjectReturnMovementSafetyStopReasonV1();
        return lastResult;
      }
      if (_consumeFrontCliffTurnRecoveryV1('object_return_research_wide')) {
        _envLogV1(
          '[ENV_V1_OBJECT_RESEARCH] resume_after_cliff round=$round',
        );
      }
      accumulatedDeg = nextAccumulated;
      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _envLogV1('[ENV_V1_OBJECT_RESEARCH] failed reason=wide_stop_failed');
        _markObjectReturnMovementSafetyStopReasonV1();
        return lastResult;
      }
      await Future<void>.delayed(_settleDelay);

      lastResult = await _detectAndAlignObjectReturnResearchCandidateV1(
        level: 'wide',
      );
      if (_isObjectReturnSuccessfulStatusV1(lastResult.finalAlignmentStatus)) {
        return lastResult;
      }
    }

    await _safeSendCommandV1('停止', 0);
    return lastResult;
  }

  Future<SnapshotAlignResult> _detectAndAlignObjectReturnResearchCandidateV1({
    required String level,
  }) async {
    final human = await _detectHumanObservationSafe(
      phase: 'object_return_research_$level',
    );
    _envLogV1(
      '[ENV_V1_OBJECT_RESEARCH] candidate hasHuman=${human.hasHuman} '
      'conf=${_f(human.confidence)} cx=${_f(human.centerX)}',
    );
    if (!_isEnvironmentMonitoring) {
      return SnapshotAlignResult.noTarget(humanObservation: human);
    }
    if (!_isReliableHumanObservation(human)) {
      return SnapshotAlignResult.noTarget(
        humanObservation: human.hasHuman ? human : null,
      );
    }

    _envLogV1('[ENV_V1_OBJECT_RESEARCH] found level=$level');
    final finalResult = await _alignObjectReturnCandidateV1(
      human,
      source: 'object_return_research_$level',
    );
    _envLogV1(
      '[ENV_V1_OBJECT_RESEARCH] final_status='
      '${finalResult.finalAlignmentStatus}',
    );
    return finalResult;
  }

  bool _isObjectReturnSuccessfulStatusV1(String status) {
    return status == SnapshotAlignStatus.verifiedFaceCentered;
  }

  void _logObjectReturnContinueStatusV1(String status) {
    _envLogV1('[ENV_V1_OBJECT_RETURN] continue_until_centered status=$status');
    if (status == SnapshotAlignStatus.verifiedFaceAcceptable) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] face_acceptable_not_done continue_scan',
      );
      return;
    }
    if (status == SnapshotAlignStatus.verifiedPersonAcceptable) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] person_only_not_done continue_find_face',
      );
      return;
    }
    if (status == SnapshotAlignStatus.noTarget ||
        status == SnapshotAlignStatus.stillOffcenter ||
        status == SnapshotAlignStatus.targetLostAfterNudge) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] no_target_not_done continue_scan',
      );
    }
  }

  String? _objectReturnSafetyStopReasonV1() {
    _refreshExternalActivityStateV1();
    if (_objectReturnPendingSafeStopReasonV1 != null) {
      return _objectReturnPendingSafeStopReasonV1;
    }
    if (!_isEnvironmentMonitoring) {
      return 'env_monitoring_stopped';
    }
    if (_isAnswering) {
      return 'chat_started';
    }
    if (!_isBluetoothConnectedV1()) {
      return 'bluetooth_disconnected';
    }
    if (_degradedToVoiceExpressionOnly) {
      return 'chassis_unavailable';
    }
    return null;
  }

  void _markObjectReturnSafetyStopReasonV1(String reason) {
    _objectReturnPendingSafeStopReasonV1 ??= reason;
  }

  void _markObjectReturnMovementSafetyStopReasonV1() {
    _markObjectReturnSafetyStopReasonV1(
      _isBluetoothConnectedV1()
          ? 'chassis_unavailable'
          : 'bluetooth_disconnected',
    );
  }

  Future<void> _finishObjectReturnSuccessV1(
    SnapshotAlignResult result,
  ) async {
    final status = result.finalAlignmentStatus;
    if (status != SnapshotAlignStatus.verifiedFaceCentered) {
      _logObjectReturnContinueStatusV1(status);
      return;
    }
    _objectReturnSafeStopWaitingV1 = false;
    _objectReturnPendingSafeStopReasonV1 = null;
    _envLogV1('[ENV_V1_OBJECT_RETURN] final_status=$status');
    await _safeSendCommandV1('停止', 0);
    await _loadExpression('assets/emotion/face2/可爱/02/可爱 02.json');
    _envLogV1('[ENV_V1_OBJECT_RETURN] centered success');
    _startIdleRecenterAfterObjectReturnV1(
      reason: 'object_return_centered_success',
    );
  }

  Future<SnapshotAlignResult> _enterObjectReturnSafeStopWaitForOwnerV1({
    required String reason,
    required SnapshotAlignResult lastResult,
  }) async {
    _objectReturnSafeStopWaitingV1 = true;
    _objectReturnPendingSafeStopReasonV1 = reason;
    _stopIdleRecenterAfterObjectReturnV1(reason: 'safe_stop_wait_for_owner');
    _monitorStatus = 'OBJECT_RETURN: safe_stop_wait_for_owner';
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] safe_stop_wait_for_owner reason=$reason',
    );
    if (_isBluetoothConnectedV1()) {
      await _safeSendCommandV1('停止', 0);
    }
    if (_isEnvironmentMonitoring && reason != 'chat_started') {
      final text = _safeStopSpeechForReasonV1(reason);
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] speak_safe_stop '
        'reason=$reason text=$text',
      );
      await speakWithInterruptProtection(text);
      await _loadExpression('assets/emotion/face2/眨眼.json');
    }
    return lastResult;
  }

  String _safeStopSpeechForReasonV1(String reason) {
    if (reason == 'bluetooth_disconnected') {
      return '我和小车断开连接了，我先停在这里。';
    }
    if (reason == 'front_cliff_recover_failed' ||
        reason == 'rear_cliff_recover_failed' ||
        reason == 'cliff_recover_failed' ||
        reason == 'repeated_front_cliff' ||
        reason == 'backoff_not_safe' ||
        reason == 'backward_interrupted_by_cliff' ||
        reason == 'cliff_repeated_during_turn' ||
        reason == 'repeated_cliff' ||
        reason == 'wheel_may_be_off_table' ||
        reason == 'edge_risk_high' ||
        reason == 'safety_recover_interrupted' ||
        reason == 'unknown_obstacle_after_cliff_recover') {
      return '主人，边上好像不太安全，我先停住等你。';
    }
    return '主人，我有点找不准你了，我先停住等你。';
  }

  String? _greetingLineForStatus(String status) {
    if (status == SnapshotAlignStatus.verifiedFaceCentered) {
      return '找到你啦，主人！';
    }
    if (status == SnapshotAlignStatus.verifiedFaceAcceptable) {
      return '我看到你啦，主人。';
    }
    if (status == SnapshotAlignStatus.verifiedPersonAcceptable) {
      return '我好像看到你啦。';
    }
    return null;
  }

  void _startIdleRecenterAfterObjectReturnV1({required String reason}) {
    if (!_enableIdleRecenterAfterObjectReturnV1) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] start skipped reason=feature_disabled');
      return;
    }
    if (!_isEnvironmentMonitoring) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] start skipped reason=env_stopped');
      return;
    }
    if (!_isBluetoothConnectedV1()) {
      _envLogV1(
        '[ENV_V1_IDLE_RECENTER] start skipped reason=bluetooth_disconnected',
      );
      return;
    }
    if (_objectReturnSafeStopWaitingV1) {
      _envLogV1(
        '[ENV_V1_IDLE_RECENTER] start skipped reason=safe_stop_wait_for_owner',
      );
      return;
    }

    _idleRecenterTimerV1?.cancel();
    _idleRecenterActiveV1 = true;
    _idleRecenterNudgeInFlightV1 = false;
    _idleRecenterNudgeCountV1 = 0;
    _idleRecenterOffsetHitCountV1 = 0;
    _idleRecenterLastDirectionV1 = null;
    _envLogV1('[ENV_V1_IDLE_RECENTER] start reason=$reason');

    if (!_envRealtimeHumanRunning) {
      unawaited(_restartRealtimeHumanDetectionForObjectReturnV1());
    }

    _idleRecenterTimerV1 = Timer.periodic(
      const Duration(milliseconds: _idleRecenterIntervalMsV1),
      (_) {
        if (_idleRecenterNudgeInFlightV1) return;
        unawaited(_handleIdleRecenterTickV1());
      },
    );
  }

  void _stopIdleRecenterAfterObjectReturnV1({required String reason}) {
    final wasActive = _idleRecenterActiveV1 || _idleRecenterTimerV1 != null;
    _idleRecenterTimerV1?.cancel();
    _idleRecenterTimerV1 = null;
    _idleRecenterActiveV1 = false;
    _idleRecenterNudgeInFlightV1 = false;
    _idleRecenterNudgeCountV1 = 0;
    _idleRecenterOffsetHitCountV1 = 0;
    _idleRecenterLastDirectionV1 = null;
    if (wasActive) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] stop reason=$reason');
    }
  }

  void _stopIdleRecenterIfInterruptedV1() {
    if (!_idleRecenterActiveV1) return;
    final reason = _idleRecenterStopReasonV1();
    if (reason != null) {
      _stopIdleRecenterAfterObjectReturnV1(reason: reason);
    }
  }

  String? _idleRecenterStopReasonV1() {
    if (!_isEnvironmentMonitoring) {
      return 'env_stopped';
    }
    if (!_isBluetoothConnectedV1()) {
      return 'bluetooth_disconnected';
    }
    if (_isAnswering) {
      return 'chat_started';
    }
    if (_isTtsPlaying) {
      return 'tts_playing';
    }
    if (_objectLookAroundRunningV1) {
      return 'object_look_started';
    }
    if (_objectReturnSafeStopWaitingV1) {
      return 'safe_stop_wait_for_owner';
    }
    if (_degradedToVoiceExpressionOnly) {
      return 'chassis_unavailable';
    }
    if (_cameraService == null) {
      return 'camera_released';
    }
    if (_envV1MotionCommandInFlight && !_idleRecenterNudgeInFlightV1) {
      return 'motion_in_flight';
    }
    return null;
  }

  Future<void> _handleIdleRecenterTickV1() async {
    if (!_idleRecenterActiveV1) return;
    _refreshExternalActivityStateV1();

    final stopReason = _idleRecenterStopReasonV1();
    if (stopReason != null) {
      _stopIdleRecenterAfterObjectReturnV1(reason: stopReason);
      return;
    }
    if (!_quietCompanionActiveV1) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] skip reason=not_quiet_companion');
      return;
    }

    final observation = _getFreshRealtimeHumanV1();
    if (observation == null) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] skip reason=no_fresh_realtime');
      return;
    }

    final dx = observation.centerX - 0.5;
    final absDx = dx.abs();
    _envLogV1(
      '[ENV_V1_IDLE_RECENTER] tick source=realtime_person fresh=true '
      'cx=${_f(observation.centerX)} dx=${_f(dx)} absDx=${_f(absDx)}',
    );

    if (absDx <= _idleRecenterDeadZoneV1) {
      _idleRecenterOffsetHitCountV1 = 0;
      _idleRecenterLastDirectionV1 = null;
      return;
    }

    final direction = _turnDirectionForOwnerDx(dx);
    if (_idleRecenterLastDirectionV1 == direction) {
      _idleRecenterOffsetHitCountV1++;
    } else {
      _idleRecenterLastDirectionV1 = direction;
      _idleRecenterOffsetHitCountV1 = 1;
    }
    _envLogV1(
      '[ENV_V1_IDLE_RECENTER] offset_hit '
      'count=$_idleRecenterOffsetHitCountV1 direction=$direction',
    );

    if (_idleRecenterOffsetHitCountV1 < _idleRecenterStableOffsetHitsV1) {
      return;
    }
    if (_idleRecenterNudgeCountV1 >= _idleRecenterMaxNudgesPerSessionV1) {
      _envLogV1('[ENV_V1_IDLE_RECENTER] pause reason=max_nudges_reached');
      _stopIdleRecenterAfterObjectReturnV1(reason: 'max_nudges_reached');
      return;
    }

    final isLargeOffset = absDx > _idleRecenterSmallThresholdV1;
    final angle = isLargeOffset
        ? _idleRecenterLargeAngleDegV1
        : _idleRecenterSmallAngleDegV1;
    final nudgeReason = isLargeOffset ? 'large_stable_offset' : 'stable_offset';
    await _performIdleRecenterNudgeV1(
      direction: direction,
      angle: angle,
      reason: nudgeReason,
    );
  }

  Future<void> _performIdleRecenterNudgeV1({
    required String direction,
    required int angle,
    required String reason,
  }) async {
    if (!_idleRecenterActiveV1 || _idleRecenterNudgeInFlightV1) return;
    _idleRecenterNudgeInFlightV1 = true;
    try {
      _envLogV1(
        '[ENV_V1_IDLE_RECENTER] nudge '
        'direction=$direction angle=$angle reason=$reason',
      );
      final moved = await _safeSendCommandV1WithPhase(
        direction,
        angle,
        phase: 'idle_recenter',
      );
      if (!moved) {
        _stopIdleRecenterAfterObjectReturnV1(reason: 'nudge_failed');
        return;
      }

      _envLogV1('[ENV_V1_CHASSIS] send_stop source=ENV_V1_IDLE_RECENTER');
      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        _stopIdleRecenterAfterObjectReturnV1(reason: 'stop_failed');
        return;
      }
      await Future<void>.delayed(
        const Duration(milliseconds: _idleRecenterSettleMsV1),
      );
      _envLogV1('[ENV_V1_IDLE_RECENTER] settle ms=$_idleRecenterSettleMsV1');

      _idleRecenterNudgeCountV1++;
      _idleRecenterOffsetHitCountV1 = 0;
      _idleRecenterLastDirectionV1 = null;
      if (_idleRecenterNudgeCountV1 >= _idleRecenterMaxNudgesPerSessionV1) {
        _envLogV1('[ENV_V1_IDLE_RECENTER] pause reason=max_nudges_reached');
        _stopIdleRecenterAfterObjectReturnV1(reason: 'max_nudges_reached');
      }
    } finally {
      _idleRecenterNudgeInFlightV1 = false;
    }
  }

  Future<void> _enterQuietCompanionModeV1() async {
    if (!_isEnvironmentMonitoring) return;
    if (_objectReturnSafeStopWaitingV1) {
      _monitorStatus = 'OBJECT_RETURN: safe_stop_wait_for_owner';
      _quietCompanionActiveV1 = false;
      _quietCompanionTimer?.cancel();
      _quietCompanionTimer = null;
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] safe_stop_wait_for_owner keep_waiting=true',
      );
      return;
    }
    _monitorStatus = 'QUIET_COMPANION: 安静陪伴中';
    _quietCompanionActiveV1 = true;
    _envLogV1(
        '[ENV_V1_QUIET] enter mode=voice_expression_only_keep_expression');

    _quietCompanionTimer?.cancel();
    _quietCompanionTimer = Timer.periodic(_quietCompanionInterval, (_) {
      if (!_isEnvironmentMonitoring ||
          _isAnswering ||
          _isTtsPlaying ||
          _objectLookAroundRunningV1) {
        return;
      }
      unawaited(_performPetMicroActionV1());
    });
  }

  Future<void> _performPetMicroActionV1() async {
    _envLogV1('[ENV_V1_QUIET] micro_action action=keep_current_expression');
  }

  Future<void> _ensureCameraService() async {
    _cameraService ??= CameraService();
    await _cameraService!.initialize();
  }

  Future<void> _startRealtimeHumanDetectionForEnvV1() async {
    if (_envRealtimeHumanRunning) {
      _envLogV1('[ENV_V1_RT_HUMAN] start skipped reason=already_running');
      return;
    }

    _envLogV1('[ENV_V1_RT_HUMAN] start requested');
    final camera = _cameraService;
    if (camera == null) {
      _envLogV1('[ENV_V1_RT_HUMAN] start failed error=camera_unavailable');
      return;
    }

    try {
      final stream = await camera.startRealTimeDetection();
      await _envRealtimeHumanSubscription?.cancel();
      _envRealtimeHumanSubscription = stream.listen(
        (recognitions) {
          final observation =
              _extractBestRealtimeHumanObservationV1(recognitions);
          _envLogV1(
            '[ENV_V1_RT_HUMAN] update hasHuman=${observation.hasHuman} '
            'conf=${_f(observation.confidence)} '
            'area=${_f(observation.areaRatio)} '
            'cx=${_f(observation.centerX)}',
          );
          if (_isReliableHumanObservation(observation)) {
            _cacheRealtimeHumanV1(observation);
          }
        },
        onError: (Object error) {
          _envLogV1('[ENV_V1_RT_HUMAN] update failed error=$error');
        },
      );
      _envRealtimeHumanRunning = true;
      _envLogV1('[ENV_V1_RT_HUMAN] start success');
    } catch (e) {
      _envRealtimeHumanRunning = false;
      _envLogV1('[ENV_V1_RT_HUMAN] start failed error=$e');
    }
  }

  Future<void> _restartRealtimeHumanDetectionForObjectReturnV1() async {
    _envLogV1('[ENV_V1_OBJECT_RETURN] realtime_human_restart requested');
    try {
      if (_envRealtimeHumanRunning || _envRealtimeHumanSubscription != null) {
        await _stopRealtimeHumanDetectionForEnvV1();
      }
      await _ensureCameraService();
      await _startRealtimeHumanDetectionForEnvV1();
      if (_envRealtimeHumanRunning) {
        _envLogV1('[ENV_V1_OBJECT_RETURN] realtime_human_restart success');
      } else {
        _envLogV1(
          '[ENV_V1_OBJECT_RETURN] realtime_human_restart failed '
          'reason=not_running_after_start',
        );
      }
    } catch (e) {
      _envLogV1(
          '[ENV_V1_OBJECT_RETURN] realtime_human_restart failed error=$e');
    }
  }

  Future<void> _stopRealtimeHumanDetectionForEnvV1() async {
    if (!_envRealtimeHumanRunning &&
        _envRealtimeHumanSubscription == null &&
        _recentRealtimeHuman == null) {
      return;
    }

    _envLogV1('[ENV_V1_RT_HUMAN] stop requested');
    try {
      await _envRealtimeHumanSubscription?.cancel();
      _envRealtimeHumanSubscription = null;
      _cameraService?.stopRealTimeDetection();
      _envLogV1('[ENV_V1_RT_HUMAN] stop success');
    } catch (e) {
      _envLogV1('[ENV_V1_RT_HUMAN] stop failed error=$e');
    } finally {
      _envRealtimeHumanRunning = false;
      _recentRealtimeHuman = null;
      _recentRealtimeHumanAt = null;
    }
  }

  Future<void> _startRealtimeObjectDetectionForEnvV1() async {
    if (_envRealtimeObjectRunning) {
      _envLogV1('[ENV_V1_RT_OBJECT] start skipped reason=already_running');
      return;
    }

    _envLogV1('[ENV_V1_RT_OBJECT] start requested');
    final camera = _cameraService;
    if (camera == null) {
      _envLogV1('[ENV_V1_RT_OBJECT] start failed error=camera_unavailable');
      return;
    }

    try {
      final stream = await camera.startRealTimeDetection();
      await _envRealtimeObjectSubscription?.cancel();
      _envRealtimeObjectSubscription = stream.listen(
        (recognitions) {
          final object = _extractBestRealtimeObjectCandidateV1(recognitions);
          if (object == null) {
            _envLogV1('[ENV_V1_RT_OBJECT] update hasObject=false');
            return;
          }
          final policy = _objectPolicyForV1(object);
          if (_isObjectEligibleForObjectLookV1(object)) {
            _cacheRealtimeObjectV1(object);
            _logGenericVisualObjectCandidateV1(
              '[ENV_V1_OBJECT] generic_visual_candidate',
              object,
            );
          } else {
            _recentIgnoredRealtimeObject = object;
            _logObjectLabelPolicyV1(object, policy);
            _logIgnoredObjectV1(object, policy);
          }
          _envLogV1(
            '[ENV_V1_RT_OBJECT] update hasObject=true '
            'label=${object.label} conf=${_f(object.confidence)} '
            'area=${_f(object.areaRatio)} cx=${_f(object.centerX)} '
            'policy=${_objectPolicyNameV1(policy)}',
          );
        },
        onError: (Object error) {
          _envLogV1('[ENV_V1_RT_OBJECT] update failed error=$error');
        },
      );
      _envRealtimeObjectRunning = true;
      _envLogV1('[ENV_V1_RT_OBJECT] start success');
    } catch (e) {
      _envRealtimeObjectRunning = false;
      _envLogV1('[ENV_V1_RT_OBJECT] start failed error=$e');
    }
  }

  Future<void> _stopRealtimeObjectDetectionForEnvV1({
    String reason = 'unknown',
  }) async {
    _envLogV1('[ENV_V1_RT_OBJECT] stop requested reason=$reason');
    if (!_envRealtimeObjectRunning &&
        _envRealtimeObjectSubscription == null &&
        _recentRealtimeObject == null &&
        _recentRealtimeObjectSamplesV1.isEmpty) {
      _envLogV1('[ENV_V1_RT_OBJECT] stop success');
      return;
    }

    try {
      await _envRealtimeObjectSubscription?.cancel();
      _envRealtimeObjectSubscription = null;
      if (!_envRealtimeHumanRunning) {
        _cameraService?.stopRealTimeDetection();
      }
      _envLogV1('[ENV_V1_RT_OBJECT] stop success');
    } catch (e) {
      _envLogV1('[ENV_V1_RT_OBJECT] stop failed error=$e');
    } finally {
      _envRealtimeObjectRunning = false;
      _recentRealtimeObject = null;
      _recentIgnoredRealtimeObject = null;
      _recentRealtimeObjectSamplesV1.clear();
    }
  }

  Future<_RealtimeObjectProbeAnalysisV1>
      _collectRealtimeObjectCandidateForProbeV1({
    required String phase,
    required Duration timeout,
  }) async {
    if (!_envRealtimeObjectRunning) {
      _envLogV1(
        '[ENV_V1_RT_OBJECT] phase=$phase wait skipped reason=not_running',
      );
      return const _RealtimeObjectProbeAnalysisV1();
    }

    final deadline = DateTime.now().add(timeout);
    while (_isEnvironmentMonitoring && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    final analysis = _analyzeRealtimeObjectSamplesV1();
    final bestLow = analysis.bestLowCandidate;
    if (bestLow == null) {
      final ignored = _recentIgnoredRealtimeObject;
      if (ignored != null) {
        final policy = _objectPolicyForV1(ignored);
        return _RealtimeObjectProbeAnalysisV1(
          bestLowCandidate: ignored,
          bestHits: 0,
          bestPolicy: policy,
        );
      }
      _envLogV1('[ENV_V1_RT_OBJECT] phase=$phase wait timeout no_candidate');
      return analysis;
    }
    if (analysis.stableCandidate != null) {
      final stable = analysis.stableCandidate!;
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] realtime_candidate stable '
        'hits=${analysis.bestHits} label=${stable.label} '
        'bestScore=${_f(stable.confidence)} area=${_f(stable.areaRatio)} '
        'speechEligible=true',
      );
      return analysis;
    }
    final bestLowPolicy = _objectPolicyForV1(bestLow);
    if (_isRealtimeGenericCandidateV1(bestLow)) {
      _envLogV1(
        '[ENV_V1_OBJECT_PROBE] realtime_candidate '
        'label=${bestLow.label} score=${_f(bestLow.confidence)} '
        'area=${_f(bestLow.areaRatio)} '
        'policy=${_objectPolicyNameV1(bestLowPolicy)} '
        'speechEligible=true '
        'reason=non_person_visual_presence',
      );
      return analysis;
    }
    final reason = bestLow.confidence < _objectRealtimeSpeechScoreV1 ||
            bestLow.areaRatio < _objectRealtimeSpeechAreaV1
        ? 'low_score_or_area'
        : 'not_stable';
    _envLogV1(
      '[ENV_V1_OBJECT_PROBE] realtime_candidate low '
      'label=${bestLow.label} score=${_f(bestLow.confidence)} '
      'area=${_f(bestLow.areaRatio)} '
      'policy=${_objectPolicyNameV1(bestLowPolicy)} '
      'speechEligible=false reason=$reason',
    );
    return analysis;
  }

  _RealtimeObjectProbeAnalysisV1 _analyzeRealtimeObjectSamplesV1() {
    final now = DateTime.now();
    final cutoff = now.subtract(
        const Duration(milliseconds: _objectRealtimeStableWindowMsV1));
    final samples = _recentRealtimeObjectSamplesV1
        .where((sample) => !sample.observedAt.isBefore(cutoff))
        .toList(growable: false);
    if (samples.isEmpty) {
      return const _RealtimeObjectProbeAnalysisV1();
    }

    final bestLowSample = samples.reduce((a, b) {
      final aScore = a.object.confidence * (0.5 + a.object.areaRatio);
      final bScore = b.object.confidence * (0.5 + b.object.areaRatio);
      return aScore >= bScore ? a : b;
    });
    final byLabel = <String, List<_RealtimeObjectSampleV1>>{};
    for (final sample in samples) {
      final key = _normalizeObjectLabelV1(sample.object.label);
      byLabel.putIfAbsent(key, () => <_RealtimeObjectSampleV1>[]).add(sample);
    }

    List<_RealtimeObjectSampleV1> bestGroup = const <_RealtimeObjectSampleV1>[];
    for (final group in byLabel.values) {
      if (group.length > bestGroup.length) {
        bestGroup = group;
      } else if (group.length == bestGroup.length && group.isNotEmpty) {
        final currentBestScore = bestGroup.isEmpty
            ? 0.0
            : bestGroup
                .map((sample) => sample.object.confidence)
                .reduce((a, b) => a > b ? a : b);
        final groupBestScore = group
            .map((sample) => sample.object.confidence)
            .reduce((a, b) => a > b ? a : b);
        if (groupBestScore > currentBestScore) bestGroup = group;
      }
    }

    final stableCandidate = _stableRealtimeObjectFromGroupV1(bestGroup);
    return _RealtimeObjectProbeAnalysisV1(
      bestLowCandidate: bestLowSample.object,
      stableCandidate: stableCandidate,
      bestHits: bestGroup.length,
    );
  }

  DetectedDesktopObject? _stableRealtimeObjectFromGroupV1(
    List<_RealtimeObjectSampleV1> group,
  ) {
    if (group.length < _objectRealtimeStableMinHitsV1) return null;
    final bestSample = group.reduce((a, b) {
      final aScore = a.object.confidence * (0.5 + a.object.areaRatio);
      final bScore = b.object.confidence * (0.5 + b.object.areaRatio);
      return aScore >= bScore ? a : b;
    });
    final object = bestSample.object;
    if (object.confidence < _objectRealtimeSpeechScoreV1 ||
        object.areaRatio < _objectRealtimeSpeechAreaV1) {
      return null;
    }
    final avgCenterX =
        group.map((sample) => sample.object.centerX).reduce((a, b) => a + b) /
            group.length;
    final avgArea =
        group.map((sample) => sample.object.areaRatio).reduce((a, b) => a + b) /
            group.length;
    final centerStable = (object.centerX - avgCenterX).abs() <= 0.18;
    final areaStable =
        avgArea <= 0 || (object.areaRatio - avgArea).abs() <= avgArea * 0.9;
    if (!centerStable || !areaStable) return null;
    return object;
  }

  void _cacheRealtimeObjectV1(DetectedDesktopObject object) {
    if (!_isReliableRealtimeObjectCandidateV1(object)) return;
    final now = DateTime.now();
    _recentRealtimeObject = object;
    _recentRealtimeObjectSamplesV1.add(
      _RealtimeObjectSampleV1(object: object, observedAt: now),
    );
    final cutoff = now.subtract(
      const Duration(milliseconds: _objectRealtimeStableWindowMsV1),
    );
    _recentRealtimeObjectSamplesV1
        .removeWhere((sample) => sample.observedAt.isBefore(cutoff));
  }

  void _clearRealtimeObjectCandidateV1() {
    _recentRealtimeObject = null;
    _recentIgnoredRealtimeObject = null;
    _recentRealtimeObjectSamplesV1.clear();
  }

  HumanObservation? _getFreshRealtimeHumanV1() {
    final observation = _recentRealtimeHuman;
    final observedAt = _recentRealtimeHumanAt;
    if (observation == null || observedAt == null) {
      return null;
    }
    if (DateTime.now().difference(observedAt) > _realtimeHumanFreshnessV1) {
      return null;
    }
    if (!_isReliableHumanObservation(observation)) {
      return null;
    }
    return observation;
  }

  void _cacheRealtimeHumanV1(HumanObservation observation) {
    if (!_isReliableHumanObservation(observation)) {
      return;
    }
    _recentRealtimeHuman = observation;
    _recentRealtimeHumanAt = DateTime.now();
  }

  HumanObservation _extractBestRealtimeHumanObservationV1(
    List<dynamic> recognitions,
  ) {
    Map<dynamic, dynamic>? bestRecognition;
    var bestScore = 0.0;

    for (final recognition in recognitions) {
      if (recognition is! Map) continue;
      if (recognition['detectedClass'] != 'person') continue;

      final confidence =
          (recognition['confidenceInClass'] as num?)?.toDouble() ?? 0;
      final rect = recognition['rect'];
      if (rect is! Map) continue;

      final width = (rect['w'] as num?)?.toDouble() ?? 0;
      final height = (rect['h'] as num?)?.toDouble() ?? 0;
      final area = width * height;
      final score = confidence * area;
      if (score > bestScore) {
        bestScore = score;
        bestRecognition = recognition;
      }
    }

    if (bestRecognition == null) {
      return const HumanObservation(hasHuman: false);
    }

    final rect = bestRecognition['rect'] as Map<dynamic, dynamic>;
    final x = (rect['x'] as num?)?.toDouble() ?? 0;
    final y = (rect['y'] as num?)?.toDouble() ?? 0;
    final width = (rect['w'] as num?)?.toDouble() ?? 0;
    final height = (rect['h'] as num?)?.toDouble() ?? 0;
    final centerX = x + width / 2;
    final centerY = y + height / 2;

    return HumanObservation(
      hasHuman: true,
      confidence:
          (bestRecognition['confidenceInClass'] as num?)?.toDouble() ?? 0,
      centerX: centerX,
      centerY: centerY,
      areaRatio: width * height,
      isCentered: (centerX - 0.5).abs() <= _ownerTrackDeadZoneV1,
      widthRatio: width,
      heightRatio: height,
      observedAt: DateTime.now(),
    );
  }

  DetectedDesktopObject? _extractBestRealtimeObjectCandidateV1(
    List<dynamic> recognitions,
  ) {
    DetectedDesktopObject? bestObject;
    var bestScore = 0.0;

    for (final recognition in recognitions) {
      if (recognition is! Map) continue;

      final label = (recognition['detectedClass'] ?? '').toString().trim();
      if (label.isEmpty || _isPersonObjectLabelV1(label)) continue;

      final confidence =
          (recognition['confidenceInClass'] as num?)?.toDouble() ?? 0;
      if (confidence < _realtimeObjectCandidateConfidenceV1) continue;

      final rect = recognition['rect'];
      if (rect is! Map) continue;
      final x = (rect['x'] as num?)?.toDouble() ?? 0;
      final y = (rect['y'] as num?)?.toDouble() ?? 0;
      final width = (rect['w'] as num?)?.toDouble() ?? 0;
      final height = (rect['h'] as num?)?.toDouble() ?? 0;
      final area = width * height;
      final object = DetectedDesktopObject(
        label: label,
        confidence: confidence,
        centerX: x + width / 2,
        centerY: y + height / 2,
        width: width,
        height: height,
        areaRatio: area,
      );
      if (!_isReliableRealtimeObjectCandidateV1(object)) continue;

      final score = confidence * (0.5 + area);
      if (score > bestScore) {
        bestScore = score;
        bestObject = object;
      }
    }

    return bestObject;
  }

  bool _isReliableRealtimeObjectCandidateV1(DetectedDesktopObject object) {
    return !_isPersonObjectLabelV1(object.label) &&
        object.confidence >= _realtimeObjectCandidateConfidenceV1 &&
        object.areaRatio >= _realtimeObjectCandidateMinAreaRatioV1 &&
        object.areaRatio <= _realtimeObjectCandidateMaxAreaRatioV1 &&
        object.centerX >= 0.03 &&
        object.centerX <= 0.97 &&
        object.centerY >= 0.03 &&
        object.centerY <= 0.97;
  }

  Future<HumanObservation> _detectHumanObservationSafe({
    String phase = 'unknown',
    bool allowSnapshotFallback = true,
  }) async {
    final realtime = _getFreshRealtimeHumanV1();
    if (realtime != null) {
      _envLogV1(
        '[ENV_V1_HUMAN] phase=$phase source=realtime fresh=true '
        'hasHuman=${realtime.hasHuman} conf=${_f(realtime.confidence)} '
        'area=${_f(realtime.areaRatio)} cx=${_f(realtime.centerX)}',
      );
      return realtime;
    }

    if (!allowSnapshotFallback) {
      _envLogV1(
        '[ENV_V1_HUMAN] phase=$phase source=realtime fresh=false '
        'reason=no_fresh_realtime',
      );
      return const HumanObservation(hasHuman: false);
    }

    try {
      final camera = _cameraService;
      if (camera == null) {
        _envLogV1(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=camera_unavailable',
        );
        return const HumanObservation(hasHuman: false);
      }
      final observation = await camera.detectHumanObservation();
      if (_isReliableHumanObservation(observation)) {
        _cacheRealtimeHumanV1(observation);
        _envLogV1(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=no_fresh_realtime hasHuman=true '
          'conf=${_f(observation.confidence)} '
          'area=${_f(observation.areaRatio)} '
          'cx=${_f(observation.centerX)}',
        );
      } else {
        _envLogV1(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=no_fresh_realtime hasHuman=${observation.hasHuman} '
          'conf=${_f(observation.confidence)} '
          'area=${_f(observation.areaRatio)} '
          'cx=${_f(observation.centerX)}',
        );
      }
      return observation;
    } catch (e) {
      _envLogV1(
        '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
        'error=$e',
      );
      return const HumanObservation(hasHuman: false);
    }
  }

  bool _isReliableHumanObservation(HumanObservation observation) {
    return observation.hasHuman &&
        observation.confidence >= _reliableHumanConfidence &&
        observation.areaRatio >= _reliableHumanMinAreaRatio &&
        observation.centerX >= 0.05 &&
        observation.centerX <= 0.95;
  }

  String _turnDirectionForOwnerDx(double dx) {
    final targetOnRight = dx > 0;
    final shouldTurnRight =
        _invertOwnerTurnDirection ? !targetOnRight : targetOnRight;
    final direction = shouldTurnRight ? '右转' : '左转';
    _envLogV1(
      '[ENV_V1_TURN_DIR] dx=${_f(dx)} '
      'invert=$_invertOwnerTurnDirection direction=$direction',
    );
    return direction;
  }

  Future<bool> _safeSendCommandV1(String command, int value) async {
    return _safeSendCommandV1WithPhase(command, value, phase: 'env_v1_command');
  }

  Future<bool> _safeSendCommandV1WithPhase(
    String command,
    int value, {
    required String phase,
  }) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _envLogV1('[ENV_V1_CHASSIS] unavailable reason=disconnected');
      await _degradeToVoiceExpressionOnly('disconnected');
      return false;
    }

    try {
      _envV1MotionCommandInFlight = true;
      if (command == '左转' || command == '右转') {
        final effectiveValue = _edgeCautiousTurnAngleV1(value, phase: phase);
        _envLogV1(
          '[BT_TURN] command=$command angleDeg=$effectiveValue source=ENV_V1',
        );
        return _sendTurnCommandWithFrontCliffResumeV1(
          service,
          command,
          effectiveValue,
          phase: phase,
        );
      } else if (command == '停止') {
        _envLogV1('[ENV_V1_CHASSIS] send_stop source=ENV_V1');
      } else if (command == '前进' || command == '后退') {
        value = _edgeCautiousLinearDistanceV1(value, phase: phase);
      }
      await service.sendCommand(command, value);
      if (command == '左转' || command == '右转') {
        await Future<void>.delayed(_shortSettleDelay);
      }
      return true;
    } catch (e) {
      _envLogV1('[ENV_V1_CHASSIS] write_failed command=$command error=$e');
      await _degradeToVoiceExpressionOnly('write_failed');
      await _bestEffortStopAfterWriteFailed(command);
      return false;
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  int? _turnCommandCodeV1(String command) {
    if (command == '左转') return 0x03;
    if (command == '右转') return 0x04;
    return null;
  }

  int _registerFrontCliffInterruptV1(String phase) {
    final next = (_frontCliffInterruptsByPhaseV1[phase] ?? 0) + 1;
    _frontCliffInterruptsByPhaseV1[phase] = next;
    return next;
  }

  void _clearFrontCliffInterruptsV1(String phase) {
    _frontCliffInterruptsByPhaseV1.remove(phase);
  }

  bool _consumeTurnSensorIncidentV1(
    String phase, {
    required String logPrefix,
  }) {
    if (_lastTurnSensorIncidentPhaseV1 != phase ||
        !_isNonFatalSensorIncidentV1(_lastTurnSensorIncidentV1)) {
      return false;
    }
    final incident = _lastTurnSensorIncidentV1;
    _lastTurnSensorIncidentV1 = _ChassisSensorIncidentV1.none;
    _lastTurnSensorIncidentPhaseV1 = null;
    _envLogV1(
      '$logPrefix motion_interrupted '
      'code=${_sensorIncidentCodeV1(incident)} '
      'action=skip_step_keep_scanning',
    );
    _envLogV1(
      '[ENV_V1_OBJECT_RETURN] keep_monitoring_after_interrupt=true',
    );
    return true;
  }

  bool _consumeFrontCliffTurnRecoveryV1(String phase) {
    if (_lastFrontCliffRecoveredTurnPhaseV1 != phase) {
      return false;
    }
    _lastFrontCliffRecoveredTurnPhaseV1 = null;
    return true;
  }

  Future<bool> _sendTurnCommandWithFrontCliffResumeV1(
    MyBluetoothService service,
    String command,
    int angleDeg, {
    required String phase,
  }) async {
    final commandCode = _turnCommandCodeV1(command);
    if (commandCode == null) {
      await service.sendCommand(command, angleDeg);
      return true;
    }

    MotionInterruptedEvent? interrupted;
    _lastTurnSensorIncidentV1 = _ChassisSensorIncidentV1.none;
    _lastTurnSensorIncidentPhaseV1 = null;
    final sub = service.responseStream.listen((event) {
      if (event is MotionInterruptedEvent && event.command == commandCode) {
        final incident = _sensorIncidentFromObstacleTypeV1(event.obstacleType);
        _lastTurnSensorIncidentV1 = incident;
        _lastTurnSensorIncidentPhaseV1 = phase;
        if (_isCliffObstacleTypeV1(event.obstacleType)) {
          interrupted ??= event;
        }
      }
    });

    try {
      await service.sendCommand(command, angleDeg);
    } finally {
      await sub.cancel();
    }

    final event = interrupted;
    if (event == null) {
      if (_lastTurnSensorIncidentPhaseV1 == phase &&
          _isNonFatalSensorIncidentV1(_lastTurnSensorIncidentV1)) {
        if (phase.startsWith('object_probe') ||
            phase.startsWith('object_return')) {
          return false;
        }
        _envLogV1(
          '[ENV_V1_CHASSIS] turn_interrupted_nonfatal '
          'phase=$phase obstacle=${_sensorIncidentNameV1(_lastTurnSensorIncidentV1)} '
          'code=${_sensorIncidentCodeV1(_lastTurnSensorIncidentV1)} '
          'action=keep_monitoring',
        );
      }
      _clearFrontCliffInterruptsV1(phase);
      return true;
    }

    final interruptCount = _registerFrontCliffInterruptV1(phase);
    _envLogV1(
      '[ENV_V1_CLIFF] turn_interrupted direction=$command '
      'angle=$angleDeg phase=$phase',
    );
    if (phase == 'idle_recenter') {
      await _handleIdleRecenterFrontCliffInterruptV1();
      return false;
    }

    final recovered = await _recoverFromFrontCliffV1(
      phase: phase,
      interruptedCommand: command,
      interruptedAngleDeg: angleDeg,
      obstacleType: event.obstacleType,
    );
    if (!recovered) {
      _envLogV1(
        '[ENV_V1_OBJECT_RETURN] motion_interrupted '
        'code=${_sensorIncidentCodeV1(_lastTurnSensorIncidentV1)} '
        'action=motion_paused_keep_monitoring',
      );
      return false;
    }

    if (interruptCount >= _frontCliffMaxRepeatedByPhaseV1) {
      _envLogV1(
        '[ENV_V1_CLIFF] repeated_front_cliff '
        'phase=$phase count=$interruptCount',
      );
      _markObjectReturnSafetyStopReasonV1('repeated_front_cliff');
      await _safeSendCommandV1('停止', 0);
      return false;
    }

    final retryAngle = _edgeCautiousTurnAngleV1(
      _frontCliffResumeAngleDegV1(angleDeg),
      phase: phase,
    );
    _envLogV1(
      '[ENV_V1_CLIFF] resume_turn direction=$command '
      'originalAngle=$angleDeg resumeAngle=$retryAngle '
      'cap=$_frontCliffResumeTurnCapDegV1 reason=after_front_cliff',
    );
    final resumed = await _sendTurnCommandWithFrontCliffResumeV1(
      service,
      command,
      retryAngle,
      phase: phase,
    );
    if (resumed) {
      _lastFrontCliffRecoveredTurnPhaseV1 = phase;
      _envLogV1('[ENV_V1_CLIFF] resume_chain phase=$phase');
    }
    return resumed;
  }

  int _frontCliffResumeAngleDegV1(int originalAngleDeg) {
    if (originalAngleDeg <= 0) {
      return _frontCliffResumeTurnMinDegV1;
    }
    if (originalAngleDeg < _frontCliffResumeTurnMinDegV1) {
      return originalAngleDeg;
    }
    if (originalAngleDeg > _frontCliffResumeTurnCapDegV1) {
      return _frontCliffResumeTurnCapDegV1;
    }
    return originalAngleDeg;
  }

  Future<void> _handleIdleRecenterFrontCliffInterruptV1() async {
    _envLogV1('[ENV_V1_CLIFF] idle_recenter_cliff stop_no_resume');
    _envLogV1('[ENV_V1_IDLE_RECENTER] stop_no_resume reason=edge_risk');
    _lastFrontCliffRecoveredTurnPhaseV1 = null;
    _clearFrontCliffInterruptsV1('idle_recenter');

    if (_isFrontCliffAutoBackoffByBluetoothV1()) {
      _envLogV1('[ENV_V1_CLIFF] backoff_owner=bluetooth_service');
      _envLogV1('[ENV_V1_CLIFF] duplicate_backoff_prevented=true');
    }

    final stopped = await _sendIdleRecenterStopSafeV1();
    if (!stopped) {
      _markObjectReturnMovementSafetyStopReasonV1();
    }
    await Future<void>.delayed(
      const Duration(milliseconds: _idleRecenterSettleMsV1),
    );
    _stopIdleRecenterAfterObjectReturnV1(reason: 'cliff_detected');
  }

  Future<bool> _sendIdleRecenterStopSafeV1() async {
    _envLogV1('[ENV_V1_CHASSIS] send_stop source=ENV_V1_IDLE_RECENTER');
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      _envLogV1('[ENV_V1_CHASSIS] unavailable reason=disconnected');
      await _degradeToVoiceExpressionOnly('disconnected');
      return false;
    }

    try {
      _envV1MotionCommandInFlight = true;
      await service.sendCommand('停止', 0);
      return true;
    } catch (e) {
      _envLogV1('[ENV_V1_CHASSIS] write_failed command=停止 error=$e');
      await _degradeToVoiceExpressionOnly('write_failed');
      return false;
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  Future<void> _bestEffortStopAfterWriteFailed(String failedCommand) async {
    final service = _bluetoothService;
    if (failedCommand == '停止') {
      _envLogV1(
          '[ENV_V1_CHASSIS] best_effort_stop skipped reason=already_stop');
      return;
    }
    if (service == null || !service.isConnected) {
      _envLogV1(
          '[ENV_V1_CHASSIS] best_effort_stop skipped reason=disconnected');
      return;
    }

    try {
      _envLogV1('[ENV_V1_CHASSIS] best_effort_stop start');
      await service.sendCommand('停止', 0);
      _envLogV1('[ENV_V1_CHASSIS] best_effort_stop done');
    } catch (e) {
      _envLogV1('[ENV_V1_CHASSIS] best_effort_stop failed error=$e');
    }
  }

  Future<void> _degradeToVoiceExpressionOnly(String reason) async {
    if (_degradedToVoiceExpressionOnly) return;
    _degradedToVoiceExpressionOnly = true;
    _cancelPendingObjectLookAroundTimerV1(reason: 'chassis_degraded_$reason');
    _cancelStatePollTimer();
    _envLogV1('[ENV_V1_CHASSIS] degrade_to_voice_expression_only');
    _monitorStatus = '底盘不可用，降级为语音和表情陪伴';
    await _loadExpression('assets/emotion/face2/眨眼.json');
  }

  Future<void> _loadExpression(String expressionPath) async {
    try {
      _uiModule?.setAnimation(expressionPath);
      _envLogV1('🎭 环境监测 V1 表情: $expressionPath');
    } catch (e) {
      _envLogV1('❌ 环境监测 V1 表情切换失败: $e');
    }
  }

  Future<void> speakWithInterruptProtection(String text) async {
    try {
      if (_ttsService == null) {
        _envLogV1('⚠️ TTS服务未设置，无法语音播报: $text');
        return;
      }
      if (_isTtsPlaying) {
        _envLogV1('⚠️ TTS正在播放，跳过语音播报: $text');
        return;
      }
      _envLogV1('🎤 环境监测 V1 语音播报: $text');
      await _ttsService!.speak(text);
    } catch (e) {
      _envLogV1('❌ 环境监测 V1 语音播报失败: $e');
    }
  }

  Future<void> _cleanupEnvironmentMonitoring() async {
    _envLogV1('🧹 清理环境监测 V1 状态');
    _isEnvironmentMonitoring = false;
    _cancelPendingObjectLookAroundTimerV1(reason: 'env_monitoring_stopped');
    _stopIdleRecenterAfterObjectReturnV1(reason: 'env_stopped');
    _degradedToVoiceExpressionOnly = false;
    _ownerFoundAtV1 = null;
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
    _objectLookAroundRunningV1 = false;
    _objectReturnSafeStopWaitingV1 = false;
    _objectGenericSpeechCountV1 = 0;
    _objectReturnPendingSafeStopReasonV1 = null;
    _lastFrontCliffRecoveredTurnPhaseV1 = null;
    _lastTurnSensorIncidentV1 = _ChassisSensorIncidentV1.none;
    _lastTurnSensorIncidentPhaseV1 = null;
    _frontCliffInterruptsByPhaseV1.clear();
    _envV1MotionCommandInFlight = false;
    _envV1EdgeCautiousMode = false;
    _envV1EdgeCautiousUntil = null;
    _monitorStatus = '环境监测已关闭';
    _cancelStatePollTimer();
    _quietCompanionTimer?.cancel();
    _quietCompanionTimer = null;

    try {
      final service = _bluetoothService;
      if (service != null && service.isConnected) {
        await service.sendCommand('停止', 0);
      }
    } catch (e) {
      _envLogV1('[ENV_V1_CHASSIS] stop_on_cleanup_failed error=$e');
    }

    await _stopRealtimeObjectDetectionForEnvV1(reason: 'cleanup');
    await _stopRealtimeHumanDetectionForEnvV1();
    await _disposeCameraService();
    _uiModule?.setProgramMode(ProgramMode.idle);
    _envLogV1('✅ 环境监测 V1 状态清理完成');
  }

  void _cancelStatePollTimer() {
    if (_statePollTimer == null) return;
    _statePollTimer?.cancel();
    _statePollTimer = null;
    _envLogV1('[ENV_V1_CLEANUP] state_poll_timer_cancelled');
  }

  void _restartStatePollTimer() {
    _cancelStatePollTimer();
    final isAnswering = _isAnsweringProvider;
    final isTtsPlaying = _isTtsPlayingProvider;
    if (isAnswering == null || isTtsPlaying == null) return;
    _statePollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _refreshExternalActivityStateV1();
      _cancelPendingObjectLookAroundIfInterruptedV1();
      _stopIdleRecenterIfInterruptedV1();
    });
  }

  void _refreshExternalActivityStateV1() {
    final isAnswering = _isAnsweringProvider;
    final isTtsPlaying = _isTtsPlayingProvider;
    if (isAnswering == null || isTtsPlaying == null) return;

    try {
      _isAnswering = isAnswering();
      _isTtsPlaying = isTtsPlaying();
    } catch (e) {
      _envLogV1('[ENV_V1_STATE] poll_failed error=$e');
    }
  }

  Future<void> _disposeCameraService() async {
    final camera = _cameraService;
    if (camera == null) return;
    try {
      camera.stopRealTimeDetection();
      await camera.dispose();
      _envLogV1('📷 环境监测 V1 摄像头资源已释放');
    } catch (e) {
      _envLogV1('⚠️ 环境监测 V1 摄像头释放失败: $e');
    } finally {
      if (identical(_cameraService, camera)) {
        _cameraService = null;
      }
    }
  }

  String _f(double value) => value.toStringAsFixed(3);
}

class _TurnStep {
  const _TurnStep(this.command, this.angleDeg);

  final String command;
  final int angleDeg;
}

class _ObjectProbePlanV1 {
  const _ObjectProbePlanV1({
    required this.turnCommand,
    required this.turnLabel,
    required this.turnAngleDeg,
    required this.turnBackCommand,
  });

  final String turnCommand;
  final String turnLabel;
  final int turnAngleDeg;
  final String turnBackCommand;
}

enum _ObjectSpeechModeV1 {
  none,
  genericVisualPresence,
}

class _RealtimeObjectSampleV1 {
  const _RealtimeObjectSampleV1({
    required this.object,
    required this.observedAt,
  });

  final DetectedDesktopObject object;
  final DateTime observedAt;
}

class _RealtimeObjectProbeAnalysisV1 {
  const _RealtimeObjectProbeAnalysisV1({
    this.bestLowCandidate,
    this.stableCandidate,
    this.bestHits = 0,
    this.bestPolicy,
  });

  final DetectedDesktopObject? bestLowCandidate;
  final DetectedDesktopObject? stableCandidate;
  final int bestHits;
  final EnvV1ObjectPolicy? bestPolicy;
}

class _ObjectProbeDecisionV1 {
  const _ObjectProbeDecisionV1({
    required this.object,
    required this.source,
    required this.speechMode,
    required this.reason,
    this.realtimeHits = 0,
    this.rejectedObject,
    this.policy = EnvV1ObjectPolicy.unknown,
  });

  final DetectedDesktopObject? object;
  final String source;
  final _ObjectSpeechModeV1 speechMode;
  final String reason;
  final int realtimeHits;
  final DetectedDesktopObject? rejectedObject;
  final EnvV1ObjectPolicy policy;

  DetectedDesktopObject? get logObject => object ?? rejectedObject;
}

class _ObjectProbeRunResultV1 {
  const _ObjectProbeRunResultV1({
    required this.restoredToAnchor,
    required this.foundObject,
    required this.shouldContinue,
    this.finishedGracefully = false,
    this.bestObject,
    this.bestSource,
    this.usedMicroApproach = false,
    this.genericSpeechCountDelta = 0,
  });

  final bool restoredToAnchor;
  final bool foundObject;
  final bool shouldContinue;
  final bool finishedGracefully;
  final DetectedDesktopObject? bestObject;
  final String? bestSource;
  final bool usedMicroApproach;
  final int genericSpeechCountDelta;
}

class _ObjectMicroConfirmResultV1 {
  const _ObjectMicroConfirmResultV1({
    this.usedMicroApproach = false,
    this.cliffDetected = false,
    this.confirmedObject,
  });

  final bool usedMicroApproach;
  final bool cliffDetected;
  final DetectedDesktopObject? confirmedObject;
}

class _LinearMotionGuardResultV1 {
  const _LinearMotionGuardResultV1({
    required this.success,
    this.cliffDetected = false,
    this.recoverySucceeded = false,
    this.safeStopRequired = false,
    this.incident = _ChassisSensorIncidentV1.none,
    this.error = '',
  });

  final bool success;
  final bool cliffDetected;
  final bool recoverySucceeded;
  final bool safeStopRequired;
  final _ChassisSensorIncidentV1 incident;
  final String error;
}
