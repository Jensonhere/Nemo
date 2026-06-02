import 'dart:async';

import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart'
    show MyBluetoothService;
import 'package:voicegpt/core/services/camera_service.dart';
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
  static const double _reliableHumanConfidence = 0.50;
  static const double _reliableHumanMinAreaRatio = 0.01;
  static const Duration _settleDelay = Duration(milliseconds: 220);
  static const Duration _shortSettleDelay = Duration(milliseconds: 160);
  static const Duration _quietCompanionInterval = Duration(seconds: 45);

  MyBluetoothService? _bluetoothService;
  VoiceTtsService? _ttsService;
  UIAnimationModule? _uiModule;
  CameraService? _cameraService;

  Timer? _statePollTimer;
  Timer? _quietCompanionTimer;

  bool _isEnvironmentMonitoring = false;
  bool _isAnswering = false;
  bool _isTtsPlaying = false;
  bool _degradedToVoiceExpressionOnly = false;
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

    _restartStatePollTimer();
    _isEnvironmentMonitoring = true;
    _degradedToVoiceExpressionOnly = false;
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

    try {
      await _ensureCameraService();
      if (!_isEnvironmentMonitoring) return;

      await _loadExpression('assets/emotion/face2/观察/01/观察 01.json');
      await speakWithInterruptProtection('主人，你在这里吗？');

      final found = await _runSearchOwnerV1();
      if (!_isEnvironmentMonitoring) return;

      final tracked = found == null ? null : await _runTrackOwnerV1(found);
      if (!_isEnvironmentMonitoring) return;

      final confirmed = tracked == null
          ? SnapshotAlignResult.noTarget()
          : await _runConfirmOwnerBySnapshotV1(tracked);
      if (!_isEnvironmentMonitoring) return;

      final finalResult = await _runFinalFaceCenteringV1(confirmed);
      if (!_isEnvironmentMonitoring) return;

      await _runInteractOwnerV1(finalResult);
      await _disposeCameraService();
      await _enterQuietCompanionModeV1();
    } catch (e, st) {
      _monitorStatus = '环境监测 V1 异常: $e';
      print('[ENV_V1] error=$e\n$st');
      await _degradeToVoiceExpressionOnly('exception');
      await _disposeCameraService();
      await _enterQuietCompanionModeV1();
    }
  }

  Future<HumanObservation?> _runSearchOwnerV1() async {
    print('[ENV_V1_SEARCH] start');
    _monitorStatus = 'SEARCH: 原地找人';

    final initial = await _detectHumanObservationSafe();
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
      _TurnStep('左转', 15),
      _TurnStep('右转', 30),
      _TurnStep('右转', 30),
      _TurnStep('左转', 30),
      _TurnStep('左转', 15),
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

      final candidate = await _detectHumanObservationSafe();
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

  Future<HumanObservation> _runTrackOwnerV1(HumanObservation initial) async {
    final dx = initial.centerX - 0.5;
    final absDx = dx.abs();
    print(
      '[ENV_V1_TRACK] start cx=${_f(initial.centerX)} dx=${_f(dx)}',
    );
    _monitorStatus = 'TRACK: 人体粗回正';

    int angle = 0;
    if (absDx <= 0.10) {
      angle = 0;
    } else if (absDx <= 0.20) {
      angle = 5;
    } else if (absDx <= 0.35) {
      angle = 8;
    } else {
      angle = 12;
    }

    final direction = dx > 0 ? '右转' : '左转';
    print(
      '[ENV_V1_TRACK] decision angle=$angle direction=$direction',
    );

    if (angle > 0) {
      final moved = await _safeSendCommandV1(direction, angle);
      if (!moved) {
        print('[ENV_V1_TRACK] fallback_old_observation');
        return initial;
      }
      await _safeSendCommandV1('停止', 0);
      await Future<void>.delayed(_settleDelay);
    }

    final fresh = await _detectHumanObservationSafe();
    print(
      '[ENV_V1_TRACK] fresh_observation hasHuman=${fresh.hasHuman} '
      'conf=${_f(fresh.confidence)} area=${_f(fresh.areaRatio)} '
      'cx=${_f(fresh.centerX)}',
    );

    if (!_isReliableHumanObservation(fresh)) {
      print('[ENV_V1_TRACK] fallback_old_observation');
      print('[ENV_V1_TRACK] done');
      return initial;
    }

    print('[ENV_V1_TRACK] done');
    return fresh;
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
    final dx = result.centerX - 0.5;
    final absDx = dx.abs();
    final target = result.targetType.name;
    print(
      '[ENV_V1_FINAL_CENTER] start target=$target '
      'cx=${_f(result.centerX)} dx=${_f(dx)}',
    );
    _monitorStatus = 'FINAL_CENTER: snapshot 居中确认';

    if (result.targetType == SnapshotTargetType.none) {
      print(
          '[ENV_V1_FINAL_CENTER] decision action=no_target direction=none angle=0');
      print('[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.noTarget}');
      return result.copyWith(
        canProceed: false,
        finalAlignmentStatus: SnapshotAlignStatus.noTarget,
      );
    }

    if (result.targetType == SnapshotTargetType.person) {
      final status = absDx <= 0.16
          ? SnapshotAlignStatus.verifiedPersonAcceptable
          : SnapshotAlignStatus.stillOffcenter;
      print(
        '[ENV_V1_FINAL_CENTER] decision action=person_only '
        'direction=none angle=0',
      );
      print('[ENV_V1_FINAL_CENTER] result=$status');
      return result.copyWith(finalAlignmentStatus: status);
    }

    if (absDx <= 0.08) {
      print(
        '[ENV_V1_FINAL_CENTER] decision action=centered '
        'direction=none angle=0',
      );
      print(
        '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.verifiedFaceCentered}',
      );
      return result.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.verifiedFaceCentered,
      );
    }

    if (absDx > 0.28) {
      print(
        '[ENV_V1_FINAL_CENTER] decision action=too_far '
        'direction=none angle=0',
      );
      print(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.stillOffcenter}');
      return result.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }

    final angle = absDx <= 0.12
        ? 3
        : absDx <= 0.18
            ? 5
            : 7;
    final direction = dx > 0 ? '右转' : '左转';
    print(
      '[ENV_V1_FINAL_CENTER] decision action=nudge '
      'direction=$direction angle=$angle',
    );

    final moved = await _safeSendCommandV1(direction, angle);
    if (!moved) {
      print(
          '[ENV_V1_FINAL_CENTER] result=${SnapshotAlignStatus.stillOffcenter}');
      return result.copyWith(
        finalAlignmentStatus: SnapshotAlignStatus.stillOffcenter,
      );
    }
    await _safeSendCommandV1('停止', 0);
    await Future<void>.delayed(_settleDelay);

    final verified = await _captureSnapshotAlignResultV1(
      result.humanObservation,
    );
    final updated = _classifyAfterNudge(verified);
    print(
      '[ENV_V1_FINAL_CENTER] verify_after_nudge '
      'hasFace=${verified.faceObservation?.hasFace ?? false} '
      'faceCx=${_f(verified.faceObservation?.centerX ?? 0.5)} '
      'hasHuman=${verified.humanObservation?.hasHuman ?? false} '
      'personCx=${_f(verified.humanObservation?.centerX ?? 0.5)}',
    );
    print('[ENV_V1_FINAL_CENTER] result=$updated');
    return verified.copyWith(finalAlignmentStatus: updated);
  }

  String _classifyAfterNudge(SnapshotAlignResult verified) {
    if (verified.targetType == SnapshotTargetType.face) {
      final faceDx =
          (verified.faceObservation?.centerX ?? verified.centerX) - 0.5;
      if (faceDx.abs() <= 0.08) {
        return SnapshotAlignStatus.verifiedFaceCentered;
      }
      if (faceDx.abs() <= 0.16) {
        return SnapshotAlignStatus.verifiedFaceAcceptable;
      }
      return SnapshotAlignStatus.stillOffcenter;
    }

    final person = verified.humanObservation;
    if (person != null && _isReliableHumanObservation(person)) {
      final personDx = person.centerX - 0.5;
      if (personDx.abs() <= 0.16) {
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
    final greetingLine = _greetingLineForStatus(result.finalAlignmentStatus);

    print(
      '[ENV_V1_INTERACT] status=${result.finalAlignmentStatus} '
      'greetingLine=$greetingLine',
    );
    await _loadExpression(
      isStrictlyCentered
          ? 'assets/emotion/face2/可爱/02/可爱 02.json'
          : 'assets/emotion/face2/观察/02/观察 02.json',
    );
    await speakWithInterruptProtection(greetingLine);

    if (!_isEnvironmentMonitoring) return;
    await speakWithInterruptProtection('要不要和我说句话？');
    await Future<void>.delayed(const Duration(seconds: 6));
    print('[ENV_V1_INTERACT] enter_quiet_companion reason=no_reply');
  }

  String _greetingLineForStatus(String status) {
    switch (status) {
      case SnapshotAlignStatus.verifiedFaceCentered:
        return '找到你啦，主人！';
      case SnapshotAlignStatus.verifiedFaceAcceptable:
      case SnapshotAlignStatus.verifiedPersonAcceptable:
      case SnapshotAlignStatus.stillOffcenter:
        return '我看到你啦，主人。';
      case SnapshotAlignStatus.targetLostAfterNudge:
        return '我刚才好像看到你啦，主人，我先乖乖待着。';
      case SnapshotAlignStatus.noTarget:
      default:
        return '我没看太清，主人，我先在这里陪你。';
    }
  }

  Future<void> _enterQuietCompanionModeV1() async {
    if (!_isEnvironmentMonitoring) return;
    _monitorStatus = 'QUIET_COMPANION: 安静陪伴中';
    await _loadExpression('assets/emotion/face2/眨眼.json');
    print('[ENV_V1_QUIET] enter mode=voice_expression_only_no_movement');

    _quietCompanionTimer?.cancel();
    _quietCompanionTimer = Timer.periodic(_quietCompanionInterval, (_) {
      if (!_isEnvironmentMonitoring || _isAnswering || _isTtsPlaying) {
        return;
      }
      unawaited(_performPetMicroActionV1());
    });
  }

  Future<void> _performPetMicroActionV1() async {
    print('[ENV_V1_QUIET] micro_action action=blink_expression_only');
    await _loadExpression('assets/emotion/face2/眨眼.json');
  }

  Future<void> _ensureCameraService() async {
    _cameraService ??= CameraService();
    await _cameraService!.initialize();
  }

  Future<HumanObservation> _detectHumanObservationSafe() async {
    try {
      final camera = _cameraService;
      if (camera == null) {
        return const HumanObservation(hasHuman: false);
      }
      return await camera.detectHumanObservation();
    } catch (e) {
      print('[ENV_V1_SEARCH] human_detection_failed error=$e');
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

  Future<bool> _safeSendCommandV1(String command, int value) async {
    final service = _bluetoothService;
    if (service == null || !service.isConnected) {
      print('[ENV_V1_CHASSIS] unavailable reason=disconnected');
      await _degradeToVoiceExpressionOnly('disconnected');
      return false;
    }

    try {
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
    _degradedToVoiceExpressionOnly = false;
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
      _isAnswering = isAnswering();
      _isTtsPlaying = isTtsPlaying();
    });
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
