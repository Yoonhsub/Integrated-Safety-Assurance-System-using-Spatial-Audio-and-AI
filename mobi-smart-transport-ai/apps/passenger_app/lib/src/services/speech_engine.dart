abstract interface class SpeechEngine {
  Future<void> prepare({required bool requireKoreanVoice});
  Future<void> speak(String text);
  Future<void> stop();
}

/// Explicit retirement, never a reason to retry/fall back to another voice.
class SpeechCancelled extends StateError {
  SpeechCancelled() : super('음성 요청이 취소되었습니다');
}
