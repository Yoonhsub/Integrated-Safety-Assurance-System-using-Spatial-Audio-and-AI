import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../mock_scenario/mock_script_lines.dart';
import '../mock_scenario/mock_voice_assets.dart';
import 'speech_priority_coordinator.dart';
import 'audio_shutdown.dart';

class MockScriptAudioService {
  MockScriptAudioService({
    AudioPlayer? audioPlayer,
    FlutterTts? flutterTts,
    this.webClipPlayer,
    this.webClipStop,
    SpeechPriorityCoordinator? speechPriority,
  })  : _audioPlayer = audioPlayer ?? AudioPlayer(),
        _priority = speechPriority ??
            (flutterTts == null
                ? sharedSpeechPriority
                : SpeechPriorityCoordinator(FlutterSpeechEngine(flutterTts)));

  /// 웹(특히 iOS)에서 beep와 동일한 AudioContext로 음성 mp3를 재생하는 경로.
  /// 자산 경로('mock_voice/x.mp3')와 공간 파라미터를 받아 재생 완료 시 true.
  /// null이면 audioplayers 사용.
  final Future<bool> Function(String assetPath, double pan, double gain)?
      webClipPlayer;
  final Future<void> Function()? webClipStop;

  final AudioPlayer _audioPlayer;
  final SpeechPriorityCoordinator _priority;
  final Object _voiceOwner = Object();
  int _generation = 0;
  bool _disposed = false;
  PriorityLease? _quarantine;
  Future<void>? _playerStarting;
  Future<bool>? _clipPlaying;
  late final _shutdown = AudioShutdown(onHold: () {
    _quarantine ??= _priority.claimPriority();
  }, onConfirmed: () {
    _quarantine?.release();
    _quarantine = null;
  });
  bool get shutdownConfirmed => _shutdown.confirmed;
  String? shutdownError;
  Future<void> _stopPlayer() async {
    final starting = _playerStarting;
    await _audioPlayer.stop();
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
      await _audioPlayer.stop();
    }
  }

  Future<void> _stopClip() async {
    final playing = _clipPlaying;
    await webClipStop?.call();
    // Fetch/decode may finish after stop; keep the barrier until retired.
    if (playing != null) {
      try {
        await playing;
      } catch (_) {}
      await webClipStop?.call();
    }
  }

  String? _lastScriptLineId;
  String? _lastSpokenText;
  double _lastSpatialPan = 0;
  double _lastSpatialGain = 1;

  // 현재 재생 중인 클립이 끝날 때까지 기다리기 위한 completer/구독.
  Completer<void>? _playbackCompleter;
  StreamSubscription<void>? _completeSub;

  String? get lastScriptLineId => _lastScriptLineId;
  String? get lastSpokenText => _lastSpokenText;

  /// 한 줄의 안내 음성을 재생하고 **재생이 끝날 때까지 await**한다.
  /// 호출자(시나리오 컨트롤러)가 이 Future로 타임라인을 음성 길이에 맞춰 멈췄다 재개한다.
  Future<void> playScript(String scriptLineId,
      {String? fallbackText,
      double spatialPan = 0,
      double spatialGain = 1}) async {
    final generation = _generation;
    if (_disposed) throw SpeechCancelled();
    final lease = await _priority.acquirePriority();
    try {
      if (_disposed || generation != _generation) throw SpeechCancelled();
      await _playScriptCore(scriptLineId,
          fallbackText: fallbackText,
          spatialPan: spatialPan,
          spatialGain: spatialGain);
    } finally {
      lease.release();
    }
  }

  Future<void> _playScriptCore(
    String scriptLineId, {
    String? fallbackText,
    double spatialPan = 0,
    double spatialGain = 1,
  }) async {
    final line = mockScriptLineById(scriptLineId);
    final text = fallbackText ?? line?.text ?? scriptLineId;
    _lastScriptLineId = scriptLineId;
    _lastSpokenText = text;
    _lastSpatialPan = spatialPan.clamp(-1.0, 1.0).toDouble();
    _lastSpatialGain = spatialGain.clamp(0.0, 1.3).toDouble();
    // 이전 재생을 확실히 멈춰 두 음성이 겹치지 않게 한다.
    final stopping = stop();
    final generation = _generation;
    await stopping;
    if (_disposed || generation != _generation) throw SpeechCancelled();

    final assetPath = mockVoiceAssetPathForText(text) ??
        line?.assetPath ??
        mockVoiceAssetPathForScriptId(scriptLineId);
    if (assetPath != null) {
      // 웹: beep와 같은 컨텍스트로 재생(컨텍스트 충돌 회피). 실패 시 audioplayers로 폴백.
      if (webClipPlayer != null) {
        final playing = Future<bool>.sync(
            () => webClipPlayer!(assetPath, _lastSpatialPan, _lastSpatialGain));
        _clipPlaying = playing;
        bool result;
        try {
          result = await playing;
        } catch (_) {
          if (_disposed || generation != _generation) throw SpeechCancelled();
          await _shutdown.run([_stopClip]);
          rethrow;
        } finally {
          if (identical(_clipPlaying, playing)) _clipPlaying = null;
        }
        if (_disposed || generation != _generation) throw SpeechCancelled();
        if (result) return;
        await _shutdown.run([_stopClip]);
        if (_disposed || generation != _generation) throw SpeechCancelled();
      }
      if (generation != _generation) return;
      if (await _playAsset(assetPath)) {
        return;
      }
    }

    if (generation == _generation) await speakText(text);
  }

  Future<void> repeatLast() async {
    final id = _lastScriptLineId;
    if (id != null) {
      await playScript(
        id,
        fallbackText: _lastSpokenText,
        spatialPan: _lastSpatialPan,
        spatialGain: _lastSpatialGain,
      );
      return;
    }
    final text = _lastSpokenText;
    if (text != null && text.trim().isNotEmpty) {
      await speakText(text);
    }
  }

  /// 기기 TTS 폴백. 자산이 없을 때만 사용되며, awaitSpeakCompletion 덕분에
  /// 발화가 끝날 때까지 await된다.
  Future<void> speakText(String text) async {
    if (_disposed) throw SpeechCancelled();
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _lastSpokenText = trimmed;
    _shutdown.ensureReady();
    final generation = _generation;
    final lease = await _priority.acquirePriority();
    try {
      _shutdown.ensureReady();
      await _priority.speakPriority(_voiceOwner, trimmed,
          () => !_disposed && generation == _generation && lease.active);
    } finally {
      lease.release();
    }
  }

  Future<void> stop() async {
    _generation++;
    final subscription = _completeSub;
    _completeSub = null;
    final completer = _playbackCompleter;
    _playbackCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(SpeechCancelled());
    }
    // Listener retirement is independent from audible output confirmation.
    unawaited(Future<void>.sync(() async {
      await subscription?.cancel();
    }).catchError((Object _) {
      shutdownError = '오디오 완료 구독 정리에 실패했습니다.';
    }));
    // Invoke every cleanup even when another channel fails or never replies.
    try {
      await _shutdown.run([
        _stopClip,
        _stopPlayer,
        () => _priority.stopPriority(_voiceOwner),
      ]);
      shutdownError = null;
    } on AudioShutdownFailure catch (error) {
      shutdownError = error.toString();
      rethrow;
    }
  }

  /// 자산(mp3)을 재생하고 **자연 종료(onPlayerComplete)까지 기다린다**.
  /// 중간에 stop()이 불리면 completer가 완료되어 즉시 반환한다.
  Future<bool> _playAsset(String assetPath) async {
    final generation = _generation;
    final completer = Completer<void>();
    unawaited(completer.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _playbackCompleter = completer;
    final subscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (generation == _generation && !completer.isCompleted) {
        completer.complete();
      }
    });
    _completeSub = subscription;
    try {
      final pending =
          Future<void>.sync(() => _audioPlayer.play(AssetSource(assetPath)));
      _playerStarting = pending;
      try {
        await pending;
      } finally {
        if (identical(_playerStarting, pending)) _playerStarting = null;
      }
      if (_disposed || generation != _generation) throw SpeechCancelled();
      await completer.future.timeout(const Duration(seconds: 30));
      if (_disposed || generation != _generation) throw SpeechCancelled();
      return true;
    } on SpeechCancelled {
      rethrow;
    } catch (_) {
      // Preserve the current request only for a real, recoverable failure.
      if (_disposed || generation != _generation) throw SpeechCancelled();
      await _shutdown.run([
        _stopPlayer,
        _stopClip,
        () => _priority.stopPriority(_voiceOwner),
      ]);
      if (_disposed || generation != _generation) throw SpeechCancelled();
      return false;
    } finally {
      await subscription.cancel();
      if (identical(_completeSub, subscription)) _completeSub = null;
      if (identical(_playbackCompleter, completer)) _playbackCompleter = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _audioPlayer.dispose();
  }
}
