import '../models/v3_guidance_models.dart';

/// `/agent/converse/live` 스트림 이벤트.
sealed class ConverseEvent {
  const ConverseEvent();
}

/// 처리 단계 '생각' 한 줄(회색 표시용).
class ConverseThought extends ConverseEvent {
  const ConverseThought(this.text);
  final String text;
}

/// 최종 응답.
class ConverseFinal extends ConverseEvent {
  const ConverseFinal(this.response);
  final V3AgentResponse response;
}
