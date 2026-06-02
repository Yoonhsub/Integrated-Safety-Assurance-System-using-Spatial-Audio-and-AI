/// Live 음성 대화의 턴 상태.
enum VoiceTurnState {
  /// 진입 전/종료 후. 마이크·재생·오로라 없음(또는 매우 약한 glow).
  idle,

  /// 사용자가 말할 수 있는 상태. 마이크 RMS로 파란 오로라가 반응한다.
  listening,

  /// 사용자가 말을 끝내(3초 무음) AI 응답을 기다리는 상태. 보라색 fake pulse.
  thinking,

  /// AI가 음성으로 응답하는 상태. 출력 RMS로 주황 오로라가 반응한다.
  speaking,
}

extension VoiceTurnStateX on VoiceTurnState {
  /// 셰이더 uMode 값(0 idle / 1 listening / 2 thinking / 3 speaking).
  double get shaderMode => switch (this) {
        VoiceTurnState.idle => 0.0,
        VoiceTurnState.listening => 1.0,
        VoiceTurnState.thinking => 2.0,
        VoiceTurnState.speaking => 3.0,
      };

  String get statusLabel => switch (this) {
        VoiceTurnState.idle => '대기 중',
        VoiceTurnState.listening => '듣는 중',
        VoiceTurnState.thinking => '생각 중',
        VoiceTurnState.speaking => '말하는 중',
      };
}
