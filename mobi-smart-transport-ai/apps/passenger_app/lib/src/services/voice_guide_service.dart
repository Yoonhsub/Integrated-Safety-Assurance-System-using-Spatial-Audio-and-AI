class VoiceGuideService {
  const VoiceGuideService();

  Future<String> startListening() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return '목적지 입력을 기다리고 있습니다.';
  }

  Future<String> stopListening() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return '음성 입력이 종료되었습니다.';
  }

  Future<String> speakGuide(String message) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return message;
  }
}