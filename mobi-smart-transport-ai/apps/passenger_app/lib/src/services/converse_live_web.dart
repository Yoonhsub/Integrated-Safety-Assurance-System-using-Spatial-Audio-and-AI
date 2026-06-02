import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/v3_guidance_models.dart';
import 'converse_event.dart';

/// `/agent/converse/live` WebSocket을 열어 thought/final 이벤트를 스트림으로 돌려준다.
Stream<ConverseEvent> openConverseLive({
  required String baseUrl,
  required Map<String, Object?> request,
}) {
  final controller = StreamController<ConverseEvent>();
  final socket = web.WebSocket(_wsUri(baseUrl));
  Timer? guard;

  void closeAll() {
    guard?.cancel();
    try {
      socket.close();
    } catch (_) {}
    if (!controller.isClosed) controller.close();
  }

  // 무응답으로 영원히 매달리지 않도록 안전 가드.
  guard = Timer(const Duration(seconds: 60), () {
    if (!controller.isClosed) {
      controller.addError(StateError('대화 응답 시간이 초과됐어.'));
    }
    closeAll();
  });

  socket.onopen = ((web.Event _) {
    socket.send(jsonEncode(request).toJS);
  }).toJS;

  socket.onmessage = ((web.MessageEvent event) {
    final data = event.data?.dartify();
    if (data is! String) return;
    final dynamic decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'thought':
        final text = decoded['text'];
        if (text is String && text.trim().isNotEmpty && !controller.isClosed) {
          controller.add(ConverseThought(text));
        }
        break;
      case 'final':
        final resp = decoded['response'];
        if (resp is Map && !controller.isClosed) {
          controller.add(
            ConverseFinal(
              V3AgentResponse.fromJson(Map<String, dynamic>.from(resp)),
            ),
          );
        }
        closeAll();
        break;
      case 'error':
        if (!controller.isClosed) {
          controller.addError(
            StateError(decoded['message']?.toString() ?? '대화 처리에 실패했어.'),
          );
        }
        closeAll();
        break;
    }
  }).toJS;

  socket.onerror = ((web.Event _) {
    if (!controller.isClosed) {
      controller.addError(StateError('대화 연결에 실패했어.'));
    }
    closeAll();
  }).toJS;

  socket.onclose = ((web.CloseEvent _) {
    closeAll();
  }).toJS;

  controller.onCancel = closeAll;
  return controller.stream;
}

String _wsUri(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final path = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return uri
      .replace(
        scheme: scheme,
        path: '$path/agent/converse/live',
        query: null,
        fragment: null,
      )
      .toString();
}
