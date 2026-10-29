import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'v3_agent_api_client.dart';
import 'session_guidance_audio.dart';
import 'speech_priority_coordinator.dart';

/// Explicit DI for the real Guidance Widget, never read from dataMode, event
/// JSON or a query string. No Firebase initialization or auth bypass in main().
class LocalGuidanceRuntime {
  LocalGuidanceRuntime(
      {required this.client,
      required this.auth,
      required this.captureGuard,
      required this.priority,
      required this.audio,
      required this.controls}) {
    final uri = Uri.parse(client.baseUrl);
    if (!kDebugMode ||
        uri.scheme != 'http' ||
        !{'127.0.0.1', 'localhost'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !identical(priority, audio.priority)) {
      throw StateError('Explicit loopback debug Guidance runtime required');
    }
  }
  final V3AgentApiClient client;
  final AuthSession auth;
  final bool Function() Function() captureGuard;
  final SpeechPriorityCoordinator priority;
  final SessionGuidanceAudio audio;
  final Widget Function(String sessionId, Future<void> Function() hold,
      Future<void> Function() stop) controls;
}
