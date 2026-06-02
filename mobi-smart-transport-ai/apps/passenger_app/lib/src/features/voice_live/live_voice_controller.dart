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
// onStart는 실제 오디오 첫 청크가 도착(=소리 시작)할 때 호출된다(자막 동기화용).
typedef LiveSpeak = Future<void> Function(String text, {VoidCallback? onStart});

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
  static const Duration _sttRestartDelay = Duration(milliseconds: 350);
  static const Duration _sttRetryDelay = Duration(milliseconds: 700);
  static const Duration _tick = Duration(milliseconds: 33);

  Timer? _levelTimer;
  Timer? _inactivityTimer;
  Timer? _listenRetryTimer;
  int _listenGeneration = 0;
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

    // 오로라 진폭(실 RMS, thinking만 fake pulse). RMS가 작아 빈약해 보이므로
    // 게인+소프트 부스트로 가시성을 키운다.
    double target;
    switch (state.value) {
      case VoiceTurnState.listening:
        target = muted.value ? 0.06 : _boost(mic);
      case VoiceTurnState.speaking:
        target = math.max(0.22, _boost(out)); // AI 발화 중엔 항상 또렷하게.
      case VoiceTurnState.thinking:
        final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
        target = 0.34 + 0.18 * (0.5 + 0.5 * math.sin(t * 2.2));
      case VoiceTurnState.idle:
        target = 0.05;
    }
    // 상승은 빠르게, 하락은 더 천천히(발화 중 잠깐의 무음에 꺼지지 않게).
    level.value = _analyzer.smoothLevel(
      current: level.value,
      target: target.clamp(0.0, 1.0),
      attack: 0.5,
      release: 0.045,
    );

    if (_ending) return;
    if (state.value == VoiceTurnState.listening &&
        !muted.value &&
        _calibrated) {
      _vadListening(mic);
    } else if (state.value == VoiceTurnState.speaking &&
        _calibrated &&
        !muted.value) {
      _vadBargeIn(mic, out);
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

  // 작은 RMS를 또렷하게 키운다(게인 + soft-knee 곡선).
  double _boost(double rms) {
    final v = (rms * 2.4).clamp(0.0, 1.0);
    return math.pow(v, 0.7).toDouble();
  }

  // 스케줄된 재생이 끝날 때까지 대기(막판 음성 잘림 방지). barge-in/종료로 stop되면
  // 남은 시간이 0이 되어 즉시 빠져나온다.
  Future<void> _drainPlayback() async {
    for (var i = 0; i < 120; i++) {
      if (_disposed) return;
      final remain = _audioLevel.remainingPlaybackMs();
      if (remain <= 80) return;
      final wait = remain > 200 ? 200 : remain.ceil();
      await Future.delayed(Duration(milliseconds: wait));
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

  void _vadBargeIn(double mic, double output) {
    // AI 음성 에코로 인한 오인을 막는다: 사용자의 마이크 입력이 충분히 크고,
    // 동시에 현재 AI 출력 레벨보다 뚜렷하게 높을 때만 barge-in으로 인정한다.
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

  /// 사용자가 마이크 버튼을 탭했을 때: 듣기를 강제로 (재)시작한다.
  /// iOS Safari/인앱 브라우저는 음성 인식의 무제스처 자동 재시작을 막는 경우가 있어,
  /// 탭(=사용자 제스처) 시점에 동기적으로 listen을 다시 연다. 이미 듣는 중이면 무시.
  Future<void> handleMicTap() async {
    if (_disposed || _ending) return;
    if (muted.value) muted.value = false;
    if (state.value != VoiceTurnState.listening) return;
    _listenRetryTimer?.cancel();
    _listenGeneration += 1;
    await _startListening(_listenGeneration);
  }

  Future<void> setMuted(bool value) async {
    muted.value = value;
    if (value) {
      try {
        await _speech.stop();
      } catch (_) {}
    } else if (state.value == VoiceTurnState.listening) {
      _beginListening(delay: _sttRestartDelay);
    }
  }

  void _beginListening({Duration delay = Duration.zero}) {
    if (_disposed || !_speechReady || muted.value || _ending) return;
    _listenRetryTimer?.cancel();
    final generation = ++_listenGeneration;
    if (delay > Duration.zero) {
      _listenRetryTimer = Timer(delay, () {
        _listenRetryTimer = null;
        _startListening(generation);
      });
      return;
    }
    _startListening(generation);
  }

  Future<void> _startListening(int generation) async {
    if (_disposed ||
        generation != _listenGeneration ||
        !_speechReady ||
        muted.value ||
        _ending ||
        state.value != VoiceTurnState.listening) {
      return;
    }
    if (_speech.isListening) return;
    _partial = '';
    _userSpeaking = false;
    _speechStartedAt = null;
    _lastVoiceAt = null;
    _bargingIn = false;
    _bargeStartedAt = null;
    try {
      await _speech.listen(
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
    } catch (_) {
      // Web Speech API는 직전 recognition 종료가 정착되기 전에 재시작하면
      // 예외를 내거나 요청을 무시할 수 있다. 아래 재시도가 복구한다.
    }
    if (!_speech.isListening) _scheduleListeningRetry();
  }

  void _scheduleListeningRetry() {
    if (_disposed ||
        !_speechReady ||
        muted.value ||
        _ending ||
        state.value != VoiceTurnState.listening) {
      return;
    }
    _beginListening(delay: _sttRetryDelay);
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
    if (_partial.trim().isEmpty) {
      _scheduleListeningRetry();
      return;
    }
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
    // 작별 인사가 끝까지 재생된 뒤에 통화를 닫는다(말 씹힘 방지).
    await _drainPlayback();
    if (_disposed) return;
    onEnd();
  }

  // ---- turn commit → 추론 → 응답 음성 ----

  Future<void> _commitUserTurn(String text) async {
    if (_disposed || _isCommitting) return;
    final spoken = text.trim();
    if (spoken.isEmpty) {
      if (state.value == VoiceTurnState.listening && !_ending) {
        _scheduleListeningRetry();
      }
      return;
    }
    _isCommitting = true;
    _listenRetryTimer?.cancel();
    _listenGeneration += 1;
    _inactivityTimer?.cancel();
    try {
      await _speech.stop();
      captions.commitFinal(speaker: Speaker.user, text: spoken);
      _setState(VoiceTurnState.thinking);

      final result = await processor(spoken);
      if (_disposed) return;

      final reply = result.spokenText.trim();
      // 종료/전환이면 떠나는 동안 VAD·재듣기를 멈춘다.
      if (result.endSession || result.navigateNow) _ending = true;

      // 자막은 실제 소리가 시작될 때 맞춘다(텍스트 먼저 뜨고 소리 늦는 문제 완화).
      var captionShown = false;
      void showAgentCaption() {
        if (captionShown || reply.isEmpty) return;
        captionShown = true;
        // GPT 답변처럼 한 글자씩 스트리밍으로 노출.
        captions.streamAgent(reply);
      }

      _setState(VoiceTurnState.speaking);
      if (reply.isNotEmpty) {
        try {
          await speak(reply, onStart: showAgentCaption);
        } catch (_) {
          // 음성 출력 실패/중단해도 대화는 계속한다.
        }
      }
      showAgentCaption(); // 오디오가 없더라도 자막은 보장.
      await _drainPlayback(); // 마지막 음성이 잘리지 않도록 재생 완료까지 대기.
      if (_disposed) return;

      if (result.navigateNow) {
        _navigateRequested = true;
        onNavigate();
        return;
      }
      if (result.endSession) {
        onEnd();
        return;
      }
      if (_ending) return;
      _setState(VoiceTurnState.listening);
      // 브라우저 STT가 직전 세션 종료를 반영할 시간을 준 뒤 다시 연다.
      // 실패하면 _startListening이 실제 listening 상태를 확인하고 재시도한다.
      _beginListening(delay: _sttRestartDelay);
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
    _listenRetryTimer?.cancel();
    _listenRetryTimer = null;
    _listenGeneration += 1;
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
    _listenRetryTimer?.cancel();
    state.dispose();
    level.dispose();
    shaderMode.dispose();
    muted.dispose();
  }
}
