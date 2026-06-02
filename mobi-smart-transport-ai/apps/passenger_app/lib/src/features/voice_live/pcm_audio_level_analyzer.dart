import 'dart:math' as math;
import 'dart:typed_data';

/// PCM16 RMS 계산과 진폭 스무딩 유틸.
///
/// 실제 PCM 바이트가 Dart로 들어오는 경로(네이티브 등)에서 RMS를 직접 계산할 때
/// 사용한다. 웹에서는 Web Audio AnalyserNode([VoiceAudioLevel])가 RMS를 주므로
/// [smoothLevel]만 사용한다.
class PcmAudioLevelAnalyzer {
  /// 16-bit little-endian PCM에서 RMS(0.0~1.0)를 계산한다.
  double calculatePcm16Rms(Uint8List pcmBytes) {
    if (pcmBytes.length < 2) return 0.0;
    final byteData = ByteData.sublistView(pcmBytes);
    final samples = pcmBytes.length ~/ 2;
    double sum = 0.0;
    for (int i = 0; i < samples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      final normalized = sample / 32768.0;
      sum += normalized * normalized;
    }
    final rms = math.sqrt(sum / samples);
    return (rms * 4.0).clamp(0.0, 1.0);
  }

  /// 상승은 빠르게(attack), 하락은 천천히(release) 스무딩한다.
  double smoothLevel({
    required double current,
    required double target,
    double attack = 0.35,
    double release = 0.08,
  }) {
    final factor = target > current ? attack : release;
    return current + (target - current) * factor;
  }
}
