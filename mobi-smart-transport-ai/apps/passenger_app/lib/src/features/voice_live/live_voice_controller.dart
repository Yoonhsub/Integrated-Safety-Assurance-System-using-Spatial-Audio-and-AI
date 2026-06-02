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
/// 입력 전사는 speech_to_text(웹은 Web Speech API)가 담당하며, 무음으로 인식이
/// 끝나면(=수동 전송 버튼 없이) 자동으로 turn을 commit한다. 추론/음성은 페이지가
/// 주입한 [processor]/[speak](기존 /agent/converse + Gemini Live TTS)로 위임한다.
class LiveVoiceController {
  LiveVoiceController({
    required this.captions,
    required this.processor,
    required this.speak,
    required this.onNavigate,
    required this.onEnd,
    SpeechToText? speechToText,
    VoiceAudioLevel? audioLevel,
  })  : _speech = speechToText ?? SpeechToText(),
        _audioLevel = audioLevel ?? VoiceAudioLevel();

  final LiveCaptionController captions;
  final LiveUtteranceProcessor processor;
  final LiveSpeak speak;

  /// 길 안내 확정 시(사용자 동의) 호출 — 페이지가 Live 종료 후 네비로 전환한다.
  final VoidCallback onNavigate;

  /// 대화 종료(종료 의사/무응답) 시 호출 — 페이지가 Live를 닫는다.
  final VoidCallback onEnd;

  static const String _goodbye = '지금 내가 수행할 작업이 없는 것 같아. 언제든 필요하면 불러줘.';

  /// 무응답 자동 종료까지의 대기 시간.
  static const Duration _inactivityTimeout = Duration(seconds: 10);

  final SpeechToText _speech;
  final VoiceAudioLevel _audioLevel;
  final PcmAudioLevelAnalyzer _analyzer = PcmAudioLevelAnalyzer();

  final ValueNotifier<VoiceTurnState> state =
      ValueNotifier<VoiceTurnState>(VoiceTurnState.idle);
  final ValueNotifier<double> level = ValueNotifier<double>(0.0);
  final ValueNotifier<double> shaderMode = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  Timer? _levelTimer;
  Timer? _inactivityTimer;
  bool _speechReady = false;
  bool _isCommitting = false;
  bool _disposed = false;
  bool _navigateRequested = false;
  bool _ending = false;
  String _partial = '';

  Future<void> start() async {
    _disposed = false;
    await _audioLevel.startMic();
    _levelTimer ??= Timer.periodic(
        const Duration(milliseconds: 33), (_) => _sampleLevel());
    _speechReady = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) => _onListenEnded(),
    );
    _setState(VoiceTurnState.listening);
    _beginListening();
  }

  // ---- 상태/레벨 ----

  void _setState(VoiceTurnState next) {
    if (_disposed) return;
    state.value = next;
    shaderMode.value = next.shaderMode;
  }

  void _sampleLevel() {
    if (_disposed) return;
    double target;
    switch (state.value) {
      case VoiceTurnState.listening:
        target = muted.value ? 0.04 : _audioLevel.micLevel();
      case VoiceTurnState.speaking:
        target = _audioLevel.outputLevel();
      case VoiceTurnState.thinking:
        // 실제 음성이 없으므로 부드러운 fake pulse.
        final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
        target = 0.28 + 0.16 * (0.5 + 0.5 * math.sin(t * 2.2));
      case VoiceTurnState.idle:
        target = 0.04;
    }
    level.value = _analyzer.smoothLevel(
      current: level.value,
      target: target.clamp(0.0, 1.0),
    );
  }

  // ---- 듣기(turn 시작) ----

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
    _resetInactivityTimer();
    _speech.listen(
      localeId: 'ko_KR',
      // 3초 무음이면 자동으로 인식 종료 → 수동 전송 버튼 불필요.
      pauseFor: const Duration(seconds: 3),
      listenFor: const Duration(seconds: 60),
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
      // 사용자가 말하는 동안에는 무응답 타이머를 멈춘다.
      _inactivityTimer?.cancel();
      captions.updatePartial(speaker: Speaker.user, text: _partial);
    }
    if (result.finalResult) {
      _commitUserTurn(_partial);
    }
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_disposed || _ending) return;
    _inactivityTimer = Timer(_inactivityTimeout, () {
      // 10초 무응답: 듣는 중이고 아직 한 마디도 안 했을 때만 자동 종료.
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

  void _onSpeechStatus(String status) {
    if (_disposed) return;
    // 무음 등으로 인식이 끝나면 현재 partial로 turn을 종료한다.
    if (status == 'notListening' || status == 'done') {
      _onListenEnded();
    }
  }

  void _onListenEnded() {
    if (_disposed) return;
    if (state.value != VoiceTurnState.listening) return;
    _commitUserTurn(_partial);
  }

  // ---- turn commit → 추론 → 응답 음성 ----

  Future<void> _commitUserTurn(String text) async {
    if (_disposed || _isCommitting) return;
    final spoken = text.trim();
    if (spoken.isEmpty) {
      // 아직 한 마디도 안 했으면 다시 듣기 상태 유지.
      if (state.value == VoiceTurnState.listening) {
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
        // 종료 의사(NLU) → 작별 인사 후 Live 종료.
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
        // 사용자 동의 → 짧게 안내하고 네비 전환(페이지가 종료 처리).
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

      _setState(VoiceTurnState.speaking);
      if (reply.isNotEmpty) {
        try {
          await speak(reply);
        } catch (_) {
          // 음성 출력 실패해도 대화는 계속한다.
        }
      }
      if (_disposed) return;
      _setState(VoiceTurnState.listening);
      _beginListening();
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
    _setStateSafe(VoiceTurnState.idle);
    level.value = 0.0;
  }

  void _setStateSafe(VoiceTurnState next) {
    state.value = next;
    shaderMode.value = next.shaderMode;
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
