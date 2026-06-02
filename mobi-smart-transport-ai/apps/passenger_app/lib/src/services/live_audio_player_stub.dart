class LiveAudioPlaybackException implements Exception {
  const LiveAudioPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LiveAudioPlayer {
  Future<void> prepare() async {}

  Future<void> play({
    required String baseUrl,
    required String text,
    void Function()? onFirstAudio,
  }) async {
    throw const LiveAudioPlaybackException(
      'Gemini Live API 스트리밍 재생은 웹에서만 지원돼.',
    );
  }

  Future<void> stop() async {}

  Future<void> dispose() async {}
}
