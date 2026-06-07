import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'live_caption_controller.dart';
import 'live_speech.dart';
import 'pcm_audio_level_analyzer.dart';
import 'voice_audio_level.dart';
import 'voice_turn_state.dart';

/// 한 사용자 발화에 대한 에이전트 처리 결과.
class LiveProcessResult {
  const LiveProcessResult({
    required this.spokenText,
    this.navigateNow = false,
    this.endSession = false,
  });

  final String spokenText;
  final bool navigateNow;
  final bool endSession;
}

// onThought는 처리 중 단계별 '생각' 한 줄을 받는다(회색 자막 스트리밍용).
typedef LiveUtteranceProcessor = Future<LiveProcessResult> Function(
  String utterance, {
  void Function(String thought)? onThought,
});
// onStart는 실제 오디오 첫 청크가 도착(=소리 시작)할 때 호출된다(자막 동기화용).
typedef LiveSpeak = Future<void> Function(String text, {VoidCallback? onStart});

/// LiveVoicePage의 상태 머신·turn-taking·오디오 레벨·자막을 관리한다.
///
/// 음성 인식은 [LiveSpeechRecognizer]를 쓴다. 첫 진입 때만 자동으로 듣기를 시작하고,
/// 이후 사용자 발화는 마이크 버튼 탭으로만 열린다. 웹은 세션을 유지하되 비듣기
/// 상태에서는 STT 입력을 일시 정지해 에이전트 음성이나 주변 소리가 전달되지 않게 한다.
class LiveVoiceController {
  LiveVoiceController({
    required this.captions,
    required this.processor,
    required this.speak,
    required this.stopAudio,
    required this.onNavigate,
    required this.onEnd,
    LiveSpeechRecognizer? recognizer,
    VoiceAudioLevel? audioLevel,
  })  : _recognizer = recognizer ?? LiveSpeechRecognizer(),
        _audioLevel = audioLevel ?? VoiceAudioLevel();

  final LiveCaptionController captions;
  final LiveUtteranceProcessor processor;
  final LiveSpeak speak;
  final Future<void> Function() stopAudio;
  final VoidCallback onNavigate;
  final VoidCallback onEnd;

  final LiveSpeechRecognizer _recognizer;
  final VoiceAudioLevel _audioLevel;
  final PcmAudioLevelAnalyzer _analyzer = PcmAudioLevelAnalyzer();

  final ValueNotifier<VoiceTurnState> state = ValueNotifier<VoiceTurnState>(
    VoiceTurnState.idle,
  );
  final ValueNotifier<double> level = ValueNotifier<double>(0.0);
  final ValueNotifier<double> shaderMode = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  static const String _goodbye = '지금 수행할 작업은 없는 것 같습니다. 언제든 필요하면 다시 불러 주세요.';
  static const Duration _inactivityTimeout = Duration(seconds: 12);
  static const Duration _tick = Duration(milliseconds: 33);
  static const Duration _speechRecoveryTick = Duration(seconds: 1);
  static const Duration _partialCommitDelay = Duration(milliseconds: 750);
  // 듣기 재개 직후 아주 짧게만 이전 턴 잔여 인식 결과를 거른다.
  static const Duration _resumeGuard = Duration(milliseconds: 120);

  Timer? _levelTimer;
  Timer? _speechRecoveryTimer;
  Timer? _inactivityTimer;
  Timer? _partialCommitTimer;
  bool _isCommitting = false;
  bool _isInterrupting = false;
  bool _disposed = false;
  bool _navigateRequested = false;
  bool _ending = false;
  String _partial = '';
  DateTime? _listeningSince;
  int _turnGeneration = 0;

  Future<void> start() async {
    _disposed = false;
    await _audioLevel.startMic();
    _levelTimer ??= Timer.periodic(_tick, (_) => _onTick());
    _speechRecoveryTimer ??= Timer.periodic(
      _speechRecoveryTick,
      (_) => _recoverRecognitionIfNeeded(),
    );
    _setState(VoiceTurnState.listening);
    _listeningSince = DateTime.now();
    await _startRecognition();
    _resetInactivityTimer();
  }

  Future<bool> _startRecognition() async {
    return _recognizer.start(
      localeId: 'ko_KR',
      onResult: _onSpeechResult,
      onState: _onSpeechState,
    );
  }

  void _setState(VoiceTurnState next) {
    if (_disposed) return;
    state.value = next;
    shaderMode.value = next.shaderMode;
    // 웹은 캡처/WS를 계속 유지하고, 듣기 상태가 아닐 때 들어온 결과는 Dart에서 무시한다.
    _recognizer.setActive(next == VoiceTurnState.listening);
  }

  // 사용자가 마이크 버튼을 탭하면 듣기를 (재)개한다. 에이전트가 말하는 중이면
  // 현재 TTS를 끊고 사용자 발화 턴을 연다.
  void handleMicTap() {
    if (_disposed || _ending) return;
    unawaited(_startManualListening());
  }

  Future<void> _startManualListening() async {
    if (_disposed || _ending || _isInterrupting) return;
    // 추론 중에는 이전 사용자 발화를 처리하고 있으므로 새 입력을 열지 않는다.
    if (state.value == VoiceTurnState.thinking) return;

    if (muted.value) muted.value = false;
    if (state.value == VoiceTurnState.speaking) {
      _isInterrupting = true;
      _turnGeneration++;
      _isCommitting = false;
      captions.commitFinal(speaker: Speaker.agent, text: '…(말 중단됨)');
      try {
        await stopAudio();
      } catch (_) {
      } finally {
        _isInterrupting = false;
      }
      if (_disposed || _ending) return;
    }

    _partialCommitTimer?.cancel();
    _inactivityTimer?.cancel();
    _partial = '';
    _setState(VoiceTurnState.listening);
    _listeningSince = DateTime.now();
    // 사용자 제스처 컨텍스트에서 마이크를 복구한다(iOS의 AudioContext suspend/WS 종료 회복).
    _recognizer.setActive(true);
    final ok = _recognizer.resume();
    if (!ok) unawaited(_startRecognition());
    _resetInactivityTimer();
  }

  Future<void> setMuted(bool value) async {
    muted.value = value;
    if (!value && state.value == VoiceTurnState.listening) {
      _listeningSince = DateTime.now();
      _recognizer.resume();
    }
  }

  // ---- 프레임 틱: 오로라 레벨 ----

  void _onTick() {
    if (_disposed) return;
    final mic = state.value == VoiceTurnState.listening && !muted.value
        ? _audioLevel.micLevel()
        : 0.0;
    final out = _audioLevel.outputLevel();

    double target;
    switch (state.value) {
      case VoiceTurnState.listening:
        target = muted.value ? 0.06 : _boost(mic);
      case VoiceTurnState.speaking:
        target = math.max(0.22, _boost(out));
      case VoiceTurnState.thinking:
        final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
        target = 0.34 + 0.18 * (0.5 + 0.5 * math.sin(t * 2.2));
      case VoiceTurnState.idle:
        target = 0.05;
    }
    level.value = _analyzer.smoothLevel(
      current: level.value,
      target: target.clamp(0.0, 1.0),
      attack: 0.5,
      release: 0.045,
    );
  }

  double _boost(double rms) {
    final v = (rms * 2.4).clamp(0.0, 1.0);
    return math.pow(v, 0.7).toDouble();
  }

  Future<void> _drainPlayback() async {
    for (var i = 0; i < 120; i++) {
      if (_disposed) return;
      final remain = _audioLevel.remainingPlaybackMs();
      if (remain <= 80) return;
      final wait = remain > 200 ? 200 : remain.ceil();
      await Future.delayed(Duration(milliseconds: wait));
    }
  }

  // ---- 인식 콜백 ----

  void _onSpeechResult(String text, bool isFinal) {
    if (_disposed) return;
    // 듣는 중이 아닐 때(생각/말하는 중)는 AI 에코·잔여 결과이므로 무시.
    if (state.value != VoiceTurnState.listening || muted.value) return;
    if (_listeningSince != null &&
        DateTime.now().difference(_listeningSince!) < _resumeGuard) {
      // 재개 직후 짧은 잔여 결과는 무시(이전 턴 꼬리).
      return;
    }
    _partial = text;
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      _inactivityTimer?.cancel();
      captions.updatePartial(speaker: Speaker.user, text: trimmed);
    }
    if (isFinal && trimmed.isNotEmpty) {
      _partialCommitTimer?.cancel();
      _commitUserTurn(trimmed);
    } else if (trimmed.isNotEmpty) {
      _schedulePartialCommit();
    }
  }

  void _onSpeechState(String s) {
    if (_disposed || _ending) return;
    if (s == 'listening') return;
    if (s == 'ready' || s == 'recovering') return;
    if (s == 'closed' || s == 'resumeBlocked' || s.startsWith('error')) {
      if (state.value == VoiceTurnState.listening) {
        _recoverRecognitionIfNeeded(force: true);
      }
      return;
    }
    if (s == 'ended' || s == 'notListening' || s == 'done') {
      // 연속 인식(웹)은 JS가 자동 재시작한다. 비연속(네이티브)만 여기서 재개.
      if (!_recognizer.isContinuous &&
          state.value == VoiceTurnState.listening) {
        _recognizer.resume();
      }
    }
  }

  void _recoverRecognitionIfNeeded({bool force = false}) {
    if (_disposed || _ending) return;
    if (state.value != VoiceTurnState.listening) return;
    if (!force && !_recognizer.needsRecovery) return;
    final ok = _recognizer.resume();
    if (!ok) unawaited(_startRecognition());
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_disposed || _ending) return;
    _inactivityTimer = Timer(_inactivityTimeout, () {
      if (_disposed || _ending) return;
      if (state.value == VoiceTurnState.listening &&
          _partial.trim().isEmpty &&
          !_isCommitting) {
        _endConversation();
      }
    });
  }

  void _schedulePartialCommit() {
    _partialCommitTimer?.cancel();
    _partialCommitTimer = Timer(_partialCommitDelay, () {
      if (_disposed || _ending || _isCommitting) return;
      if (state.value != VoiceTurnState.listening || muted.value) return;
      final spoken = _partial.trim();
      if (spoken.isEmpty) return;
      _commitUserTurn(spoken);
    });
  }

  Future<void> _endConversation() async {
    if (_disposed || _ending) return;
    _ending = true;
    _inactivityTimer?.cancel();
    _setState(VoiceTurnState.speaking);
    var shown = false;
    void showCaption() {
      if (shown) return;
      shown = true;
      captions.streamAgent(_goodbye);
    }

    try {
      await speak(_goodbye, onStart: showCaption);
    } catch (_) {}
    showCaption();
    await _drainPlayback();
    if (_disposed) return;
    onEnd();
  }

  // ---- turn commit → 추론 → 응답 음성 ----

  Future<void> _commitUserTurn(String text) async {
    if (_disposed || _isCommitting) return;
    final spoken = text.trim();
    if (spoken.isEmpty) return;
    final turnGeneration = ++_turnGeneration;
    _isCommitting = true;
    _inactivityTimer?.cancel();
    _partialCommitTimer?.cancel();
    _partial = '';
    try {
      captions.commitFinal(speaker: Speaker.user, text: spoken);
      _setState(VoiceTurnState.thinking);

      final result = await processor(
        spoken,
        onThought: (thought) {
          if (!_disposed && state.value == VoiceTurnState.thinking) {
            captions.addThought(thought);
          }
        },
      );
      if (_disposed || turnGeneration != _turnGeneration) return;

      final reply = result.spokenText.trim();
      if (result.endSession) _ending = true;

      var captionShown = false;
      void showAgentCaption() {
        if (captionShown || reply.isEmpty) return;
        captionShown = true;
        captions.streamAgent(reply);
      }

      _setState(VoiceTurnState.speaking);
      if (result.navigateNow) {
        _ending = true;
        _navigateRequested = true;
        if (reply.isNotEmpty) {
          showAgentCaption();
          unawaited(_speakNavigatingReply(reply));
        }
        onNavigate();
        return;
      }
      if (reply.isNotEmpty) {
        try {
          await speak(reply, onStart: showAgentCaption);
        } catch (_) {}
      }
      if (_disposed || turnGeneration != _turnGeneration) return;
      showAgentCaption();
      await _drainPlayback();
      if (_disposed || turnGeneration != _turnGeneration) return;
      if (result.endSession) {
        onEnd();
        return;
      }
      if (_ending) return;
      // 에이전트가 말한 뒤에는 자동으로 다시 듣지 않는다. 다음 사용자 발화는
      // 마이크 버튼 탭으로만 열리며, 그 전까지 STT 입력은 일시 정지된다.
      _partial = '';
      _listeningSince = null;
      _setState(VoiceTurnState.idle);
    } finally {
      if (turnGeneration == _turnGeneration) {
        _isCommitting = false;
      }
    }
  }

  Future<void> _speakNavigatingReply(String reply) async {
    try {
      await speak(reply);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    _levelTimer?.cancel();
    _levelTimer = null;
    _speechRecoveryTimer?.cancel();
    _speechRecoveryTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _partialCommitTimer?.cancel();
    _partialCommitTimer = null;
    try {
      await _recognizer.stop();
    } catch (_) {}
    try {
      await _audioLevel.stopMic();
    } catch (_) {}
    state.value = VoiceTurnState.idle;
    shaderMode.value = VoiceTurnState.idle.shaderMode;
    level.value = 0.0;
  }

  bool get navigateRequested => _navigateRequested;

  void dispose() {
    _levelTimer?.cancel();
    _speechRecoveryTimer?.cancel();
    _inactivityTimer?.cancel();
    _partialCommitTimer?.cancel();
    state.dispose();
    level.dispose();
    shaderMode.dispose();
    muted.dispose();
  }
}
