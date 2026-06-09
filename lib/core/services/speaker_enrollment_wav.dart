import 'dart:typed_data';

/// 将 16kHz 单声道 float PCM 写入标准 WAV 字节。
class SpeakerEnrollmentWav {
  SpeakerEnrollmentWav._();

  static const int sampleRate = 16000;

  static Uint8List encodeFloat32Mono(Float32List samples) {
    final dataSize = samples.length * 2;
    final out = Uint8List(44 + dataSize);
    final bd = ByteData.sublistView(out);

    void writeStr(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out[offset + i] = s.codeUnitAt(i);
      }
    }

    writeStr(0, 'RIFF');
    bd.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    bd.setUint32(40, dataSize, Endian.little);

    var o = 44;
    for (var i = 0; i < samples.length; i++) {
      var v = (samples[i] * 32767).round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      bd.setInt16(o, v, Endian.little);
      o += 2;
    }
    return out;
  }
}
