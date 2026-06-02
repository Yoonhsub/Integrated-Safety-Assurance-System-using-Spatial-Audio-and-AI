import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'live_caption_controller.dart';
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

  /// AI가 말하고 자막으로 보여 줄 텍스트.
  final String spokenText;

  /// 사용자가 길 안내에 동의해 즉시 네비 화면으로 전환해야 하면 true.
  final bool navigateNow;

  /// 사용자가 대화를 끝내려는 의사를 보여(에이전트 NLU 판단) Live를 닫아야 하면 true.
  final bool endSession;
}

typedef LiveUtteranceProcessor = Future<LiveProcessResult> Function(
    String utterance);
typedef LiveSpeak = Future<void> Function(String text);

/// LiveVoicePage의 상태 머신·turn-taking·오디오 레벨·자막을 관리한다.
///
/// 실제 통화처럼 자연스럽게 동작하도록, 고정 3초 대기 대신 마이크 에너지 기반
/// 적응형 endpointing(주변 소음 보정 + 약 0.9초 무음으로 발화 종료 판정)을 쓰고,
/// AI가 말하는 중 사용자가 끼어들면(barge-in) 재생을 즉시 끊고 다시 듣는다.
/// 입력 전사는 speech_to_text(웹은 Web Speech API), 추론/음성은 페이지가 주입한
/// [processor]/[speak](기존 /agent/converse + Gemini Live TTS)로 위임한다.
class LiveVoiceController {
  LiveVoiceController({
    required this.captions,
    required this.processor,
    required this.speak,
    required this.stopAudio,
    required this.onNavigate,
    required this.onEnd,
    SpeechToText? speechToText,
    VoiceAudioLevel? audioLevel,
  })  : _speech = speechToText ?? SpeechToText(),
        _audioLevel = audioLevel ?? VoiceAudioLevel();

  final LiveCaptionController captions;
  final LiveUtteranceProcessor processor;
  final LiveSpeak speak;

  /// 진행 중인 Live TTS 재생/WebSocket을 즉시 중단한다(barge-in·종료 시).
  final Future<void> Function() stopAudio;

  /// 길 안내 확정 시(사용자 동의) 호출 — 페이지가 Live 종료 후 네비로 전환한다.
  final VoidCallback onNavigate;

  /// 대화 종료(종료 의사/무응답) 시 호출 — 페이지가 Live를 닫는다.
  final VoidCallback onEnd;

  final SpeechToText _speech;
  final VoiceAudioLevel _audioLevel;
  final PcmAudioLevelAnalyzer _analyzer = PcmAudioLevelAnalyzer();

  final ValueNotifier<VoiceTurnState> state =
      ValueNotifier<VoiceTurnState>(VoiceTurnState.idle);
  final ValueNotifier<double> level = ValueNotifier<double>(0.0);
  final ValueNotifier<double> shaderMode = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  static const String _goodbye = '지금 내가 수행할 작업이 없는 것 같아. 언제든 필요하면 불러줘.';

  // ---- 자연스러운 turn-taking 튜닝값 ----
  static const Duration _inactivityTimeout = Duration(seconds: 10);
  // 발화 끝으로 판정하는 무음 길이(자연 대화에 가깝게 짧게).
  static const Duration _endpointSilence = Duration(milliseconds: 850);
  // 너무 짧은 잡음을 발화로 오인하지 않도록 최소 발화 길이.
  static const Duration _minSpeech = Duration(milliseconds: 350);
  // barge-in으로 인정하기 위한 지속 시간.
  static const Duration _bargeInSustain = Duration(milliseconds: 320);
  // STT 자체 안전망(내 VAD가 먼저 끊으므로 길게).
  static const Duration _sttSafetyPause = Duration(seconds: 5);
  static const Duration _tick = Duration(milliseconds: 33);

  Timer? _levelTimer;
  Timer? _inactivityTimer;
  bool _speechReady = false;
  bool _isCommitting = false;
  bool _disposed = false;
  bool _navigateRequested = false;
  bool _ending = false;
  String _partial = '';

  // VAD 상태
  bool _calibrated = false;
  double _calibAccum = 0.0;
  int _calibSamples = 0;
  DateTime? _startedAt;
  double _noiseFloor = 0.02;
  double _speechThreshold = 0.08;
  double _silenceThreshold = 0.05;
  bool _userSpeaking = false;
  DateTime? _speechStartedAt;
  DateTime? _lastVoiceAt;
  bool _endpointing = false;
  DateTime? _bargeStartedAt;
  bool _bargingIn = false;

  Future<void> start() async {
    _disposed = false;
    await _audioLevel.startMic();
    _startedAt = DateTime.now();
    _levelTimer ??= Timer.periodic(_tick, (_) => _onTick());
    _speechReady = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) => _onListenEnded(),
    );
    _setState(VoiceTurnState.listening);
    _beginListening();
    _resetInactivityTimer();
  }

  void _setState(VoiceTurnState next) {
    if (_disposed) return;
    state.value = next;
    shaderMode.value = next.shaderMode;
  }

  // ---- 프레임 틱: 오로라 레벨 + VAD ----

  void _onTick() {
    if (_disposed) return;
    final mic = muted.value ? 0.0 : _audioLevel.micLevel();
    final out = _audioLevel.outputLevel();

    _calibrate(mic);

    // 오로라 진폭(실 RMS, thinking만 fake pulse)
    double target;
    switch (state.value) {
      case VoiceTurnState.listening:
        target = muted.value ? 0.04 : mic;
      case VoiceTurnState.speaking:
        target = out;
      case VoiceTurnState.thinking:
        final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
        target = 0.28 + 0.16 * (0.5 + 0.5 * math.sin(t * 2.2));
      case VoiceTurnState.idle:
        target = 0.04;
    }
    level.value = _analyzer.smoothLevel(
      current: level.value,
      target: target.clamp(0.0, 1.0),
    );

    if (_ending) return;
    if (state.value == VoiceTurnState.listening && !muted.value && _calibrated) {
      _vadListening(mic);
    } else if (state.value == VoiceTurnState.speaking && _calibrated) {
      _vadBargeIn(mic);
    } else {
      _userSpeaking = false;
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
      // 주변 소음 위로 충분히, 그러나 작은 목소리도 잡도록 보정.
      _speechThreshold = math.max(0.06, _noiseFloor * 2.6 + 0.02);
      _silenceThreshold = math.max(0.035, _noiseFloor * 1.7 + 0.012);
      _calibrated = true;
    }
  }

  void _vadListening(double level) {
    final now = DateTime.now();
    if (level >= _speechThreshold) {
      if (!_userSpeaking) {
        _userSpeaking = true;
        _speechStartedAt = now;
      }
      _lastVoiceAt = now;
      _inactivityTimer?.cancel();
    } else if (_userSpeaking && level <= _silenceThreshold) {
      final spokeEnough = _speechStartedAt != null &&
          now.difference(_speechStartedAt!) >= _minSpeech;
      final silentEnough = _lastVoiceAt != null &&
          now.difference(_lastVoiceAt!) >= _endpointSilence;
      if (spokeEnough && silentEnough) {
        _endpointNow();
      }
    }
  }

  // 자연스러운 발화 끝: STT를 멈추면 final 결과가 와서 turn이 commit된다.
  Future<void> _endpointNow() async {
    if (_endpointing || _isCommitting || _ending) return;
    _endpointing = true;
    _userSpeaking = false;
    try {
      await _speech.stop();
    } catch (_) {}
    _endpointing = false;
  }

  void _vadBargeIn(double level) {
    // 에코(AI 음성)가 마이크로 새는 것을 줄이려 더 높은 임계 + 지속시간 요구.
    if (level >= _speechThreshold * 1.35) {
      _bargeStartedAt ??= DateTime.now();
      if (DateTime.now().difference(_bargeStartedAt!) >= _bargeInSustain) {
        _bargeStartedAt = null;
        _triggerBargeIn();
      }
    } else {
      _bargeStartedAt = null;
    }
  }

  // AI가 말하는 중 사용자가 끼어들면 재생을 끊는다. 끊긴 speak()가 반환되면
  // _commitUserTurn의 후속 흐름이 자동으로 다시 듣기로 전환한다.
  Future<void> _triggerBargeIn() async {
    if (_bargingIn || _ending || _disposed) return;
    _bargingIn = true;
    captions.commitFinal(speaker: Speaker.agent, text: '…(말 중단됨)');
    try {
      await stopAudio();
    } catch (_) {}
  }

  // ---- 듣기 ----

  Future<void> setMuted(bool value) async {
    muted.value = value;
    if (value) {
      try {
        await _speech.stop();
      } catch (_) {}
    } else if (state.value == VoiceTurnState.listening) {
      _beginListening();
    }
  }

  void _beginListening() {
    if (_disposed || !_speechReady || muted.value || _ending) return;
    _partial = '';
    _userSpeaking = false;
    _speechStartedAt = null;
    _lastVoiceAt = null;
    _bargingIn = false;
    _bargeStartedAt = null;
    _speech.listen(
      localeId: 'ko_KR',
      // 내 VAD가 먼저 자연스럽게 끊으므로 STT pause는 안전망 용도로 길게 둔다.
      pauseFor: _sttSafetyPause,
      listenFor: const Duration(seconds: 120),
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void _onResult(SpeechRecognitionResult result) {
    if (_disposed) return;
    _partial = result.recognizedWords;
    if (_partial.trim().isNotEmpty) {
      _inactivityTimer?.cancel();
      captions.updatePartial(speaker: Speaker.user, text: _partial);
    }
    if (result.finalResult) {
      _commitUserTurn(_partial);
    }
  }

  void _onSpeechStatus(String status) {
    if (_disposed) return;
    if (status == 'notListening' || status == 'done') {
      _onListenEnded();
    }
  }

  void _onListenEnded() {
    if (_disposed) return;
    if (state.value != VoiceTurnState.listening) return;
    _commitUserTurn(_partial);
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

  Future<void> _endConversation() async {
    if (_disposed || _ending) return;
    _ending = true;
    _inactivityTimer?.cancel();
    try {
      await _speech.stop();
    } catch (_) {}
    captions.commitFinal(speaker: Speaker.agent, text: _goodbye);
    _setState(VoiceTurnState.speaking);
    try {
      await speak(_goodbye);
    } catch (_) {}
    if (_disposed) return;
    onEnd();
  }

  // ---- turn commit → 추론 → 응답 음성 ----

  Future<void> _commitUserTurn(String text) async {
    if (_disposed || _isCommitting) return;
    final spoken = text.trim();
    if (spoken.isEmpty) {
      if (state.value == VoiceTurnState.listening && !_ending) {
        Future.delayed(const Duration(milliseconds: 250), _beginListening);
      }
      return;
    }
    _isCommitting = true;
    _inactivityTimer?.cancel();
    try {
      await _speech.stop();
      captions.commitFinal(speaker: Speaker.user, text: spoken);
      _setState(VoiceTurnState.thinking);

      final result = await processor(spoken);
      if (_disposed) return;

      final reply = result.spokenText.trim();
      if (reply.isNotEmpty) {
        captions.commitFinal(speaker: Speaker.agent, text: reply);
      }

      if (result.endSession) {
        _ending = true;
        _setState(VoiceTurnState.speaking);
        if (reply.isNotEmpty) {
          try {
            await speak(reply);
          } catch (_) {}
        }
        if (_disposed) return;
        onEnd();
        return;
      }

      if (result.navigateNow) {
        _setState(VoiceTurnState.speaking);
        if (reply.isNotEmpty) {
          try {
            await speak(reply);
          } catch (_) {}
        }
        if (_disposed) return;
        _navigateRequested = true;
        onNavigate();
        return;
      }

      // 응답 음성. barge-in으로 끊기면 speak()가 반환되고 곧바로 다시 듣는다.
      _setState(VoiceTurnState.speaking);
      if (reply.isNotEmpty) {
        try {
          await speak(reply);
        } catch (_) {
          // 음성 출력 실패/중단해도 대화는 계속한다.
        }
      }
      if (_disposed || _ending) return;
      _setState(VoiceTurnState.listening);
      _beginListening();
      _resetInactivityTimer();
    } finally {
      _isCommitting = false;
    }
  }

  /// X 종료/네비 전환 시 모든 자원을 정리한다.
  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    _levelTimer?.cancel();
    _levelTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    try {
      await _speech.cancel();
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
    _inactivityTimer?.cancel();
    state.dispose();
    level.dispose();
    shaderMode.dispose();
    muted.dispose();
  }
}
