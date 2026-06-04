import 'dart:async';

import 'package:flutter/foundation.dart';

enum Speaker { user, agent, thinking }

/// 한 발화(또는 진행 중 partial) 자막 항목.
@immutable
class LiveCaptionLine {
  const LiveCaptionLine({
    required this.speaker,
    required this.text,
    required this.isFinal,
    required this.createdAt,
  });

  final Speaker speaker;
  final String text;
  final bool isFinal;
  final DateTime createdAt;

  LiveCaptionLine copyWith({String? text, bool? isFinal}) => LiveCaptionLine(
        speaker: speaker,
        text: text ?? this.text,
        isFinal: isFinal ?? this.isFinal,
        createdAt: createdAt,
      );
}

/// Live 음성 대화의 임시 자막과 세션 로그를 관리한다.
///
/// - [visibleLines]: 화면에 표시할 임시 자막(파셜 포함).
/// - [sessionLog]: 확정(final)된 발화 누적. X 종료/길찾기 전환 시 앱 대화 로그로 옮긴다.
class LiveCaptionController extends ChangeNotifier {
  final List<LiveCaptionLine> _temporaryLines = [];
  final List<LiveCaptionLine> _sessionLog = [];
  Timer? _streamTimer;

  List<LiveCaptionLine> get visibleLines => List.unmodifiable(_temporaryLines);
  List<LiveCaptionLine> get sessionLog => List.unmodifiable(_sessionLog);

  bool get hasContent => _temporaryLines.isNotEmpty || _sessionLog.isNotEmpty;

  /// 진행 중(partial) 자막. 같은 화자의 마지막 미확정 줄을 교체한다.
  void updatePartial({required Speaker speaker, required String text}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_temporaryLines.isNotEmpty &&
        _temporaryLines.last.speaker == speaker &&
        !_temporaryLines.last.isFinal) {
      _temporaryLines[_temporaryLines.length - 1] =
          _temporaryLines.last.copyWith(text: trimmed);
    } else {
      _temporaryLines.add(LiveCaptionLine(
        speaker: speaker,
        text: trimmed,
        isFinal: false,
        createdAt: DateTime.now(),
      ));
    }
    notifyListeners();
  }

  /// 처리 중 '생각' 한 줄을 회색으로 추가한다(세션 로그에는 남기지 않는 임시 줄).
  void addThought(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _temporaryLines.add(LiveCaptionLine(
      speaker: Speaker.thinking,
      text: t,
      isFinal: true,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  /// 화면의 '생각' 줄만 제거한다(답변이 시작될 때 호출).
  void clearThoughts() {
    _temporaryLines.removeWhere((line) => line.speaker == Speaker.thinking);
    notifyListeners();
  }

  // 타이핑 노출 속도(말하는 속도에 맞춤). 한 글자당 대략 이 시간만큼 걸려 노출된다.
  // TTS(한국어) 발화 속도와 비슷하게 잡아, 긴 답변이 한 번에 쏟아지지 않고
  // 음성과 함께 또박또박 타이핑되도록 한다.
  static const double _msPerChar = 120.0;

  /// 에이전트 응답을 한 글자씩 타이핑되듯 점진적으로 노출한다(말하는 속도에 동기화).
  ///
  /// 경과 시간 기준으로 노출 글자 수를 계산해, 답변이 길어도(5줄 이상이어도)
  /// 한 번에 생성되지 않고 발화 속도에 맞춰 또박또박 채워진다.
  void streamAgent(String text) {
    clearThoughts();
    _streamTimer?.cancel();
    final full = text.trim();
    if (full.isEmpty) return;
    final line = LiveCaptionLine(
      speaker: Speaker.agent,
      text: '',
      isFinal: false,
      createdAt: DateTime.now(),
    );
    _temporaryLines.add(line);
    final index = _temporaryLines.length - 1;
    final startedAt = DateTime.now();
    notifyListeners();
    // 40ms 주기로 다시 그리되, 실제 노출 글자 수는 경과 시간/_msPerChar 로 정해
    // 프레임이 끊겨도 일정한 '말하는 속도'를 유지한다.
    _streamTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (index >= _temporaryLines.length) {
        timer.cancel();
        return;
      }
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      final shown = (elapsedMs / _msPerChar).floor().clamp(0, full.length);
      final partial = full.substring(0, shown);
      final done = shown >= full.length;
      _temporaryLines[index] = _temporaryLines[index].copyWith(
        text: partial,
        isFinal: done,
      );
      notifyListeners();
      if (done) {
        timer.cancel();
        _streamTimer = null;
        _sessionLog.add(_temporaryLines[index]);
      }
    });
  }

  /// 발화 확정. 같은 화자의 미확정 줄이 있으면 그것을 확정하고, 없으면 새로 추가한다.
  void commitFinal({required Speaker speaker, required String text}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    LiveCaptionLine line;
    if (_temporaryLines.isNotEmpty &&
        _temporaryLines.last.speaker == speaker &&
        !_temporaryLines.last.isFinal) {
      line = _temporaryLines.last.copyWith(text: trimmed, isFinal: true);
      _temporaryLines[_temporaryLines.length - 1] = line;
    } else {
      line = LiveCaptionLine(
        speaker: speaker,
        text: trimmed,
        isFinal: true,
        createdAt: DateTime.now(),
      );
      _temporaryLines.add(line);
    }
    _sessionLog.add(line);
    notifyListeners();
  }

  /// 남은 partial을 final로 정리해 세션 로그에 보존한다(X 종료 직전 호출).
  void flushTemporaryToSessionLog() {
    _streamTimer?.cancel();
    _streamTimer = null;
    if (_temporaryLines.isNotEmpty && !_temporaryLines.last.isFinal) {
      final pending = _temporaryLines.last.copyWith(isFinal: true);
      _temporaryLines[_temporaryLines.length - 1] = pending;
      _sessionLog.add(pending);
    }
    notifyListeners();
  }

  /// 화면의 임시 자막만 제거한다(세션 로그는 유지).
  void clearTemporary() {
    _streamTimer?.cancel();
    _streamTimer = null;
    _temporaryLines.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    super.dispose();
  }
}
