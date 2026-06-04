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
/// 음성 인식은 [LiveSpeechRecognizer]를 쓴다. 웹은 **연속(continuous) 인식**으로
/// 세션을 한 번만 시작하고 턴 사이에 멈추지 않아, iOS/인앱 브라우저의 무제스처
/// 재시작 차단으로 두 번째 턴부터 인식이 씹히던 문제를 없앤다. 발화 종료는
/// 인식기의 final 결과로 판정한다(고정 3초 대기 아님).
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

  final ValueNotifier<VoiceTurnState> state =
      ValueNotifier<VoiceTurnState>(VoiceTurnState.idle);
  final ValueNotifier<double> level = ValueNotifier<double>(0.0);
  final ValueNotifier<double> shaderMode = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  static const String _goodbye = '지금 내가 수행할 작업이 없는 것 같아. 언제든 필요하면 불러줘.';
  static const Duration _inactivityTimeout = Duration(seconds: 12);
  static const Duration _bargeInSustain = Duration(milliseconds: 320);
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
  bool _disposed = false;
  bool _navigateRequested = false;
  bool _ending = false;
  String _partial = '';
  DateTime? _listeningSince;

  // 보정(주변 소음) — barge-in 임계 산정용.
  bool _calibrated = false;
  double _calibAccum = 0.0;
  int _calibSamples = 0;
  DateTime? _startedAt;
  double _noiseFloor = 0.02;
  double _speechThreshold = 0.08;
  DateTime? _bargeStartedAt;
  bool _bargingIn = false;

  Future<void> start() async {
    _disposed = false;
    await _audioLevel.startMic();
    _startedAt = DateTime.now();
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

  // 사용자가 마이크 버튼을 탭하면 듣기를 (재)개한다. 자동 재시작이 막힌 환경에서
  // 사용자 제스처로 복구하는 경로.
  void handleMicTap() {
    if (_disposed || _ending) return;
    if (muted.value) muted.value = false;
    _listeningSince = DateTime.now();
    if (state.value != VoiceTurnState.listening) {
      _setState(VoiceTurnState.listening);
    }
    // 사용자 제스처 컨텍스트에서 마이크를 복구한다(iOS의 AudioContext suspend/WS 종료 회복).
    _recognizer.setActive(true);
    final ok = _recognizer.resume();
    if (!ok) unawaited(_startRecognition());
  }

  Future<void> setMuted(bool value) async {
    muted.value = value;
    if (!value && state.value == VoiceTurnState.listening) {
      _listeningSince = DateTime.now();
      _recognizer.resume();
    }
  }

  // ---- 프레임 틱: 오로라 레벨 + barge-in ----

  void _onTick() {
    if (_disposed) return;
    final mic = muted.value ? 0.0 : _audioLevel.micLevel();
    final out = _audioLevel.outputLevel();
    _calibrate(mic);

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

    if (_ending) return;
    if (state.value == VoiceTurnState.speaking && _calibrated && !muted.value) {
      _vadBargeIn(mic, out);
    } else {
      _bargeStartedAt = null;
    }
  }

  void _calibrate(double mic) {
    if (_calibrated || _startedAt == null) return;
    _calibAccum += mic;
    _calibSamples += 1;
    if (DateTime.now().difference(_startedAt!) >=
            const Duration(milliseconds: 600) &&
        _calibSamples > 0) {
      _noiseFloor = (_calibAccum / _calibSamples).clamp(0.0, 0.2);
      _speechThreshold = math.max(0.06, _noiseFloor * 2.6 + 0.02);
      _calibrated = true;
    }
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

  void _vadBargeIn(double mic, double output) {
    final loudEnough = mic >= _speechThreshold * 1.8 + 0.04;
    final overAi = mic >= output * 1.6 + 0.05;
    if (loudEnough && overAi) {
      _bargeStartedAt ??= DateTime.now();
      if (DateTime.now().difference(_bargeStartedAt!) >= _bargeInSustain) {
        _bargeStartedAt = null;
        _triggerBargeIn();
      }
    } else {
      _bargeStartedAt = null;
    }
  }

  Future<void> _triggerBargeIn() async {
    if (_bargingIn || _ending || _disposed) return;
    _bargingIn = true;
    captions.commitFinal(speaker: Speaker.agent, text: '…(말 중단됨)');
    try {
      await stopAudio();
    } catch (_) {}
    if (_disposed || _ending) return;
    _partial = '';
    _setState(VoiceTurnState.listening);
    _listeningSince = DateTime.now();
    if (!_recognizer.resume()) unawaited(_startRecognition());
    _resetInactivityTimer();
    _bargingIn = false;
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
      _recoverRecognitionIfNeeded(force: true);
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
      if (_disposed) return;

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
      showAgentCaption();
      await _drainPlayback();
      if (_disposed) return;
      if (result.endSession) {
        onEnd();
        return;
      }
      if (_ending) return;
      // 다시 듣기. 연속 인식은 계속 돌고 있으므로 상태만 전환하고 잔여 결과를
      // 잠깐 무시한다. 비연속은 명시적으로 재개한다.
      _partial = '';
      _setState(VoiceTurnState.listening);
      _listeningSince = DateTime.now();
      // AI 발화 후 멈췄을 수 있는 마이크를 복구(컨텍스트 재개 + WS 재연결 + 버퍼 리셋).
      if (!_recognizer.resume()) unawaited(_startRecognition());
      _resetInactivityTimer();
    } finally {
      _isCommitting = false;
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
