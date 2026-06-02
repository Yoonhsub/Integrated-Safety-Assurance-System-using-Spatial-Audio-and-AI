import 'converse_event.dart';

/// 비-웹: 스트리밍 미지원. 호출자가 일반 converse로 폴백한다.
Stream<ConverseEvent> openConverseLive({
  required String baseUrl,
  required Map<String, Object?> request,
}) {
  throw UnsupportedError('converseLive streaming is only available on web.');
}
