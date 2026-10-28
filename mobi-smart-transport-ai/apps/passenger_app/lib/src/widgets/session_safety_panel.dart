import 'package:flutter/material.dart';
import '../services/session_safety_receiver.dart';
import '../services/speech_priority_coordinator.dart';

class SessionSafetyPanel extends StatefulWidget {
  const SessionSafetyPanel(
      {super.key,
      required this.sessionId,
      required this.ownerUid,
      required this.captureGuard,
      required this.fetch,
      required this.authChanges,
      this.priority,
      this.lifecycle,
      this.openTransport,
      this.allowSynthetic = false});
  final String sessionId, ownerUid;
  final bool Function() Function() captureGuard;
  final SafetyFetch fetch;
  final SessionSafetyLifecycle? lifecycle;
  final SafetyPollingTransport Function()? openTransport;
  final Stream<Object?> authChanges;
  final SpeechPriorityCoordinator? priority;
  final bool allowSynthetic;
  @override
  State<SessionSafetyPanel> createState() => _SessionSafetyPanelState();
}

class _SessionSafetyPanelState extends State<SessionSafetyPanel> {
  late final SessionSafetyReceiver _receiver;
  SafetyPollingTransport? _transport;
  @override
  void initState() {
    super.initState();
    final guard = widget.captureGuard();
    final revision = widget.lifecycle?.revision;
    _transport = widget.openTransport?.call();
    _receiver = SessionSafetyReceiver(
        sessionId: widget.sessionId,
        ownerUid: widget.ownerUid,
        isCurrent: () =>
            guard() &&
            (widget.lifecycle == null ||
                (widget.lifecycle!.active &&
                    widget.lifecycle!.revision == revision)),
        fetch: _transport?.fetch ?? widget.fetch,
        priority: widget.priority ?? sharedSpeechPriority,
        authChanges: widget.authChanges,
        allowSynthetic: widget.allowSynthetic,
        cancelFetch: _transport?.close,
        trace: widget.lifecycle?.trace);
    widget.lifecycle?.attach(_receiver);
  }

  @override
  void dispose() {
    widget.lifecycle?.detach(_receiver);
    _receiver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: _receiver,
      builder: (context, _) => Card(
              child: Column(children: [
            Text(_receiver.status),
            if (_receiver.message != null) Text(_receiver.message!),
            SwitchListTile(
                title: const Text('세션 안전 정보 음성'),
                subtitle: const Text('방향·거리·승차 가능 여부를 판단하지 않습니다'),
                value: _receiver.enabled,
                onChanged: _receiver.active ? _receiver.setEnabled : null),
          ])));
}

/// Owns reset sequencing used by the normal page and by Widget/Runtime tests.
/// A reset never resurrects the previous receiver, including on failure.
class SessionSafetyLifecycle extends ChangeNotifier {
  SessionSafetyLifecycle({this.trace});
  final void Function(String)? trace;
  bool active = true, resetting = false, failed = false, _disposed = false;
  int revision = 0;
  SessionSafetyReceiver? _receiver;
  void attach(SessionSafetyReceiver receiver) {
    if (_disposed || !active) {
      receiver.close();
      return;
    }
    _receiver?.close();
    _receiver = receiver;
    trace?.call('new_receiver_bound');
  }

  void detach(SessionSafetyReceiver receiver) {
    if (identical(_receiver, receiver)) _receiver = null;
  }

  Future<bool> reset(
      {required Future<void> Function() request,
      required bool Function() isCurrent}) async {
    if (_disposed || resetting || !isCurrent()) return false;
    resetting = true;
    active = false;
    failed = false;
    final ticket = ++revision;
    _receiver?.close();
    _receiver = null;
    trace?.call('old_receiver_invalidated');
    notifyListeners();
    try {
      trace?.call('reset_request');
      await request();
      if (_disposed || ticket != revision) return false;
      resetting = false;
      if (!isCurrent()) {
        failed = true;
        notifyListeners();
        return false;
      }
      trace?.call('server_reset_success');
      active = true;
      notifyListeners();
      return true;
    } catch (_) {
      if (!_disposed && ticket == revision) {
        resetting = false;
        failed = true;
        notifyListeners();
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    active = false;
    revision++;
    // Receiver close is normally done by child disposal; invalidate its guard
    // synchronously and close only the transport/audio without rebuilding UI.
    _receiver?.close(notify: false);
    _receiver = null;
    super.dispose();
  }
}

class SessionSafetyHost extends StatelessWidget {
  const SessionSafetyHost(
      {super.key,
      required this.lifecycle,
      required this.sessionId,
      required this.ownerUid,
      required this.captureGuard,
      required this.fetch,
      required this.authChanges,
      this.priority,
      this.allowSynthetic = false,
      this.openTransport});
  final SessionSafetyLifecycle lifecycle;
  final String sessionId, ownerUid;
  final bool Function() Function() captureGuard;
  final SafetyFetch fetch;
  final Stream<Object?> authChanges;
  final SpeechPriorityCoordinator? priority;
  final bool allowSynthetic;
  final SafetyPollingTransport Function()? openTransport;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: lifecycle,
      builder: (context, _) {
        if (lifecycle.resetting) return const Text('RESETTING · 세션 초기화 중');
        if (!lifecycle.active) {
          return const Text('세션 초기화 실패 · 초기화 버튼으로 다시 시도하세요');
        }
        return SessionSafetyPanel(
            key: ValueKey(lifecycle.revision),
            lifecycle: lifecycle,
            sessionId: sessionId,
            ownerUid: ownerUid,
            captureGuard: captureGuard,
            fetch: fetch,
            authChanges: authChanges,
            priority: priority,
            allowSynthetic: allowSynthetic,
            openTransport: openTransport);
      });
}
