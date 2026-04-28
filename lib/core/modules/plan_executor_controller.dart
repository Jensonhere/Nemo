import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voicegpt/core/llm/llm_planner.dart';

enum PlanExecutionState {
  idle,
  executing,
  done,
  failed,
}

typedef PlannerStepRunner = Future<void> Function(PlannerStep step);
typedef PlannerStepTimeout = Duration Function(PlannerStep step);

/// 按顺序执行 Planner steps；每步整段包在 [timeoutForStep(step)] 内。
class PlanExecutorController extends ChangeNotifier {
  PlanExecutionState _state = PlanExecutionState.idle;
  /// 执行中：当前步序号 1..n；空闲/完成后为 0。
  int _currentStep = 0;
  int _totalSteps = 0;
  String _lastError = '';

  PlanExecutionState get state => _state;
  int get currentStep => _currentStep;
  int get totalSteps => _totalSteps;
  String get lastError => _lastError;

  bool get isExecuting => _state == PlanExecutionState.executing;

  Future<void> executeSteps(
    List<PlannerStep> steps, {
    required PlannerStepTimeout timeoutForStep,
    required PlannerStepRunner runStep,
  }) async {
    if (steps.isEmpty) {
      _state = PlanExecutionState.done;
      _currentStep = 0;
      _totalSteps = 0;
      _lastError = '';
      notifyListeners();
      print('[PlanExec] 空计划，直接 DONE');
      return;
    }

    _state = PlanExecutionState.executing;
    _totalSteps = steps.length;
    _currentStep = 0;
    _lastError = '';
    notifyListeners();
    print('[PlanExec] 状态 -> EXECUTING，共 $_totalSteps 步');

    try {
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        _currentStep = i + 1;
        notifyListeners();
        final stepTimeout = timeoutForStep(step);
        print(
          '[PlanExec] step$_currentStep/$_totalSteps 开始 '
          'action=${step.action} expression=${step.expression} reply=${step.reply} '
          'parallel_tts=${step.parallelTts ?? ""} 本步超时=${stepTimeout.inSeconds}s',
        );

        await _withStepTimeout(
          () => runStep(step),
          stepTimeout,
        );

        print('[PlanExec] step$_currentStep/$_totalSteps 完成');
      }

      _state = PlanExecutionState.done;
      _currentStep = _totalSteps;
      notifyListeners();
      print('[PlanExec] 状态 -> DONE');
    } catch (e, st) {
      _state = PlanExecutionState.failed;
      _lastError = e.toString();
      notifyListeners();
      print('[PlanExec] 状态 -> FAILED (step$_currentStep/$_totalSteps): $e\n$st');
    }
  }

  Future<void> _withStepTimeout(
    Future<void> Function() run,
    Duration perStepTimeout,
  ) async {
    await run().timeout(
      perStepTimeout,
      onTimeout: () => throw TimeoutException(
        '整步超过 ${perStepTimeout.inSeconds}s',
        perStepTimeout,
      ),
    );
  }

  void reset() {
    _state = PlanExecutionState.idle;
    _currentStep = 0;
    _totalSteps = 0;
    _lastError = '';
    notifyListeners();
    print('[PlanExec] 状态 -> IDLE');
  }
}
