// Copyright (c)  2024  Xiaomi Corporation
// Dart 3.1 兼容：无 NativeCallable.isolateLocal，使用 Pointer.fromFunction + 单槽回调。
import 'dart:ffi';

import './sherpa_onnx_bindings.dart';

int Function(int, int)? _diarizationProgressNoArg;

@pragma('vm:entry-point')
int _diarizationProgressNoArgNative(int a, int b) {
  return _diarizationProgressNoArg!(a, b);
}

Pointer<NativeFunction<SherpaOnnxOfflineSpeakerDiarizationProgressCallbackNoArgNative>>
    allocateDiarizationProgressNoArg(int Function(int, int) impl) {
  _diarizationProgressNoArg = impl;
  return Pointer.fromFunction(_diarizationProgressNoArgNative, 0);
}

void clearDiarizationProgressNoArg() {
  _diarizationProgressNoArg = null;
}

int Function(Pointer<Float> samples, int n, double p, Pointer<Void> arg)?
    _ttsProgressWithArg;

@pragma('vm:entry-point')
int _ttsProgressWithArgNative(
  Pointer<Float> samples,
  int n,
  double p,
  Pointer<Void> arg,
) {
  return _ttsProgressWithArg!(samples, n, p, arg);
}

Pointer<NativeFunction<SherpaOnnxGeneratedAudioProgressCallbackWithArgNative>>
    allocateTtsProgressWithArg(
  int Function(Pointer<Float> samples, int n, double p, Pointer<Void> arg) impl,
) {
  _ttsProgressWithArg = impl;
  return Pointer.fromFunction(_ttsProgressWithArgNative, 0);
}

void clearTtsProgressWithArg() {
  _ttsProgressWithArg = null;
}
