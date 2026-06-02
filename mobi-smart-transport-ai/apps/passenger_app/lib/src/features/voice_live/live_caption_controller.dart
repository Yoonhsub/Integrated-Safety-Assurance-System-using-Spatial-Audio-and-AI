import 'dart:async';

import 'package:flutter/foundation.dart';

enum Speaker { user, agent }

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

  /// 에이전트 응답을 한 글자씩 타이핑되듯 점진적으로 노출한다(GPT 스타일 스트리밍).
  void streamAgent(String text) {
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
    var shown = 0;
    notifyListeners();
    _streamTimer = Timer.periodic(const Duration(milliseconds: 32), (timer) {
      if (index >= _temporaryLines.length) {
        timer.cancel();
        return;
      }
      shown = (shown + 2).clamp(0, full.length);
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
