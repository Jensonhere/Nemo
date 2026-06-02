import 'dart:async';

import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart'
    show MyBluetoothService;
import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/desktop_object_detector.dart';
import 'package:voicegpt/core/services/voice_tts_service.dart';

enum SnapshotTargetType {
  none,
  face,
  person,
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

class EnvironMonitorModule {
  static const bool _invertOwnerTurnDirection = false;
  static const bool _enableStartSearchSpeechAfterPreLookFail = true;
  static const bool _enableObjectLookAroundAfterOwnerFoundV1 = true;
  static const bool _enableWeakObjectSpeechV1 = true;
  static const int _preLookAroundSweepAngleDeg = 18;
  static const int _objectLookAroundTurnStepDeg = 30;
  static const int _objectLookAroundMaxAccumulatedTurnDeg = 60;
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
  static const Duration _settleDelay = Duration(milliseconds: 220);
  static const Duration _shortSettleDelay = Duration(milliseconds: 160);
  static const Duration _quietCompanionInterval = Duration(seconds: 45);
  static const Duration _objectLookAroundDelayAfterOwnerFoundV1 =
      Duration(seconds: 30);
  static const Duration _objectLookAroundPreStartStopSettleV1 =
      Duration(milliseconds: 200);

  MyBluetoothService? _bluetoothService;
  VoiceTtsService? _ttsService;
  UIAnimationModule? _uiModule;
  CameraService? _cameraService;

  Timer? _statePollTimer;
  Timer? _quietCompanionTimer;
  Timer? _pendingObjectLookAroundTimerV1;
  StreamSubscription<List<dynamic>>? _envRealtimeHumanSubscription;

  bool _isEnvironmentMonitoring = false;
  bool _isAnswering = false;
  bool _isTtsPlaying = false;
  bool _degradedToVoiceExpressionOnly = false;
  bool _envRealtimeHumanRunning = false;
  bool _quietCompanionActiveV1 = false;
  bool _ownerAlignmentActiveV1 = false;
  bool _envV1MotionCommandInFlight = false;
  bool _objectLookAroundExecutedV1 = false;
  bool _objectLookAroundRunningV1 = false;
  HumanObservation? _recentRealtimeHuman;
  DateTime? _recentRealtimeHumanAt;
  DateTime? _ownerFoundAtV1;
  String _monitorStatus = '环境监测已关闭';
  bool Function()? _isAnsweringProvider;
  bool Function()? _isTtsPlayingProvider;

  void setBluetoothService(MyBluetoothService bluetoothService) {
    _bluetoothService = bluetoothService;
    print('🔗 环境监测模块：蓝牙服务已设置');
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
      print('[ENV_V1] already_running status=$_monitorStatus');
      return;
    }

    _resetObjectLookAroundSessionV1();
    _restartStatePollTimer();
    _isEnvironmentMonitoring = true;
    _degradedToVoiceExpressionOnly = false;
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
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

  Future<void> _runEnvironmentMonitorV1() async {
    print('[ENV_V1] start');
    _uiModule?.setProgramMode(ProgramMode.environmentCheck);
    _ownerAlignmentActiveV1 = true;

    try {
      await _ensureCameraService();
      await _startRealtimeHumanDetectionForEnvV1();
      if (!_isEnvironmentMonitoring) return;

      await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');
      print('[ENV_V1] start_owner_search_speech');
      await speakWithInterruptProtection('主人，你在这里吗？');
      if (!_isEnvironmentMonitoring) return;

      final preLookFound = await _runPreLookAroundOwnerV1();
      final HumanObservation? found;
      if (preLookFound != null) {
        print('[ENV_V1] prelook_found skip_start_search_speech');
        found = preLookFound;
      } else {
        print(
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

      if (finalResult.finalAlignmentStatus ==
          SnapshotAlignStatus.stillOffcenter) {
        finalResult = await _runSilentReacquireAfterFinalOffcenterV1(
          finalResult,
        );
      }
      if (!_isEnvironmentMonitoring) return;

      await _runInteractOwnerV1(finalResult);
      _ownerAlignmentActiveV1 = false;
      if (!_isEnvironmentMonitoring) return;
    } catch (e, st) {
      _monitorStatus = '环境监测 V1 异常: $e';
      print('[ENV_V1] error=$e\n$st');
      await _degradeToVoiceExpressionOnly('exception');
    } finally {
      _ownerAlignmentActiveV1 = false;
      await _stopRealtimeHumanDetectionForEnvV1();
      await _disposeCameraService();
      await _enterQuietCompanionModeV1();
    }
  }

  Future<HumanObservation?> _runSearchOwnerV1() async {
    print('[ENV_V1_SEARCH] start');
    _monitorStatus = 'SEARCH: 原地找人';

    final initial = await _detectHumanObservationSafe(phase: 'search_initial');
    print(
      '[ENV_V1_SEARCH] initial_check hasHuman=${initial.hasHuman} '
      'conf=${_f(initial.confidence)} area=${_f(initial.areaRatio)} '
      'cx=${_f(initial.centerX)}',
    );
    if (_isReliableHumanObservation(initial)) {
      print('[ENV_V1_SEARCH] confirmed');
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
      print('[ENV_V1_SEARCH] $tag angle=${step.angleDeg}');
      final moved = await _safeSendCommandV1(step.command, step.angleDeg);
      if (!moved) {
        print(
            '[ENV_V1_SEARCH] abort reason=bluetooth_disconnected/write_failed');
        return null;
      }

      await _safeSendCommandV1('停止', 0);
      await Future<void>.delayed(_settleDelay);

      final candidate = await _detectHumanObservationSafe(
        phase: 'search_sweep',
      );
      print(
        '[ENV_V1_SEARCH] candidate conf=${_f(candidate.confidence)} '
        'area=${_f(candidate.areaRatio)} cx=${_f(candidate.centerX)}',
      );
      if (_isReliableHumanObservation(candidate)) {
        print('[ENV_V1_SEARCH] confirmed');
        return candidate;
      }
    }

    await _safeSendCommandV1('停止', 0);
    print('[ENV_V1_SEARCH] no_target');
    return null;
  }

  Future<HumanObservation?> _runPreLookAroundOwnerV1() async {
    print('[ENV_V1_PRELOOK] start');
    _monitorStatus = 'PRELOOK: 原地张望';

    final front = await _detectHumanObservationSafe(phase: 'prelook_front');
    print(
      '[ENV_V1_PRELOOK] front_check hasHuman=${front.hasHuman} '
      'conf=${_f(front.confidence)} area=${_f(front.areaRatio)} '
      'cx=${_f(front.centerX)}',
    );
    if (_isReliableHumanObservation(front)) {
      print('[ENV_V1_PRELOOK] found phase=front');
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

    print('[ENV_V1_PRELOOK] no_target');
    return null;
  }

  Future<HumanObservation?> _turnPreLookAndDetectOwnerV1({
    required String command,
    required int angleDeg,
    required String phase,
  }) async {
    final tag = command == '左转' ? 'turn_left' : 'turn_right';
    print('[ENV_V1_PRELOOK] $tag angle=$angleDeg');

    final moved = await _safeSendCommandV1(command, angleDeg);
    if (!moved) {
      print('[ENV_V1_PRELOOK] no_target');
      return null;
    }

    await _safeSendCommandV1('停止', 0);
    await Future<void>.delayed(_settleDelay);

    final candidate = await _detectHumanObservationSafe(
      phase: 'prelook_$phase',
    );
    print(
      '[ENV_V1_PRELOOK] candidate phase=$phase '
      'conf=${_f(candidate.confidence)} area=${_f(candidate.areaRatio)} '
      'cx=${_f(candidate.centerX)}',
    );
    if (_isReliableHumanObservation(candidate)) {
      print('[ENV_V1_PRELOOK] found phase=$phase');
      return candidate;
    }
    return null;
  }

  Future<HumanObservation> _runTrackOwnerV1(
    HumanObservation initial, {
    int maxLoops = _ownerTrackMaxLoopsV1,
  }) async {
    print(
      '[ENV_V1_TRACK] start cx=${_f(initial.centerX)} '
      'dx=${_f(initial.centerX - 0.5)}',
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
          allowSnapshotFallback: true,
        );
        source = 'realtime_or_snapshot_fallback';
      }

      if (!_isReliableHumanObservation(current)) {
        print('[ENV_V1_TRACK] loop=$loop no reliable human, break');
        break;
      }

      lastReliable = current;
      final dx = current.centerX - 0.5;
      final absDx = dx.abs();
      print(
        '[ENV_V1_TRACK] loop=$loop source=$source '
        'cx=${_f(current.centerX)} dx=${_f(dx)} absDx=${_f(absDx)}',
      );

      if (absDx <= _ownerTrackDeadZoneV1) {
        print(
          '[ENV_V1_TRACK] loop=$loop centered_by_human '
          'absDx=${_f(absDx)}',
        );
        return current;
      }

      final angle = absDx > _ownerTrackSoftZoneV1 ? 12 : 6;
      final direction = _turnDirectionForOwnerDx(dx);
      print(
        '[ENV_V1_TRACK] loop=$loop recenter '
        'direction=$direction angle=$angle',
      );

      final moved = await _safeSendCommandV1(direction, angle);
      if (!moved) {
        print('[ENV_V1_TRACK] loop=$loop recenter_failed reason=turn');
        return lastReliable;
      }

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        print('[ENV_V1_TRACK] loop=$loop recenter_failed reason=stop');
        return lastReliable;
      }
      await Future<void>.delayed(_ownerTrackSettleV1);
      current = null;
    }

    print('[ENV_V1_TRACK] finished max_loops_or_no_target');
    return lastReliable;
  }

  Future<SnapshotAlignResult> _runConfirmOwnerBySnapshotV1(
    HumanObservation tracked,
  ) async {
    _monitorStatus = 'CONFIRM: snapshot 视觉确认';
    print('[ENV_V1_CONFIRM] capture start');
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
        print('[ENV_V1_CONFIRM] target=none reason=camera_unavailable');
        return SnapshotAlignResult.noTarget(humanObservation: tracked);
      }

      final imagePath = await camera.captureImage();
      print('[ENV_V1_CONFIRM] imagePath=$imagePath');

      final face = await camera.detectFaceObservationFromImagePath(imagePath);
      print(
        '[ENV_V1_CONFIRM] face hasFace=${face.hasFace} '
        'conf=${_f(face.confidence)} cx=${_f(face.centerX)}',
      );

      final person =
          await camera.detectHumanObservationFromImagePath(imagePath);
      print(
        '[ENV_V1_CONFIRM] person hasHuman=${person.hasHuman} '
        'conf=${_f(person.confidence)} area=${_f(person.areaRatio)} '
        'cx=${_f(person.centerX)}',
      );

      if (face.hasFace) {
        print('[ENV_V1_CONFIRM] target=face');
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
        print('[ENV_V1_CONFIRM] target=person');
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

      print('[ENV_V1_CONFIRM] target=none');
      return SnapshotAlignResult.noTarget(
        humanObservation: tracked,
        imagePath: imagePath,
      );
    } catch (e) {
      print('[ENV_V1_CONFIRM] target=none error=$e');
      return SnapshotAlignResult.noTarget(humanObservation: tracked);
    }
  }

  Future<SnapshotAlignResult> _runFinalFaceCenteringV1(
    SnapshotAlignResult result,
  ) async {
    print(
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
      print(
        '[ENV_V1_FINAL_CENTER] round=$round target=$target '
        'cx=${_f(current.centerX)} dx=${_f(dx)}',
      );

      if (current.targetType == SnapshotTargetType.none) {
        print(
          '[ENV_V1_FINAL_CENTER] decision action=no_target '
          'direction=none angle=0',
        );
        print('[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.noTarget}');
        return current.copyWith(
          canProceed: false,
          finalAlignmentStatus: SnapshotAlignStatus.noTarget,
        );
      }

      if (current.targetType == SnapshotTargetType.person) {
        final status = absDx <= _verifiedPersonAcceptableDx
            ? SnapshotAlignStatus.verifiedPersonAcceptable
            : SnapshotAlignStatus.stillOffcenter;
        print(
          '[ENV_V1_FINAL_CENTER] decision action=person_only '
          'direction=none angle=0',
        );
        print('[ENV_V1_FINAL_CENTER] result=$status');
        return current.copyWith(finalAlignmentStatus: status);
      }

      final faceDx =
          (current.faceObservation?.centerX ?? current.centerX) - 0.5;
      final absFaceDx = faceDx.abs();
      print(
        '[ENV_V1_FINAL_CENTER] round=$round faceDx=${_f(faceDx)} '
        'absDx=${_f(absFaceDx)}',
      );

      if (absFaceDx <= _verifiedFaceCenteredDx) {
        print(
          '[ENV_V1_FINAL_CENTER] decision action=centered '
          'direction=none angle=0',
        );
        print(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.verifiedFaceCentered}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.verifiedFaceCentered,
        );
      }

      if (absFaceDx <= _verifiedFaceAcceptableDx) {
        print(
          '[ENV_V1_FINAL_CENTER] decision action=acceptable '
          'direction=none angle=0',
        );
        print(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.verifiedFaceAcceptable}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.verifiedFaceAcceptable,
        );
      }

      if (round >= _finalFaceCenterMaxCorrectionRoundsV1) {
        final updated = _classifyAfterNudge(current);
        print('[ENV_V1_FINAL_CENTER] result=$updated');
        return current.copyWith(finalAlignmentStatus: updated);
      }

      final angle = _finalFaceNudgeAngleV1(
        absFaceDx,
        overshotLastNudge: overshotLastNudge,
      );
      final direction = _turnDirectionForOwnerDx(faceDx);
      print(
        '[ENV_V1_FINAL_CENTER] round=$round recenter '
        'direction=$direction angle=$angle',
      );

      final moved = await _safeSendCommandV1(direction, angle);
      if (!moved) {
        print(
          '[ENV_V1_FINAL_CENTER] result='
          '${SnapshotAlignStatus.stillOffcenter}',
        );
        return current.copyWith(
          finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
        );
      }

      final stopped = await _safeSendCommandV1('停止', 0);
      if (!stopped) {
        print(
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
      print(
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
          print(
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
    print('[ENV_V1_FINAL_CENTER] result=$updated');
    return current.copyWith(finalAlignmentStatus: updated);
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

    print('[ENV_V1_FINAL_RECOVER] start reason=still_offcenter');
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
      print('[ENV_V1_FINAL_RECOVER] abort reason=no_reliable_human');
      return previous;
    }

    final tracked = await _runTrackOwnerV1(seed, maxLoops: 2);
    if (!_isEnvironmentMonitoring) return previous;

    final confirmed = await _runConfirmOwnerBySnapshotV1(tracked);
    if (!_isEnvironmentMonitoring) return confirmed;

    final recovered = await _runFinalFaceCenteringV1(confirmed);
    print(
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
    final isStrictlyCentered =
        result.finalAlignmentStatus == SnapshotAlignStatus.verifiedFaceCentered;
    final objectLookAroundReason =
        _objectLookAroundScheduleReasonForStatusV1(result.finalAlignmentStatus);
    final canHoldForObjectLookAround =
        _enableObjectLookAroundAfterOwnerFoundV1 &&
            objectLookAroundReason != null;
    final greetingLine = _greetingLineForStatus(result.finalAlignmentStatus);

    if (greetingLine != null) {
      print(
        '[ENV_V1_INTERACT] status=${result.finalAlignmentStatus} '
        'strict_centered=$isStrictlyCentered speak_found_owner=true',
      );
      if (canHoldForObjectLookAround) {
        await _sendImmediateStopV1(phase: 'owner_found_hold');
        if (!_isEnvironmentMonitoring) return;
      }
      await _loadExpression('assets/emotion/face2/可爱/02/可爱 02.json');
      await speakWithInterruptProtection(greetingLine);
      if (!_isEnvironmentMonitoring) return;
      final scheduledObjectLookAround =
          _checkAndScheduleObjectLookAroundAfterOwnerFoundV1(
        status: result.finalAlignmentStatus,
        strictCentered: isStrictlyCentered,
      );
      if (scheduledObjectLookAround) {
        print(
          '[ENV_V1_INTERACT] skip_companion_invite '
          'reason=object_look_around_pending',
        );
      } else {
        await speakWithInterruptProtection('要不要和我说句话？');
      }
    } else {
      print(
        '[ENV_V1_INTERACT] status=${result.finalAlignmentStatus} '
        'speak_skipped reason=not_aligned',
      );
      await _loadExpression('assets/emotion/face2/眨眼.json');
      _checkAndScheduleObjectLookAroundAfterOwnerFoundV1(
        status: result.finalAlignmentStatus,
        strictCentered: isStrictlyCentered,
      );
    }

    if (!_isEnvironmentMonitoring) return;
    print('[ENV_V1_INTERACT] enter_quiet_companion');
  }

  bool _checkAndScheduleObjectLookAroundAfterOwnerFoundV1({
    required String status,
    required bool strictCentered,
  }) {
    print(
      '[ENV_V1_OBJECT_DELAY] schedule_check status=$status '
      'strictCentered=$strictCentered '
      'enable=$_enableObjectLookAroundAfterOwnerFoundV1',
    );

    if (!_enableObjectLookAroundAfterOwnerFoundV1) {
      print(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=feature_disabled status=$status',
      );
      return false;
    }

    final reason = _objectLookAroundScheduleReasonForStatusV1(status);
    if (reason == null) {
      print(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=status_not_owner_seen status=$status',
      );
      return false;
    }

    if (_objectLookAroundExecutedV1) {
      print(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=already_executed status=$status',
      );
      return false;
    }
    if (_objectLookAroundRunningV1) {
      print(
        '[ENV_V1_OBJECT_DELAY] not_scheduled '
        'reason=already_running status=$status',
      );
      return false;
    }

    _scheduleObjectLookAroundAfterOwnerFoundV1(reason: reason);
    return true;
  }

  String? _objectLookAroundScheduleReasonForStatusV1(String status) {
    if (status == SnapshotAlignStatus.verifiedFaceCentered) {
      return 'owner_seen';
    }
    if (status == SnapshotAlignStatus.verifiedFaceAcceptable) {
      return 'owner_seen_acceptable';
    }
    return null;
  }

  void _scheduleObjectLookAroundAfterOwnerFoundV1({required String reason}) {
    _ownerFoundAtV1 = DateTime.now();
    print(
      '[ENV_V1_INTERACT] owner_found_hold still for '
      '${_objectLookAroundDelayAfterOwnerFoundV1.inSeconds}s before object '
      'look-around',
    );

    _cancelPendingObjectLookAroundTimerV1(reason: 'reschedule_owner_found');
    _pendingObjectLookAroundTimerV1 = Timer(
      _objectLookAroundDelayAfterOwnerFoundV1,
      () => unawaited(_handleObjectLookAroundDelayElapsedV1()),
    );
    print(
      '[ENV_V1_OBJECT_DELAY] scheduled '
      'delay=${_objectLookAroundDelayAfterOwnerFoundV1.inSeconds}s '
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
      print(
        '[ENV_V1_OBJECT_DELAY] elapsed allowed=false '
        'reason=$skipReason heldMs=$heldMs',
      );
      return;
    }

    print('[ENV_V1_OBJECT_DELAY] elapsed allowed=true heldMs=$heldMs');
    print('[ENV_V1_OBJECT_DELAY] elapsed start object look-around');
    final hadCameraService = _cameraService != null;
    _objectLookAroundRunningV1 = true;
    _quietCompanionActiveV1 = false;

    try {
      await _ensureCameraService();
      if (!_isEnvironmentMonitoring) return;

      final stopped = await _sendImmediateStopV1(phase: 'object_look_start');
      if (!stopped) {
        print('[ENV_V1_OBJECT_DELAY] skipped reason=pre_start_stop_failed');
        return;
      }
      await Future<void>.delayed(_objectLookAroundPreStartStopSettleV1);
      if (!_isEnvironmentMonitoring) return;

      _objectLookAroundExecutedV1 = true;
      await _runObjectLookAroundAfterOwnerFoundV1();
    } catch (e, st) {
      print('[ENV_V1_OBJECT_DELAY] start_failed error=$e\n$st');
    } finally {
      _objectLookAroundRunningV1 = false;
      if (_isEnvironmentMonitoring) {
        if (!hadCameraService) {
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
    print('[ENV_V1_OBJECT_DELAY] canceled reason=$reason');
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
    _ownerFoundAtV1 = null;
    _objectLookAroundExecutedV1 = false;
    _objectLookAroundRunningV1 = false;
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
    _envV1MotionCommandInFlight = false;
  }

  Future<bool> _sendImmediateStopV1({required String phase}) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      print(
        '[ENV_V1_OBJECT_DELAY] stop skipped '
        'phase=$phase reason=bluetooth_disconnected',
      );
      return false;
    }

    try {
      _envV1MotionCommandInFlight = true;
      await service.sendCommand('停止', 0);
      print('[ENV_V1_OBJECT_DELAY] stop sent phase=$phase');
      return true;
    } catch (e) {
      print('[ENV_V1_OBJECT_DELAY] stop failed phase=$phase error=$e');
      return false;
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  Future<void> _runObjectLookAroundAfterOwnerFoundV1() async {
    if (!_isEnvironmentMonitoring) return;

    _monitorStatus = 'OBJECT_LOOK: 原地物体观察';
    print(
      '[ENV_V1_OBJECT] start leave_owner_view=true '
      'reason=verified_face_centered_owner_face_or_body_dominates_frame',
    );
    await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');

    final detector = DesktopObjectDetector();
    var accumulatedTurnDeg = 0;
    var returnedToOwnerDirection = false;
    var canAttemptApproximateReturn = true;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!_isEnvironmentMonitoring) return;
        if (accumulatedTurnDeg >= _objectLookAroundMaxAccumulatedTurnDeg) {
          break;
        }

        final moved =
            await _safeSendCommandV1('右转', _objectLookAroundTurnStepDeg);
        if (!moved) {
          canAttemptApproximateReturn = false;
          print('[ENV_V1_OBJECT] abort reason=turn_away_failed');
          return;
        }
        accumulatedTurnDeg += _objectLookAroundTurnStepDeg;
        print(
          '[ENV_V1_OBJECT] turn_away direction=右转 '
          'angle=$_objectLookAroundTurnStepDeg '
          'accumulated=$accumulatedTurnDeg',
        );

        final stopped = await _safeSendCommandV1('停止', 0);
        if (!stopped) {
          canAttemptApproximateReturn = false;
          print('[ENV_V1_OBJECT] abort reason=stop_after_turn_failed');
          return;
        }
        await Future<void>.delayed(_settleDelay);

        final result = await _captureAndDetectObjectSnapshotV1(detector);
        if (result == null) {
          print('[ENV_V1_OBJECT] detection_skipped reason=snapshot_failed');
          break;
        }

        await _speakWeakObjectObservationV1(result);
        if (result.hasObject) {
          break;
        }
      }
    } finally {
      await detector.close();
      if (_isEnvironmentMonitoring &&
          canAttemptApproximateReturn &&
          accumulatedTurnDeg > 0) {
        returnedToOwnerDirection = await _returnToOwnerAfterObjectLookV1(
          accumulatedTurnDeg,
          '左转',
        );
      }
    }

    if (!_isEnvironmentMonitoring) return;
    if (returnedToOwnerDirection) {
      final finalResult = await _reconfirmOwnerAfterObjectLookV1();
      print(
        '[ENV_V1_OBJECT] done final_status='
        '${finalResult.finalAlignmentStatus}',
      );
    } else {
      print(
          '[ENV_V1_OBJECT] done reason=return_owner_approx_failed_or_skipped');
    }
  }

  Future<ObjectDetectionSnapshotResult?> _captureAndDetectObjectSnapshotV1(
    DesktopObjectDetector detector,
  ) async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        print('[ENV_V1_OBJECT] snapshot skipped reason=camera_unavailable');
        return null;
      }

      final imagePath = await camera.captureImage();
      print('[ENV_V1_OBJECT] snapshot imagePath=$imagePath');

      final result =
          await detector.detectDesktopObjectsFromImagePath(imagePath);
      print(
        '[ENV_V1_OBJECT] result hasObject=${result.hasObject} '
        'rawCount=${result.rawDetectionCount} '
        'filteredCount=${result.objects.length}',
      );

      for (final object in result.objects) {
        print(
          '[ENV_V1_OBJECT] object label=${object.label} '
          'conf=${_f(object.confidence)} '
          'cx=${_f(object.centerX)} cy=${_f(object.centerY)} '
          'area=${_f(object.areaRatio)}',
        );
      }
      return result;
    } catch (e) {
      print('[ENV_V1_OBJECT] result hasObject=false error=$e');
      return null;
    }
  }

  Future<void> _speakWeakObjectObservationV1(
    ObjectDetectionSnapshotResult result,
  ) async {
    if (!_enableWeakObjectSpeechV1 || !result.hasObject) {
      return;
    }

    const text = '我好像看到一个小东西。';
    print('[ENV_V1_OBJECT] weak_speech text=$text');
    await speakWithInterruptProtection(text);
  }

  Future<bool> _returnToOwnerAfterObjectLookV1(
    int accumulatedTurnDeg,
    String returnDirection,
  ) async {
    if (accumulatedTurnDeg <= 0) {
      return true;
    }

    final boundedTurnDeg =
        accumulatedTurnDeg > _objectLookAroundMaxAccumulatedTurnDeg
            ? _objectLookAroundMaxAccumulatedTurnDeg
            : accumulatedTurnDeg;
    _monitorStatus = 'OBJECT_RETURN: 回到主人方向';
    print(
      '[ENV_V1_OBJECT] return_owner_approx '
      'direction=$returnDirection angle=$boundedTurnDeg',
    );

    final moved = await _safeSendCommandV1(returnDirection, boundedTurnDeg);
    if (!moved) {
      print('[ENV_V1_OBJECT_RETURN] approximate_return failed reason=turn');
      return false;
    }
    final stopped = await _safeSendCommandV1('停止', 0);
    if (!stopped) {
      print('[ENV_V1_OBJECT_RETURN] approximate_return failed reason=stop');
      return false;
    }
    await Future<void>.delayed(_settleDelay);
    print(
      '[ENV_V1_OBJECT_RETURN] approximate_return done '
      'accumulated=$boundedTurnDeg',
    );
    return true;
  }

  Future<SnapshotAlignResult> _reconfirmOwnerAfterObjectLookV1() async {
    _monitorStatus = 'OBJECT_RETURN: 视觉重确认主人';
    print('[ENV_V1_OBJECT_RETURN] owner_reacquire start');

    final human = await _detectHumanObservationSafe(
      phase: 'object_return_reacquire',
    );
    print(
      '[ENV_V1_OBJECT_RETURN] human hasHuman=${human.hasHuman} '
      'conf=${_f(human.confidence)} cx=${_f(human.centerX)}',
    );

    if (!_isEnvironmentMonitoring) {
      return SnapshotAlignResult.noTarget(humanObservation: human);
    }
    if (!_isReliableHumanObservation(human)) {
      final noTarget = SnapshotAlignResult.noTarget(
        humanObservation: human.hasHuman ? human : null,
      );
      print(
        '[ENV_V1_OBJECT_RETURN] final_status='
        '${noTarget.finalAlignmentStatus} reason=no_reliable_human',
      );
      return noTarget;
    }

    final tracked = await _runTrackOwnerV1(human);
    if (!_isEnvironmentMonitoring) {
      return SnapshotAlignResult.noTarget(humanObservation: tracked);
    }

    final confirmed = await _runConfirmOwnerBySnapshotV1(tracked);
    if (!_isEnvironmentMonitoring) {
      return confirmed;
    }

    final finalResult = await _runFinalFaceCenteringV1(confirmed);
    print(
      '[ENV_V1_OBJECT_RETURN] final_status='
      '${finalResult.finalAlignmentStatus}',
    );
    if (finalResult.finalAlignmentStatus ==
        SnapshotAlignStatus.verifiedFaceCentered) {
      await _loadExpression('assets/emotion/face2/可爱/02/可爱 02.json');
    }
    return finalResult;
  }

  String? _greetingLineForStatus(String status) {
    if (status == SnapshotAlignStatus.verifiedFaceCentered) {
      return '找到你啦，主人！';
    }
    if (status == SnapshotAlignStatus.verifiedFaceAcceptable ||
        status == SnapshotAlignStatus.verifiedPersonAcceptable) {
      return '我看到你啦，主人。';
    }
    return null;
  }

  Future<void> _enterQuietCompanionModeV1() async {
    if (!_isEnvironmentMonitoring) return;
    _monitorStatus = 'QUIET_COMPANION: 安静陪伴中';
    _quietCompanionActiveV1 = true;
    print('[ENV_V1_QUIET] enter mode=voice_expression_only_keep_expression');

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
    print('[ENV_V1_QUIET] micro_action action=keep_current_expression');
  }

  Future<void> _ensureCameraService() async {
    _cameraService ??= CameraService();
    await _cameraService!.initialize();
  }

  Future<void> _startRealtimeHumanDetectionForEnvV1() async {
    if (_envRealtimeHumanRunning) {
      print('[ENV_V1_RT_HUMAN] start skipped reason=already_running');
      return;
    }

    print('[ENV_V1_RT_HUMAN] start requested');
    final camera = _cameraService;
    if (camera == null) {
      print('[ENV_V1_RT_HUMAN] start failed error=camera_unavailable');
      return;
    }

    try {
      final stream = await camera.startRealTimeDetection();
      await _envRealtimeHumanSubscription?.cancel();
      _envRealtimeHumanSubscription = stream.listen(
        (recognitions) {
          final observation =
              _extractBestRealtimeHumanObservationV1(recognitions);
          print(
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
          print('[ENV_V1_RT_HUMAN] update failed error=$error');
        },
      );
      _envRealtimeHumanRunning = true;
      print('[ENV_V1_RT_HUMAN] start success');
    } catch (e) {
      _envRealtimeHumanRunning = false;
      print('[ENV_V1_RT_HUMAN] start failed error=$e');
    }
  }

  Future<void> _stopRealtimeHumanDetectionForEnvV1() async {
    if (!_envRealtimeHumanRunning &&
        _envRealtimeHumanSubscription == null &&
        _recentRealtimeHuman == null) {
      return;
    }

    print('[ENV_V1_RT_HUMAN] stop requested');
    try {
      await _envRealtimeHumanSubscription?.cancel();
      _envRealtimeHumanSubscription = null;
      _cameraService?.stopRealTimeDetection();
      print('[ENV_V1_RT_HUMAN] stop success');
    } catch (e) {
      print('[ENV_V1_RT_HUMAN] stop failed error=$e');
    } finally {
      _envRealtimeHumanRunning = false;
      _recentRealtimeHuman = null;
      _recentRealtimeHumanAt = null;
    }
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

  Future<HumanObservation> _detectHumanObservationSafe({
    String phase = 'unknown',
    bool allowSnapshotFallback = true,
  }) async {
    final realtime = _getFreshRealtimeHumanV1();
    if (realtime != null) {
      print(
        '[ENV_V1_HUMAN] phase=$phase source=realtime fresh=true '
        'hasHuman=${realtime.hasHuman} conf=${_f(realtime.confidence)} '
        'area=${_f(realtime.areaRatio)} cx=${_f(realtime.centerX)}',
      );
      return realtime;
    }

    if (!allowSnapshotFallback) {
      print(
        '[ENV_V1_HUMAN] phase=$phase source=realtime fresh=false '
        'reason=no_fresh_realtime',
      );
      return const HumanObservation(hasHuman: false);
    }

    try {
      final camera = _cameraService;
      if (camera == null) {
        print(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=camera_unavailable',
        );
        return const HumanObservation(hasHuman: false);
      }
      final observation = await camera.detectHumanObservation();
      if (_isReliableHumanObservation(observation)) {
        _cacheRealtimeHumanV1(observation);
        print(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=no_fresh_realtime hasHuman=true '
          'conf=${_f(observation.confidence)} '
          'area=${_f(observation.areaRatio)} '
          'cx=${_f(observation.centerX)}',
        );
      } else {
        print(
          '[ENV_V1_HUMAN] phase=$phase source=snapshot_fallback '
          'reason=no_fresh_realtime hasHuman=${observation.hasHuman} '
          'conf=${_f(observation.confidence)} '
          'area=${_f(observation.areaRatio)} '
          'cx=${_f(observation.centerX)}',
        );
      }
      return observation;
    } catch (e) {
      print(
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
    print(
      '[ENV_V1_TURN_DIR] dx=${_f(dx)} '
      'invert=$_invertOwnerTurnDirection direction=$direction',
    );
    return direction;
  }

  Future<bool> _safeSendCommandV1(String command, int value) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      print('[ENV_V1_CHASSIS] unavailable reason=disconnected');
      await _degradeToVoiceExpressionOnly('disconnected');
      return false;
    }

    try {
      _envV1MotionCommandInFlight = true;
      await service.sendCommand(command, value);
      if (command == '左转' || command == '右转') {
        await Future<void>.delayed(_shortSettleDelay);
      }
      return true;
    } catch (e) {
      print('[ENV_V1_CHASSIS] write_failed command=$command error=$e');
      await _degradeToVoiceExpressionOnly('write_failed');
      await _bestEffortStopAfterWriteFailed(command);
      return false;
    } finally {
      _envV1MotionCommandInFlight = false;
    }
  }

  Future<void> _bestEffortStopAfterWriteFailed(String failedCommand) async {
    final service = _bluetoothService;
    if (failedCommand == '停止') {
      print('[ENV_V1_CHASSIS] best_effort_stop skipped reason=already_stop');
      return;
    }
    if (service == null || !service.isConnected) {
      print('[ENV_V1_CHASSIS] best_effort_stop skipped reason=disconnected');
      return;
    }

    try {
      print('[ENV_V1_CHASSIS] best_effort_stop start');
      await service.sendCommand('停止', 0);
      print('[ENV_V1_CHASSIS] best_effort_stop done');
    } catch (e) {
      print('[ENV_V1_CHASSIS] best_effort_stop failed error=$e');
    }
  }

  Future<void> _degradeToVoiceExpressionOnly(String reason) async {
    if (_degradedToVoiceExpressionOnly) return;
    _degradedToVoiceExpressionOnly = true;
    _cancelPendingObjectLookAroundTimerV1(reason: 'chassis_degraded_$reason');
    _cancelStatePollTimer();
    print('[ENV_V1_CHASSIS] degrade_to_voice_expression_only');
    _monitorStatus = '底盘不可用，降级为语音和表情陪伴';
    await _loadExpression('assets/emotion/face2/眨眼.json');
  }

  Future<void> _loadExpression(String expressionPath) async {
    try {
      _uiModule?.setAnimation(expressionPath);
      print('🎭 环境监测 V1 表情: $expressionPath');
    } catch (e) {
      print('❌ 环境监测 V1 表情切换失败: $e');
    }
  }

  Future<void> speakWithInterruptProtection(String text) async {
    try {
      if (_ttsService == null) {
        print('⚠️ TTS服务未设置，无法语音播报: $text');
        return;
      }
      if (_isTtsPlaying) {
        print('⚠️ TTS正在播放，跳过语音播报: $text');
        return;
      }
      print('🎤 环境监测 V1 语音播报: $text');
      await _ttsService!.speak(text);
    } catch (e) {
      print('❌ 环境监测 V1 语音播报失败: $e');
    }
  }

  Future<void> _cleanupEnvironmentMonitoring() async {
    print('🧹 清理环境监测 V1 状态');
    _isEnvironmentMonitoring = false;
    _cancelPendingObjectLookAroundTimerV1(reason: 'env_monitoring_stopped');
    _degradedToVoiceExpressionOnly = false;
    _ownerFoundAtV1 = null;
    _quietCompanionActiveV1 = false;
    _ownerAlignmentActiveV1 = false;
    _objectLookAroundRunningV1 = false;
    _envV1MotionCommandInFlight = false;
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
      print('[ENV_V1_CHASSIS] stop_on_cleanup_failed error=$e');
    }

    await _stopRealtimeHumanDetectionForEnvV1();
    await _disposeCameraService();
    _uiModule?.setProgramMode(ProgramMode.idle);
    print('✅ 环境监测 V1 状态清理完成');
  }

  void _cancelStatePollTimer() {
    if (_statePollTimer == null) return;
    _statePollTimer?.cancel();
    _statePollTimer = null;
    print('[ENV_V1_CLEANUP] state_poll_timer_cancelled');
  }

  void _restartStatePollTimer() {
    _cancelStatePollTimer();
    final isAnswering = _isAnsweringProvider;
    final isTtsPlaying = _isTtsPlayingProvider;
    if (isAnswering == null || isTtsPlaying == null) return;
    _statePollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _refreshExternalActivityStateV1();
      _cancelPendingObjectLookAroundIfInterruptedV1();
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
      print('[ENV_V1_STATE] poll_failed error=$e');
    }
  }

  Future<void> _disposeCameraService() async {
    final camera = _cameraService;
    if (camera == null) return;
    try {
      camera.stopRealTimeDetection();
      await camera.dispose();
      print('📷 环境监测 V1 摄像头资源已释放');
    } catch (e) {
      print('⚠️ 环境监测 V1 摄像头释放失败: $e');
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
