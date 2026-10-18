import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'speech_engine.dart';
export 'speech_engine.dart';
import 'browser_speech_stub.dart'
    if (dart.library.js_interop) 'browser_speech_web.dart';
import 'tts_cancel_stub.dart'
    if (dart.library.js_interop) 'tts_cancel_web.dart';

class FlutterSpeechEngine implements SpeechEngine {
  FlutterSpeechEngine([FlutterTts? tts]) : this.platform(tts: tts);
  FlutterSpeechEngine.platform({
    FlutterTts? tts,
    bool? webPlatform,
    bool Function()? browserActive,
    void Function()? browserCancel,
  })  : _tts = tts ?? FlutterTts(),
        _web = webPlatform ?? kIsWeb,
        _browserActive = browserActive ?? browserSpeechStillActive,
        _browserCancel = browserCancel ?? cancelBrowserSpeech {
    _tts.setCancelHandler(_cancelled);
    _tts.setCompletionHandler(_finished);
    _tts.setErrorHandler((_) {
      if (_acknowledgeStop()) return;
      if (_web && _browserActive()) {
        return; // Ignore a prior Web cancel while the current voice is active.
      }
      final pending = _completion;
      _completion = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('TTS 엔진 오류'));
      }
    });
  }
  final FlutterTts _tts;
  final bool _web;
  final bool Function() _browserActive;
  final void Function() _browserCancel;
  Completer<void>? _stopAck;
  bool _unavailable = false;
  bool _acknowledgeStop() {
    final ack = _stopAck;
    if (ack == null) return false;
    if (!ack.isCompleted) ack.complete();
    return true;
  }

  void _cancelled() {
    if (_acknowledgeStop()) return;
    if (_web && _browserActive()) return;
    final pending = _completion;
    _completion = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(SpeechCancelled());
    }
  }

  Completer<void>? _completion;
  Timer? _completionTimer;
  void _finished() {
    if (_acknowledgeStop()) return;
    _completionTimer?.cancel();
    // A delayed prior cancel/end must not release a new Web safety voice.
    if (_completion != null && _web && _browserActive()) {
      final pending = _completion;
      _completionTimer = Timer(const Duration(milliseconds: 25), () {
        if (identical(_completion, pending)) _finished();
      });
      return;
    }
    final pending = _completion;
    _completion = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {
    if (_unavailable) throw StateError('TTS 종료 확인 실패: 앱을 다시 열어 주세요');
    if (requireKoreanVoice) {
      final voices = await _tts.getVoices;
      final korean = voices is List
          ? voices.where((v) =>
              v is Map &&
              (v['locale']?.toString().toLowerCase().startsWith('ko') ?? false))
          : const [];
      if (korean.isEmpty) throw StateError('한국어 TTS 음성이 없습니다');
      final voice = korean.first as Map;
      await _tts.setVoice({
        'name': voice['name'].toString(),
        'locale': voice['locale'].toString()
      });
    }
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    // Own completion/cancellation handles Web's unresolved cancel Future.
    await _tts.awaitSpeakCompletion(false);
  }

  @override
  Future<void> speak(String text) {
    final pending = _completion = Completer<void>();
    unawaited(_tts.speak(text).then((result) {
      if (result == 0 || (!_web && result == null)) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('TTS 실행 불가'));
        }
      }
    }, onError: (Object error, StackTrace stack) {
      if (!pending.isCompleted) pending.completeError(error, stack);
    }));
    return pending.future;
  }

  @override
  Future<void> stop() async {
    _completionTimer?.cancel();
    final pending = _completion;
    _completion = null; // A retiring callback must never finish a new run.
    final ack = pending == null || _web ? null : Completer<void>();
    _stopAck = ack;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(SpeechCancelled());
    }
    try {
      if (_web) _browserCancel();
      await _tts.stop().timeout(const Duration(seconds: 2));
      if (ack != null) {
        // Android stop's method reply precedes its onStop callback.
        await ack.future.timeout(const Duration(seconds: 2));
      }
      if (_web && _browserActive()) {
        final until = Stopwatch()..start();
        while (_browserActive()) {
          if (until.elapsed >= const Duration(seconds: 2)) {
            throw StateError('Web 음성 종료를 확인할 수 없습니다');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    } catch (_) {
      _unavailable = true; // Unconfirmed cancellation cannot authorize reuse.
      rethrow;
    } finally {
      _stopAck = null;
    }
  }
}

class PriorityLease {
  PriorityLease._(this._release);
  final VoidCallback _release;
  bool active = true;
  void release() {
    if (active) {
      active = false;
      _release();
    }
  }
}

class _Run {
  _Run(this.owner, this.priority, this.done);
  final Object owner;
  final bool priority;
  final Future<void> done;
  final cancel = Completer<void>();
}

/// All native TTS control commands serialize, but completion never locks stop.
/// Priority leases cover both TTS and existing generated/script audio playback.
class SpeechPriorityCoordinator extends ChangeNotifier {
  SpeechPriorityCoordinator(this.engine);
  final SpeechEngine engine;
  Future<void> _tail = Future.value();
  final Set<Object> _leases = {};
  _Run? _run;
  bool _engineAvailable = true;
  final Object _uncertainOutput = Object();
  bool get priorityActive => _leases.isNotEmpty;
  Future<T> _command<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> _stopRun() async {
    final run = _run;
    _run = null;
    if (run == null) return;
    if (!run.cancel.isCompleted) run.cancel.complete();
    try {
      await engine.stop().timeout(const Duration(seconds: 3));
    } catch (_) {
      _engineAvailable = false;
      // Unknown native output keeps Observation blocked until app reload.
      _leases.add(_uncertainOutput);
      notifyListeners();
      rethrow;
    }
  }

  /// Reserve priority synchronously: independent warning outputs never wait
  /// for a speech engine that is preparing, stopping or failing.
  PriorityLease claimPriority() {
    final token = Object();
    _leases.add(token);
    notifyListeners();
    unawaited(_command(() async {
      if (_run?.priority == false) await _stopRun();
    }).catchError((Object _) {}));
    return PriorityLease._(() {
      _leases.remove(token);
      notifyListeners();
    });
  }

  Future<PriorityLease> acquirePriority() async {
    final lease = claimPriority();
    await _command(() async {});
    return lease;
  }

  Future<bool> speakObservation(
          Object owner, String text, bool Function() valid) =>
      _speak(owner, text, false, valid);
  Future<bool> speakPriority(
          Object owner, String text, bool Function() valid) =>
      _speak(owner, text, true, valid);
  Future<bool> _speak(
      Object owner, String text, bool priority, bool Function() valid) async {
    final run = await _command<_Run?>(() async {
      bool allowed() => valid() && (priority || !priorityActive);
      if (!allowed()) return null;
      if (!_engineAvailable) throw StateError('음성 엔진 종료를 확인할 수 없습니다');
      await engine
          .prepare(requireKoreanVoice: !priority)
          .timeout(const Duration(seconds: 3));
      if (!allowed()) return null;
      await _stopRun();
      if (!allowed()) return null;
      final next = _Run(owner, priority, engine.speak(text));
      // Observe errors immediately, even if cancel wins the race.
      unawaited(
          next.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      _run = next;
      return next;
    });
    if (run == null) return false;
    try {
      await Future.any([run.done, run.cancel.future])
          .timeout(const Duration(seconds: 30));
      return !run.cancel.isCompleted;
    } finally {
      await _command(() async {
        if (identical(_run, run)) await _stopRun();
      });
    }
  }

  Future<void> stopObservation(Object owner) => _command(() async {
        if (_run?.priority == false && identical(_run?.owner, owner)) {
          await _stopRun();
        }
      });
  Future<void> stopPriority(Object owner) => _command(() async {
        if (_run?.priority == true && identical(_run?.owner, owner)) {
          await _stopRun();
        }
      });
}

final sharedSpeechPriority = SpeechPriorityCoordinator(
    createBrowserSpeechEngine() ?? FlutterSpeechEngine());
