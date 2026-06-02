/// 비-웹 플랫폼용 스텁. 실제 마이크/출력 진폭은 웹(Web Audio)에서만 제공한다.
class VoiceAudioLevel {
  Future<bool> startMic() async => false;

  double micLevel() => 0.0;

  double outputLevel() => 0.0;

  double remainingPlaybackMs() => 0.0;

  Future<void> stopMic() async {}
}
