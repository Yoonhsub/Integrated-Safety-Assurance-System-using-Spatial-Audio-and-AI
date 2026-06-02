import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../features/voice_live/live_caption_controller.dart';
import '../features/voice_live/live_voice_controller.dart';
import '../features/voice_live/live_voice_page.dart';
import '../models/v3_guidance_models.dart';
import '../services/api_base_url.dart';
import '../services/audio_haptic_cue_service.dart';
import '../services/converse_live.dart';
import '../services/v3_agent_api_client.dart';
import '../services/web_geolocation.dart';
import '../services/voice_guide_service.dart';
import '../widgets/chat_overlay.dart';
import '../widgets/debug_panel.dart';
import '../widgets/mock_control_panel.dart';

class V3GuidancePage extends StatefulWidget {
  const V3GuidancePage({
    super.key,
    required this.agentName,
    required this.onReturnToModeSelection,
    required this.dataMode,
  });

  final String agentName;
  final VoidCallback onReturnToModeSelection;
  final String dataMode;

  @override
  State<V3GuidancePage> createState() => _V3GuidancePageState();
}

class _V3GuidancePageState extends State<V3GuidancePage> {
  static const String _routePlanningMessage =
      '요청하신 내용을 응답하기 위해 경로를 계산 중입니다. 잠시만 기다려 주세요.';

  static final String _apiBaseUrl = resolveApiBaseUrl();

  static const String _sessionId = 'demo-session';

  late final V3AgentApiClient _client;
  late final AudioHapticCueService _cueService;
  late final VoiceGuideService _voiceGuideService;
  late final TextEditingController _utteranceController;

  V3HealthStatus? _healthStatus;
  V3GuidanceState? _sessionState;
  V3AgentResponse? _lastAgentResponse;
  V3RouteRecommendResponse? _lastRouteRecommendation;
  V3RoutePlanResponse? _lastRoutePlan;
  V3BusArrivalsResponse? _lastArrivals;
  V3BeaconDecisionResponse? _lastBeaconDecision;
  String? _latestGeofenceMessage;
  String? _routePlanningStatus;
  String? _errorMessage;
  bool _isBusy = false;
  bool _isRoutePlanning = false;
  bool _useMockHeadTracking = false;
  HeadTrackingDebugSnapshot _headTracking =
      HeadTrackingDebugSnapshot.disabled();
  Timer? _liveRouteTimer;
  V3LiveStatus? _liveStatus;
  Position? _lastRoutePosition;
  String? _liveRouteError;
  bool _liveRoutePanelVisible = false;
  bool _isLiveRouteLoading = false;
  // 사용자가 '길찾기 중지'를 누르면 지도/경로 UI를 끄고 폴링을 멈춘 상태로 표시한다.
  // 새 목적지 탐색이 시작되면 다시 false로 풀린다.
  bool _navStopped = false;
  // 앱 진입 시 1회 확보해 두는 실제 사용자 위치. 경로 탐색마다 새로 받지 않고 재사용한다.
  Position? _cachedPosition;
  // 위치 권한이 거부/불가해 실제 위치를 쓸 수 없는 상태.
  bool _locationDenied = false;
  // 위치 권한 확인이 진행 중인지(중복 요청 방지).
  bool _resolvingLocation = false;
  bool _isAgentTraceExpanded = false;
  bool _isListening = false;
  String _voiceStatusMessage = '마이크 버튼을 누르고 목적지를 말해줘.';

  // 실시간 채팅 상태
  final List<ChatMessage> _chatMessages = [];
  bool _isChatOpen = false;

  // 경로를 찾은 뒤 사용자에게 "안내해줄까?"를 물어 두고, 사용자가 동의("그래")할 때까지
  // 보행 내비게이션을 자동 활성화하지 않는다(채팅·음성 공통).
  V3RoutePlanResponse? _pendingNavPlan;
  Position? _pendingNavPosition;

  String get _wakeWord => widget.agentName;
  bool get _isLiveMode => widget.dataMode == 'live';

  @override
  void initState() {
    super.initState();
    _client = V3AgentApiClient(baseUrl: _apiBaseUrl);
    _cueService = AudioHapticCueService();
    _voiceGuideService = VoiceGuideService();
    _utteranceController = TextEditingController(
      text: '$_wakeWord, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?',
    );
    _bootstrap();
    // 위치는 첫 접속 시점에 한 번 요청해 둔다(경로 탐색 버튼을 누를 때가 아니라).
    _ensureLocation(forceRequest: true);
  }

  @override
  void dispose() {
    _liveRouteTimer?.cancel();
    _voiceGuideService.cancelListening();
    _utteranceController.dispose();
    _cueService.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _runGuarded(() async {
      final health = await _client.fetchHealth();
      final session = await _client.createSession(
        sessionId: _sessionId,
        wakeWord: _wakeWord,
      );
      setState(() {
        _healthStatus = health;
        _sessionState = session;
      });
    });
  }

  Future<void> _runGuarded(Future<void> Function() action) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      await action();
    } on V3ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
      await _cueService.playDing();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _refreshState() async {
    final state = await _client.fetchState(sessionId: _sessionId);
    setState(() {
      _sessionState = state;
    });
  }

  Future<void> _sendUtterance([String? utterance]) async {
    return _sendUtteranceFromSource(utterance: utterance, fromChat: false);
  }

  /// 채팅에서 보낸 메시지를 처리한다.
  Future<void> _sendChatMessage(String text) async {
    if (text.trim().isEmpty) return;
    await _sendUtteranceFromSource(utterance: text, fromChat: true);
  }

  Future<void> _toggleVoiceInput() async {
    if (_isBusy) return;
    if (_isLiveMode) {
      // 실제 API 모드: 수동 녹음 UI 대신 전체 화면 Live 음성 대화로 진입한다.
      await _openLiveVoice();
      return;
    }
    if (_isListening) {
      final recognizedWords = _voiceGuideService.lastRecognizedWords.trim();
      final message = await _voiceGuideService.stopListening();
      if (!mounted) return;
      setState(() {
        _isListening = false;
        _voiceStatusMessage = message;
      });
      if (recognizedWords.isNotEmpty) {
        await _submitVoiceUtterance(recognizedWords);
      }
      return;
    }

    await _cueService.playDing();
    final message = await _voiceGuideService.startListening(
      onResult: (recognizedWords) {
        if (!mounted) return;
        setState(() {
          _voiceStatusMessage = recognizedWords.isEmpty
              ? '목적지를 듣고 있어.'
              : '인식 중: $recognizedWords';
        });
      },
    );
    if (!mounted) return;
    final isListening = message == '목적지 입력을 기다리고 있습니다.';
    setState(() {
      _isListening = isListening;
      _voiceStatusMessage = message;
    });
  }

  Future<void> _submitVoiceUtterance(String recognizedWords) async {
    final utterance = recognizedWords.contains(_wakeWord)
        ? recognizedWords
        : '$_wakeWord, $recognizedWords';
    setState(() {
      _voiceStatusMessage = '경로를 탐색 중이야: $recognizedWords';
    });
    await _sendUtteranceFromSource(
      utterance: utterance,
      fromChat: false,
      logUserText: recognizedWords,
    );
    if (!mounted) return;
    setState(() {
      _voiceStatusMessage = _lastAgentResponse?.message ?? '음성 요청 처리를 마쳤어.';
    });
  }

  /// 전체 화면 Live 음성 대화 페이지를 연다(실제 API 모드 전용).
  Future<void> _openLiveVoice() async {
    unawaited(_cueService.prepareLiveGeneratedSpeech());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => LiveVoicePage(
          agentName: _wakeWord,
          processor: _processLiveUtterance,
          speak: _speakLiveOnly,
          stopAudio: () => _cueService.stopCue(),
          onExit: _onLiveVoiceExit,
        ),
      ),
    );
  }

  /// Live 음성 발화 1턴 처리: 길안내 동의 → 네비 전환, 그 외 → 에이전트 응답.
  Future<LiveProcessResult> _processLiveUtterance(
    String utterance, {
    void Function(String thought)? onThought,
  }) async {
    final text = utterance.trim();
    if (text.isEmpty) return const LiveProcessResult(spokenText: '');

    // 경로를 찾은 뒤 "안내해줄까?"에 대한 응답을 먼저 해석한다.
    if (_pendingNavPlan != null) {
      if (_isNavAffirmative(text)) {
        return const LiveProcessResult(
          spokenText: '좋아, 길 안내를 시작할게.',
          navigateNow: true,
        );
      }
      if (_isNavNegative(text)) {
        _pendingNavPlan = null;
        _pendingNavPosition = null;
        return const LiveProcessResult(
          spokenText: '알겠어. 안내는 시작하지 않을게. 다른 목적지를 말해도 돼.',
        );
      }
      _pendingNavPlan = null;
      _pendingNavPosition = null;
    }

    final shouldPlanRoute = _looksLikeRouteRequest(text);
    final preparation = shouldPlanRoute ? await _beginRoutePlanning() : null;
    try {
      final response = await _converseWithThoughts(
        text: text,
        originLat: preparation?.position?.latitude,
        originLng: preparation?.position?.longitude,
        onThought: onThought ?? (_) {},
      );
      // 종료 의사는 백엔드 Gemini가 자연어로 판별(END_CONVERSATION).
      if (response.intent == 'END_CONVERSATION') {
        return LiveProcessResult(
          spokenText: response.message,
          endSession: true,
        );
      }
      final state = await _client.fetchState(sessionId: _sessionId);
      final routePlan = response.routePlan;
      final hasNavPlan = routePlan?.recommendedPlan != null;
      if (mounted) {
        setState(() {
          _lastAgentResponse = response;
          _sessionState = state;
          if (routePlan != null) {
            _lastRoutePlan = routePlan;
            _lastRouteRecommendation = null;
            _lastArrivals = _arrivalsFromRoutePlan(routePlan);
          }
        });
      }
      if (hasNavPlan) {
        _pendingNavPlan = routePlan;
        _pendingNavPosition = preparation?.position;
        return LiveProcessResult(
          spokenText:
              "${response.message} 이 경로로 안내를 시작할까? '그래'라고 답하면 길 안내를 시작할게.",
        );
      }
      return LiveProcessResult(spokenText: response.message);
    } on V3ApiException catch (error) {
      return LiveProcessResult(spokenText: error.toString());
    } catch (_) {
      return const LiveProcessResult(
        spokenText: '지금은 답하기 어려워. 잠시 후에 다시 말해줄래?',
      );
    } finally {
      if (shouldPlanRoute && mounted) {
        setState(() => _isRoutePlanning = false);
      }
    }
  }

  /// Live 세션 종료: 대화 로그 병합 + (동의 시) 네비게이션 활성화.
  void _onLiveVoiceExit(
    List<LiveCaptionLine> sessionLog, {
    required bool navigated,
  }) {
    if (sessionLog.isNotEmpty && mounted) {
      setState(() {
        for (final line in sessionLog) {
          _chatMessages.add(ChatMessage(
            text: line.text,
            isUser: line.speaker == Speaker.user,
            timestamp: line.createdAt,
            source: 'voice',
          ));
        }
      });
    }
    if (navigated && _pendingNavPlan != null) {
      final plan = _pendingNavPlan!;
      final pos = _pendingNavPosition;
      _pendingNavPlan = null;
      _pendingNavPosition = null;
      unawaited(_activateLiveRoutePanel(plan, pos));
    }
  }

  Future<void> _sendUtteranceFromSource({
    String? utterance,
    required bool fromChat,
    String? logUserText,
  }) async {
    final text = (utterance ?? _utteranceController.text).trim();
    if (text.isEmpty) return;
    if (_isLiveMode) {
      unawaited(_cueService.prepareLiveGeneratedSpeech());
    }

    // 채팅·음성을 하나의 대화 로그로 통합 기록한다(사용자 발화).
    final userLogText = (logUserText ?? text).trim();
    if (userLogText.isNotEmpty) {
      setState(() {
        _chatMessages.add(ChatMessage(
          text: userLogText,
          isUser: true,
          timestamp: DateTime.now(),
          source: fromChat ? 'chat' : 'voice',
        ));
      });
    }

    // 경로를 찾은 뒤 "안내해줄까?"에 대한 사용자 응답을 먼저 해석한다.
    if (_pendingNavPlan != null) {
      if (_isNavAffirmative(text)) {
        final plan = _pendingNavPlan!;
        final pos = _pendingNavPosition;
        _pendingNavPlan = null;
        _pendingNavPosition = null;
        _addAgentLog('좋아, 길 안내를 시작할게.', fromChat: fromChat);
        await _speakAgentMessage('좋아, 길 안내를 시작할게.');
        await _activateLiveRoutePanel(plan, pos);
        return;
      }
      if (_isNavNegative(text)) {
        _pendingNavPlan = null;
        _pendingNavPosition = null;
        const cancelMsg = '알겠어. 안내는 시작하지 않을게. 다른 목적지를 말해도 돼.';
        _addAgentLog(cancelMsg, fromChat: fromChat);
        await _speakAgentMessage(cancelMsg);
        return;
      }
      // 동의·거절이 아니면 새 요청으로 보고 대기 상태를 해제한다.
      _pendingNavPlan = null;
      _pendingNavPosition = null;
    }

    final shouldPlanRoute = _looksLikeRouteRequest(text);
    final planningPreparation =
        shouldPlanRoute ? await _beginRoutePlanning() : null;

    try {
      await _runGuarded(() async {
        // 처리 중 단계별 '생각'을 회색 줄로 보여 주고, 최종 응답을 받는다.
        final thinkingMessages = <ChatMessage>[];
        final response = await _converseWithThoughts(
          text: text,
          originLat: planningPreparation?.position?.latitude,
          originLng: planningPreparation?.position?.longitude,
          onThought: (thought) {
            final msg = ChatMessage(
              text: thought,
              isUser: false,
              timestamp: DateTime.now(),
              source: fromChat ? 'chat' : 'voice',
              kind: 'thinking',
            );
            thinkingMessages.add(msg);
            if (mounted) setState(() => _chatMessages.add(msg));
          },
        );
        // 답변이 준비되면 임시 생각줄은 정리한다.
        if (thinkingMessages.isNotEmpty && mounted) {
          setState(() =>
              _chatMessages.removeWhere((m) => thinkingMessages.contains(m)));
        }
        final state = await _client.fetchState(sessionId: _sessionId);
        V3RouteRecommendResponse? recommendation;
        V3RoutePlanResponse? routePlan = response.routePlan;
        String? planningStatus;
        if (shouldPlanRoute && routePlan != null) {
          planningStatus = _completedRoutePlanStatus(
            preparation: planningPreparation!,
            routePlan: routePlan,
          );
        } else if (shouldPlanRoute && state.selectedDestination != null) {
          recommendation = await _client.routeRecommend(
            destination: state.selectedDestination!,
            originLat: planningPreparation?.position?.latitude,
            originLng: planningPreparation?.position?.longitude,
            mode: widget.dataMode,
          );
          planningStatus = _completedPlanningStatus(
            preparation: planningPreparation!,
            recommendation: recommendation,
          );
        }
        // 실제 API 모드에서 버스 경로를 찾으면 바로 안내를 켜지 않고,
        // 사용자에게 안내 시작 의사를 물어본다.
        final hasNavPlan = routePlan?.recommendedPlan != null;
        final askConsent = _isLiveMode && hasNavPlan;
        final agentText = askConsent
            ? "${response.message} 이 경로로 안내를 시작할까? '그래'라고 답하면 길 안내를 시작할게."
            : response.message;
        setState(() {
          _lastAgentResponse = response;
          _isAgentTraceExpanded = false;
          _sessionState = state;
          if (routePlan != null) {
            _lastRoutePlan = routePlan;
            _lastRouteRecommendation = null;
            _lastArrivals = _arrivalsFromRoutePlan(routePlan);
            _routePlanningStatus = planningStatus;
          }
          if (recommendation != null) {
            _lastRouteRecommendation = recommendation;
            _routePlanningStatus = planningStatus;
          }
          // 채팅·음성 구분 없이 에이전트 응답을 통합 로그에 추가한다.
          _chatMessages.add(ChatMessage(
            text: agentText,
            isUser: false,
            timestamp: DateTime.now(),
            source: fromChat ? 'chat' : 'voice',
          ));
        });
        await _cueService.playCue(response.cue, fallbackMessage: agentText);
        if (response.cue.isNone && response.ttsMode != 'NONE') {
          await _speakAgentMessage(
            agentText,
            forceLocal: response.ttsMode == 'SAFETY_LOCAL',
          );
        }
        if (askConsent) {
          // 동의를 기다리는 동안에는 내비게이션을 활성화하지 않는다.
          _pendingNavPlan = routePlan;
          _pendingNavPosition = planningPreparation?.position;
        } else if (hasNavPlan) {
          unawaited(_activateLiveRoutePanel(
              routePlan!, planningPreparation?.position));
        } else if (shouldPlanRoute) {
          _stopLiveRoutePolling(clearStatus: true);
        }
      });
    } finally {
      if (shouldPlanRoute && mounted) {
        setState(() {
          _isRoutePlanning = false;
        });
      }
    }
  }

  void _addAgentLog(String text, {required bool fromChat}) {
    if (!mounted) return;
    setState(() {
      _chatMessages.add(ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
        source: fromChat ? 'chat' : 'voice',
      ));
    });
  }

  String _consentCompact(String text) {
    var compact = text.replaceAll(_wakeWord, '');
    compact = compact.replaceAll(RegExp(r'[\s,.!?~]+'), '');
    return compact;
  }

  bool _isNavAffirmative(String text) {
    final compact = _consentCompact(text);
    const yes = [
      '그래',
      '응',
      '어',
      '네',
      '예',
      'ㅇㅇ',
      '좋아',
      '좋아요',
      '시작',
      '안내해줘',
      '안내시작',
      '해줘',
      '부탁해',
      '가자',
      '오케이',
      'ok',
      'go',
      '출발',
      '응그래',
      '그래그래',
      '안내',
      '시작해',
      '시작해줘',
      '맞아',
      '맞아요',
      '그래줘',
    ];
    if (yes.contains(compact)) return true;
    // 긴 새 목적지 문장을 동의로 오인하지 않도록 짧은 발화만 부분 일치 허용.
    if (compact.length <= 6) return yes.any(compact.contains);
    return false;
  }

  bool _isNavNegative(String text) {
    final compact = _consentCompact(text);
    const no = ['아니', '아니야', 'ㄴㄴ', '노', 'no', '나중에', '취소', '안해', '괜찮아'];
    if (no.contains(compact)) return true;
    if (compact.length <= 6) return no.any(compact.contains);
    return false;
  }

  /// converse를 WS 스트리밍으로 호출해 처리 단계 'thought'를 실시간 전달하고,
  /// 최종 응답을 돌려준다. 웹이 아니거나 스트림 실패 시 일반 converse로 폴백한다.
  Future<V3AgentResponse> _converseWithThoughts({
    required String text,
    required double? originLat,
    required double? originLng,
    required void Function(String thought) onThought,
  }) async {
    try {
      V3AgentResponse? finalResponse;
      final stream = _client
          .converseLive(
            sessionId: _sessionId,
            wakeWord: _wakeWord,
            utterance: text,
            mode: widget.dataMode,
            originLat: originLat,
            originLng: originLng,
          )
          .timeout(const Duration(seconds: 45));
      await for (final event in stream) {
        if (event is ConverseThought) {
          onThought(event.text);
        } else if (event is ConverseFinal) {
          finalResponse = event.response;
        }
      }
      if (finalResponse != null) return finalResponse;
    } catch (_) {
      // 스트리밍 미지원/실패 → 일반 REST converse로 폴백.
    }
    return _client.converse(
      sessionId: _sessionId,
      wakeWord: _wakeWord,
      utterance: text,
      mode: widget.dataMode,
      originLat: originLat,
      originLng: originLng,
    );
  }

  /// Live 음성 대화 전용 발화: Gemini Live 스트리밍만 사용하고 실패/중단(barge-in) 시
  /// WAV 폴백으로 다시 말하지 않는다(중복 음성·끼어들기 깨짐 방지).
  Future<void> _speakLiveOnly(String message, {VoidCallback? onStart}) async {
    if (message.trim().isEmpty) return;
    try {
      await _cueService.playLiveGeneratedSpeech(
        baseUrl: _apiBaseUrl,
        text: message,
        onFirstAudio: onStart,
      );
    } catch (_) {
      // 스트리밍 실패/중단은 조용히 넘어간다(자막은 이미 표시됨).
    }
  }

  Future<void> _speakAgentMessage(String message,
      {bool forceLocal = false}) async {
    if (_isLiveMode) {
      try {
        await _cueService.playLiveGeneratedSpeech(
          baseUrl: _apiBaseUrl,
          text: message,
        );
        return;
      } catch (_) {
        // Fall back to the existing WAV endpoint if streaming is unavailable.
      }
    }

    if (forceLocal) {
      await _cueService.speakLocal(message);
      return;
    }

    try {
      final audioBytes = await _client.synthesizeSpeech(text: message);
      await _cueService.playGeneratedSpeech(audioBytes);
      return;
    } on V3ApiException {
      await _cueService.playDing();
    }
  }

  Future<void> _routeRecommend(String destination) async {
    if (_isBusy) return;
    final preparation = await _beginRoutePlanning();
    try {
      await _runGuarded(() async {
        final routePlan = await _client.routePlan(
          q: destination,
          originLat: preparation.position?.latitude,
          originLng: preparation.position?.longitude,
          mode: widget.dataMode,
        );

        V3RouteRecommendResponse? recommendation;
        try {
          recommendation = await _client.routeRecommend(
            destination: destination,
            originLat: preparation.position?.latitude,
            originLng: preparation.position?.longitude,
            mode: widget.dataMode,
          );
        } on V3ApiException {
          // 임의 장소명은 새 RoutePlan만으로도 표시 가능하다.
        }

        setState(() {
          _lastRoutePlan = routePlan;
          _lastRouteRecommendation = recommendation;
          _lastArrivals = _arrivalsFromRoutePlan(routePlan);
          _routePlanningStatus = _completedRoutePlanStatus(
            preparation: preparation,
            routePlan: routePlan,
          );
        });
        if (routePlan.recommendedPlan != null) {
          await _activateLiveRoutePanel(routePlan, preparation.position);
        } else {
          _stopLiveRoutePolling(clearStatus: true);
        }
        final spokenGuidance = routePlan.agentMessage ??
            routePlan.recommendedPlan?.boardingInstruction ??
            routePlan.question;
        if (spokenGuidance != null && spokenGuidance.isNotEmpty) {
          await _speakAgentMessage(spokenGuidance, forceLocal: true);
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRoutePlanning = false;
        });
      }
    }
  }

  /// 첫 접속 시(혹은 사용자가 다시 시도할 때) 위치 권한을 요청하고 실제 위치를 캐시한다.
  /// 경로 탐색 시점이 아니라 진입 시점에 호출해 사용자 위치를 미리 확보한다.
  Future<void> _ensureLocation({bool forceRequest = false}) async {
    if (_resolvingLocation) return;
    if (_cachedPosition != null && !forceRequest) return;
    _resolvingLocation = true;
    try {
      final position = await _currentPosition();
      if (!mounted) return;
      setState(() {
        _cachedPosition = position;
        _locationDenied = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 실제 위치를 못 받으면 사창사거리 같은 가짜 좌표를 만들지 않는다.
      // 위치 없이 진행하고, 사용자가 권한을 켤 수 있도록 안내 배너만 띄운다.
      setState(() {
        _locationDenied = true;
      });
    } finally {
      _resolvingLocation = false;
    }
  }

  Future<_RoutePlanningPreparation> _beginRoutePlanning() async {
    _liveRouteTimer?.cancel();
    _liveRouteTimer = null;
    setState(() {
      _isRoutePlanning = true;
      _routePlanningStatus = _routePlanningMessage;
      _liveRoutePanelVisible = false;
      _liveStatus = null;
      _liveRouteError = null;
      // 새 목적지 탐색이 시작되면 '길찾기 중지' 상태를 해제한다.
      _navStopped = false;
    });
    await _cueService.playDing();

    // 진입 시 확보한 실제 위치를 우선 사용한다. 없으면 한 번 더 시도한다.
    if (_cachedPosition == null) {
      await _ensureLocation(forceRequest: true);
    }
    final position = _cachedPosition;
    if (position != null) {
      return _RoutePlanningPreparation(position: position);
    }
    // 실제 위치가 없으면 가짜 좌표(사창사거리)를 보내지 않고 위치 없이 진행한다.
    return const _RoutePlanningPreparation();
  }

  Future<void> _activateLiveRoutePanel(
    V3RoutePlanResponse routePlan,
    Position? position,
  ) async {
    final plan = routePlan.recommendedPlan;
    if (plan == null || plan.segments.isEmpty) {
      _stopLiveRoutePolling(clearStatus: true);
      return;
    }
    // 새 경로가 확정되면 '길찾기 중지' 상태를 해제하고 실시간 추적을 시작한다.
    _liveRouteTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _navStopped = false;
      _liveRoutePanelVisible = true;
      _liveStatus = null;
      _liveRouteError = null;
      _lastRoutePosition = position ?? _cachedPosition;
    });
    await _refreshNavStatus();
    if (!mounted || !_liveRoutePanelVisible || _navStopped) return;
    // 30초 단위 최신화. 서버의 더 짧은 캐시가 같은 경계의 이전 응답 재사용을 막는다.
    _liveRouteTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isLiveRouteLoading && _liveRoutePanelVisible && !_navStopped) {
        unawaited(_refreshNavStatus());
      }
    });
  }

  Future<void> _refreshNavStatus() async {
    if (_isLiveRouteLoading || _navStopped) return;
    final plan = _lastRoutePlan?.recommendedPlan;
    if (plan == null || plan.segments.isEmpty) return;
    final segment = plan.segments.first;
    setState(() {
      _isLiveRouteLoading = true;
    });
    // 30초 폴링마다 실제 위치도 갱신한다. 실패하면 마지막으로 확인한 좌표를 유지한다.
    var userPos = _cachedPosition ?? _lastRoutePosition;
    try {
      final refreshedPosition = await _currentPosition();
      if (mounted) {
        _cachedPosition = refreshedPosition;
        _lastRoutePosition = refreshedPosition;
        userPos = refreshedPosition;
      }
    } catch (_) {
      // 위치 갱신 실패는 마지막 좌표로 계속 안내한다.
    }
    try {
      final destination = _lastRoutePlan?.destination?.topCandidate;
      final status = await _client.liveStatus(
        routeNo: segment.routeNo,
        routeId: segment.routeId,
        boardStopId: segment.boardStop.stopId,
        alightStopId: segment.alightStop.stopId,
        sessionId: _sessionId,
        userLat: userPos?.latitude,
        userLng: userPos?.longitude,
        boardLat: segment.boardStop.latitude,
        boardLng: segment.boardStop.longitude,
        alightLat: segment.alightStop.latitude,
        alightLng: segment.alightStop.longitude,
        destLat: destination?.latitude,
        destLng: destination?.longitude,
        boardStopName: segment.boardStop.stopName,
        alightStopName: segment.alightStop.stopName,
        destName: plan.destinationName,
        mode: widget.dataMode,
      );
      if (!mounted || !_liveRoutePanelVisible || _navStopped) return;
      setState(() {
        _liveStatus = status;
        _liveRouteError = null;
      });
    } on V3ApiException catch (error) {
      if (!mounted || !_liveRoutePanelVisible || _navStopped) return;
      // 실패해도 마지막 갱신 결과는 유지하고 경고만 표시한다.
      setState(() {
        _liveRouteError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLiveRouteLoading = false;
        });
      }
    }
  }

  /// '길찾기 중지': 지도/실시간 패널을 끄고 30초 폴링을 멈춘다.
  /// 새 목적지를 말하면 _activateLiveRoutePanel에서 다시 시작된다.
  void _stopNavigation() {
    _liveRouteTimer?.cancel();
    _liveRouteTimer = null;
    if (!mounted) return;
    setState(() {
      _navStopped = true;
      _liveRoutePanelVisible = false;
      _isLiveRouteLoading = false;
      _liveStatus = null;
      _liveRouteError = null;
      _routePlanningStatus = null;
      _lastRoutePlan = null;
      _lastArrivals = null;
    });
    unawaited(_cueService.stopCue());
  }

  void _stopLiveRoutePolling({bool clearStatus = false}) {
    _liveRouteTimer?.cancel();
    _liveRouteTimer = null;
    if (!mounted) return;
    setState(() {
      _liveRoutePanelVisible = false;
      _isLiveRouteLoading = false;
      if (clearStatus) {
        _liveStatus = null;
        _liveRouteError = null;
        _lastRoutePosition = null;
      }
    });
  }

  String _completedRoutePlanStatus({
    required _RoutePlanningPreparation preparation,
    required V3RoutePlanResponse routePlan,
  }) {
    if (routePlan.recommendedPlan == null) {
      return routePlan.question ?? '직통 또는 1회 환승 경로를 찾지 못했습니다.';
    }
    final plan = routePlan.recommendedPlan!;
    final locationLabel =
        preparation.position == null ? '현재 위치 없이' : '현재 위치 기준으로';
    final typeLabel = plan.type == 'DIRECT' ? '직통' : '1회 환승';
    return '$locationLabel $typeLabel 경로 ${routePlan.plans.length}개를 계산했습니다. 추천 점수 ${plan.score.toStringAsFixed(1)}점.';
  }

  String _completedPlanningStatus({
    required _RoutePlanningPreparation preparation,
    required V3RouteRecommendResponse recommendation,
  }) {
    if (preparation.position == null) {
      return '현재 위치를 사용할 수 없어 검증된 목적지 후보만 조회했습니다.';
    }
    if (!recommendation.usedGemini) {
      return '현재 위치는 전달했지만 Pro 응답을 사용할 수 없어 검증된 후보만 표시했습니다.';
    }
    if (!recommendation.mapsGrounded) {
      return 'Google Maps 위치 증빙을 확보하지 못해 위치 기반 최적 경로는 확정하지 않았습니다.';
    }
    return '현재 위치, Google Maps와 ${recommendation.planningDataSource ?? '검증된'} 버스 도착정보를 기준으로 경로를 계산했습니다.';
  }

  bool _looksLikeRouteRequest(String utterance) {
    final compact = utterance.replaceAll(' ', '');
    return utterance.contains('가야') ||
        utterance.contains('가고 싶') ||
        compact.contains('가고싶') ||
        utterance.contains('가자') ||
        utterance.contains('어떻게 가') ||
        utterance.contains('몇 번') ||
        compact.contains('몇번') ||
        utterance.contains('바꿔') ||
        utterance.contains('변경') ||
        utterance.contains('아니라') ||
        utterance.contains('맞아') ||
        utterance.contains('첫 번째') ||
        utterance.contains('두 번째') ||
        compact.contains('첫번째') ||
        compact.contains('두번째');
  }

  Future<Position> _currentPosition() async {
    // 웹: 관대한 옵션의 raw navigator.geolocation을 먼저 시도한다.
    // (인앱 브라우저에서 geolocator의 엄격한 호출이 실패해도 maximumAge 캐시로
    //  좌표를 받을 수 있다.)
    if (kIsWeb) {
      final coords = await getWebCoords();
      if (coords != null) {
        return Position(
          latitude: coords.latitude,
          longitude: coords.longitude,
          timestamp: DateTime.now(),
          accuracy: coords.accuracy,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
      }
    }

    // 웹 브라우저에서는 isLocationServiceEnabled()가 권한이 있어도 false를 줄 수 있어
    // (그래서 위치를 제공했는데도 데모 배너가 떴다) 네이티브에서만 이 사전 점검을 한다.
    if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission was denied.');
    }

    // 1차: 고정확도로 충분한 시간을 준다. 카카오톡 같은 인앱 브라우저는
    // enableHighAccuracy=true 일 때만 좌표를 주는 경우가 있다.
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
    } catch (_) {
      // 2차: 마지막으로 알려진 위치라도 재사용(인앱 브라우저 지연/실패 대비).
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return last;
      } catch (_) {
        // 웹 등 미지원 환경에서는 무시하고 마지막 재시도로 넘어간다.
      }
      // 3차: 정확도를 낮춰 빠르게 한 번 더 시도.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
    }
  }

  Future<void> _refreshArrivals() async {
    await _runGuarded(() async {
      final state = _sessionState;
      final segments = _lastRoutePlan?.recommendedPlan?.segments;
      final firstSegment =
          segments == null || segments.isEmpty ? null : segments.first;
      final stopId = firstSegment?.boardStop.stopId ?? state?.selectedStopId;
      final routeNo = firstSegment?.routeNo ?? state?.selectedRouteNo;
      if (stopId == null || routeNo == null) {
        throw const V3ApiException('먼저 목적지 경로를 선택해줘.');
      }
      final arrivals = await _client.arrivals(
          stopId: stopId, routeNo: routeNo, mode: widget.dataMode);
      setState(() {
        _lastArrivals = arrivals;
      });
    });
  }

  V3BusArrivalsResponse? _arrivalsFromRoutePlan(V3RoutePlanResponse routePlan) {
    final segments = routePlan.recommendedPlan?.segments;
    if (segments == null || segments.isEmpty) return null;
    final segment = segments.first;
    return V3BusArrivalsResponse(
      stopId: segment.boardStop.stopId,
      routeNo: segment.routeNo,
      arrivals: segment.arrivals,
      fallbackSource: segment.arrivalSource,
      serviceStatus: segment.serviceStatus,
    );
  }

  Future<void> _startGuidance() async {
    await _sendUtterance('응, 선택한 경로로 안내해줘.');
  }

  Future<void> _mockGeofence(String event) async {
    await _runGuarded(() async {
      final response =
          await _client.mockGeofence(sessionId: _sessionId, event: event);
      final state = await _client.fetchState(sessionId: _sessionId);
      setState(() {
        _latestGeofenceMessage = response.message;
        _sessionState = state;
      });
      await _cueService.playCue(response.cue,
          fallbackMessage: response.message);
    });
  }

  Future<void> _mockBeacons(List<V3BeaconSignal> beacons) async {
    await _runGuarded(() async {
      final state = _sessionState;
      final response = await _client.mockBeacons(
        sessionId: _sessionId,
        targetBusId: state?.targetBusId ?? 'BUS_2',
        targetRouteNo: state?.selectedRouteNo ?? '502',
        beacons: beacons,
      );
      final refreshedState = await _client.fetchState(sessionId: _sessionId);
      setState(() {
        _lastBeaconDecision = response;
        _sessionState = refreshedState;
      });
      await _cueService.playCue(response.cue,
          fallbackMessage: response.message);
    });
  }

  Future<void> _mockBusPassed() async {
    await _runGuarded(() async {
      final response = await _client.mockBusEvent(
          sessionId: _sessionId, event: 'BUS_PASSED');
      final state = await _client.fetchState(sessionId: _sessionId);
      setState(() {
        _latestGeofenceMessage = response.message;
        _sessionState = state;
      });
      await _cueService.playCue(response.cue,
          fallbackMessage: response.message);
    });
  }

  Future<void> _resetSession() async {
    await _runGuarded(() async {
      await _cueService.stopCue();
      final state = await _client.resetSession(sessionId: _sessionId);
      _liveRouteTimer?.cancel();
      _liveRouteTimer = null;
      setState(() {
        _sessionState = state;
        _lastAgentResponse = null;
        _lastRouteRecommendation = null;
        _lastRoutePlan = null;
        _lastArrivals = null;
        _lastBeaconDecision = null;
        _latestGeofenceMessage = null;
        _routePlanningStatus = null;
        _liveRoutePanelVisible = false;
        _navStopped = false;
        _liveStatus = null;
        _liveRouteError = null;
        _lastRoutePosition = null;
        _isAgentTraceExpanded = false;
      });
    });
  }

  void _toggleMockHeadTracking(bool value) {
    setState(() {
      _useMockHeadTracking = value;
      _headTracking = value
          ? HeadTrackingDebugSnapshot.mock(yaw: 12.5, pitch: -3.2, roll: 1.8)
          : HeadTrackingDebugSnapshot.disabled();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _sessionState;
    final lastMessage = _lastAgentResponse?.message ??
        _latestGeofenceMessage ??
        _lastBeaconDecision?.message ??
        'V3 버스 탑승 보조 에이전트가 대기 중이야.';

    return Scaffold(
      appBar: AppBar(
        title: Text(_isLiveMode ? '모비 실시간 버스 안내' : 'V3 버스 탑승 보조'),
        actions: [
          IconButton(
            tooltip: '초기 화면으로',
            onPressed: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
              widget.onReturnToModeSelection();
            },
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: '상태 새로고침',
            onPressed: _isBusy ? null : () => _runGuarded(_refreshState),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '세션 초기화',
            onPressed: _isBusy ? null : _resetSession,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      // Mock 화면은 기존 채팅 FAB를 유지한다. 실제 API 화면은 질문 수단 카드에 통합한다.
      floatingActionButton: _isLiveMode || _isChatOpen
          ? null
          : FloatingActionButton.extended(
              onPressed: () => setState(() => _isChatOpen = true),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('채팅'),
              tooltip: '실시간 채팅 열기',
            ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeroStatusCard(
                    isBusy: _isBusy,
                    stateLabel: state?.state ?? 'LOADING',
                    destination: state?.selectedDestination,
                    routeNo: state?.selectedRouteNo,
                    stopName: state?.selectedStopName,
                    targetBusId: state?.targetBusId,
                    message: lastMessage,
                    errorMessage: _errorMessage,
                  ),
                  if (_isLiveMode) ...[
                    const SizedBox(height: 12),
                    _LiveQuestionMethodsCard(
                      isBusy: _isBusy,
                      isListening: _isListening,
                      voiceStatusMessage: _voiceStatusMessage,
                      onOpenChat: () => setState(() => _isChatOpen = true),
                      onToggleVoice: _toggleVoiceInput,
                    ),
                    if (_chatMessages.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _ConversationLogCard(messages: _chatMessages),
                    ],
                  ],
                  if (_locationDenied) ...[
                    const SizedBox(height: 12),
                    _LocationNeededBanner(
                      onRetry: _isBusy
                          ? null
                          : () => _ensureLocation(forceRequest: true),
                    ),
                  ],
                  if (_liveRoutePanelVisible && !_navStopped) ...[
                    const SizedBox(height: 12),
                    _RealtimeNavCard(
                      status: _liveStatus,
                      routePlan: _lastRoutePlan,
                      userPosition: _cachedPosition ?? _lastRoutePosition,
                      isLoading: _isLiveRouteLoading,
                      errorMessage: _liveRouteError,
                      onStop: _stopNavigation,
                    ),
                  ],
                  if (_navStopped) ...[
                    const SizedBox(height: 12),
                    _NavStoppedNotice(),
                  ],
                  if (!_isLiveMode) ...[
                    const SizedBox(height: 12),
                    _ArrivalCard(
                      routeRecommendation: _lastRouteRecommendation,
                      routePlan: _lastRoutePlan,
                      routePlanningStatus: _routePlanningStatus,
                      arrivals: _lastArrivals,
                      onRecommendSachang: () => _routeRecommend('사창사거리'),
                      onRecommendHospital: () => _routeRecommend('충북대병원'),
                      onRecommendSangdang: () => _routeRecommend('상당산성'),
                      onRefreshArrivals: _refreshArrivals,
                      onChooseDestination: (candidate) =>
                          _sendUtterance(candidate),
                      onStartGuidance: _startGuidance,
                      isBusy: _isBusy,
                    ),
                    const SizedBox(height: 12),
                    _CombinedChatControlCard(
                      controller: _utteranceController,
                      isBusy: _isBusy,
                      wakeWord: _wakeWord,
                      onSend: () => _sendUtterance(),
                      onQuickAction: (text) => _sendUtterance(text),
                    ),
                    const SizedBox(height: 12),
                    _DebugExpansionPanel(
                      isBusy: _isBusy,
                      dataMode: widget.dataMode,
                      traceId: _lastAgentResponse?.traceId,
                      traceEvents: _lastAgentResponse?.trace,
                      isAgentTraceExpanded: _isAgentTraceExpanded,
                      onToggleTrace: () => setState(() {
                        _isAgentTraceExpanded = !_isAgentTraceExpanded;
                      }),
                      onArrivedAtStop: () => _mockGeofence('ARRIVED_AT_STOP'),
                      onLeftWaitingArea: () =>
                          _mockGeofence('LEFT_WAITING_AREA'),
                      onDangerZone: () => _mockGeofence('DANGER_ZONE'),
                      onReturnedToStop: () => _mockGeofence('RETURNED_TO_STOP'),
                      onWrongBusNear: () => _mockBeacons(
                        const <V3BeaconSignal>[
                          V3BeaconSignal(
                              busId: 'BUS_1',
                              routeNo: '511',
                              rssi: -50,
                              distanceMeters: 1.8),
                          V3BeaconSignal(
                              busId: 'BUS_2',
                              routeNo: '502',
                              rssi: -70,
                              distanceMeters: 6.0),
                        ],
                      ),
                      onTargetBusMid: () => _mockBeacons(const <V3BeaconSignal>[
                        V3BeaconSignal(
                            busId: 'BUS_2',
                            routeNo: '502',
                            rssi: -70,
                            distanceMeters: 6.0),
                      ]),
                      onTargetBusNear: () =>
                          _mockBeacons(const <V3BeaconSignal>[
                        V3BeaconSignal(
                            busId: 'BUS_2',
                            routeNo: '502',
                            rssi: -52,
                            distanceMeters: 1.4),
                      ]),
                      onNoBeacon: () => _mockBeacons(const <V3BeaconSignal>[]),
                      onBusPassed: _mockBusPassed,
                      onRefreshArrivals: _refreshArrivals,
                      latestBeaconDecision: _lastBeaconDecision,
                      latestGeofenceMessage: _latestGeofenceMessage,
                      headTracking: _headTracking,
                      useMockHeadTracking: _useMockHeadTracking,
                      onToggleMockHeadTracking: _toggleMockHeadTracking,
                      apiBaseUrl: _apiBaseUrl,
                      healthMessage: _healthStatus?.message ?? '확인 전',
                      sessionState: _sessionState,
                      lastAgentResponse: _lastAgentResponse,
                      lastArrivals: _lastArrivals,
                      activeCueType: _cueService.activeCueType,
                    ),
                  ],
                ],
              ),
            ),
            if (_isRoutePlanning)
              const Positioned.fill(
                child: _RoutePlanningOverlay(message: _routePlanningMessage),
              ),
            // 실시간 채팅 오버레이
            if (_isChatOpen)
              Positioned.fill(
                child: ChatOverlay(
                  messages: _chatMessages,
                  isBusy: _isBusy,
                  onSendMessage: _sendChatMessage,
                  onClose: () => setState(() => _isChatOpen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AgentTraceCard extends StatelessWidget {
  const _AgentTraceCard({
    required this.traceId,
    required this.events,
    required this.expanded,
    required this.onToggle,
  });

  final String? traceId;
  final List<V3AgentTraceEvent> events;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context)
          .colorScheme
          .primaryContainer
          .withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '모비가 실제 데이터를 확인했어',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onToggle,
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: Text(expanded ? '검증 과정 접기' : '검증 과정 보기'),
                ),
              ],
            ),
            Text('${events.length}개 단계의 확인 기록이 있어.'),
            if (expanded) ...[
              if (traceId != null) ...[
                const SizedBox(height: 4),
                Text(
                  'traceId: $traceId',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 10),
              for (final event in events) _AgentTraceTimelineItem(event: event),
            ],
          ],
        ),
      ),
    );
  }
}

class _AgentTraceTimelineItem extends StatelessWidget {
  const _AgentTraceTimelineItem({required this.event});

  final V3AgentTraceEvent event;

  @override
  Widget build(BuildContext context) {
    final payload = sanitizeAgentTracePayloadForDisplay(event.safePayload);
    final providerOperation = <String>[
      if (event.provider != null) event.provider!,
      if (event.operation != null) event.operation!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              _agentTraceIcon(event.status),
              size: 20,
              color: _agentTraceColor(context, event.status),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${event.step}. ${event.title}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(event.summary),
                if (providerOperation.isNotEmpty)
                  Text(
                    providerOperation,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (event.durationMs != null)
                  Text(
                    '${event.durationMs}ms',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (payload.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(payload),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
                if (event.warning != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '주의: ${event.warning}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _agentTraceIcon(String status) {
  return switch (status) {
    'DONE' => Icons.check_circle,
    'FAILED' => Icons.error,
    'SKIPPED' => Icons.remove_circle_outline,
    'RUNNING' => Icons.pending,
    _ => Icons.schedule,
  };
}

Color _agentTraceColor(BuildContext context, String status) {
  return switch (status) {
    'DONE' => Colors.green,
    'FAILED' => Theme.of(context).colorScheme.error,
    'SKIPPED' => Colors.grey,
    'RUNNING' => Colors.orange,
    _ => Colors.blueGrey,
  };
}

class _HeroStatusCard extends StatelessWidget {
  const _HeroStatusCard({
    required this.isBusy,
    required this.stateLabel,
    required this.message,
    this.destination,
    this.routeNo,
    this.stopName,
    this.targetBusId,
    this.errorMessage,
  });

  final bool isBusy;
  final String stateLabel;
  final String message;
  final String? destination;
  final String? routeNo;
  final String? stopName;
  final String? targetBusId;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isBusy ? Icons.hourglass_top : Icons.directions_bus),
                const SizedBox(width: 8),
                Text(
                  '상태: $stateLabel',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(message, style: Theme.of(context).textTheme.bodyLarge),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(label: '목적지', value: destination ?? '-'),
                _InfoChip(label: '노선', value: routeNo ?? '-'),
                _InfoChip(label: '정류장', value: stopName ?? '-'),
                _InfoChip(label: '타깃 버스', value: targetBusId ?? '-'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label: $value'));
  }
}

class _LocationNeededBanner extends StatelessWidget {
  const _LocationNeededBanner({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '현재 위치를 확인하지 못했어. 정확한 경로 안내에는 위치가 필요해.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              '• 카카오톡·인스타그램 같은 앱 안의 브라우저는 위치를 막는 경우가 많아. '
              '우측 상단 메뉴에서 Safari/Chrome 같은 기본 브라우저로 열면 위치가 잡혀.\n'
              '• 기본 브라우저에서는 주소창 옆 위치 아이콘에서 접근을 허용해줘.',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.my_location),
                label: const Text('위치 권한 다시 시도'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 채팅·음성 발화를 하나로 합쳐 보여 주는 접이식 대화 로그.
class _ConversationLogCard extends StatelessWidget {
  const _ConversationLogCard({required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 최신 대화가 위로 오도록 역순 정렬해서 보여 준다.
    final ordered = messages.reversed.toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(Icons.forum_outlined),
        title: const Text(
          '대화 로그',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('채팅·음성 통합 · ${messages.length}개'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.separated(
              shrinkWrap: true,
              reverse: true,
              itemCount: ordered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final m = ordered[index];
                if (m.isThinking) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      m.text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  );
                }
                final isUser = m.isUser;
                final sourceIcon =
                    m.source == 'voice' ? Icons.mic : Icons.chat_bubble_outline;
                final who =
                    isUser ? (m.source == 'voice' ? '나 (음성)' : '나 (채팅)') : '모비';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isUser
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(isUser ? sourceIcon : Icons.smart_toy_outlined,
                                size: 14),
                            const SizedBox(width: 4),
                            Text(
                              who,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _hhmm(m.timestamp),
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(m.text),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveQuestionMethodsCard extends StatelessWidget {
  const _LiveQuestionMethodsCard({
    required this.isBusy,
    required this.isListening,
    required this.voiceStatusMessage,
    required this.onOpenChat,
    required this.onToggleVoice,
  });

  final bool isBusy;
  final bool isListening;
  final String voiceStatusMessage;
  final VoidCallback onOpenChat;
  final VoidCallback onToggleVoice;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.primaryContainer.withValues(alpha: 0.36),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '어디로 갈까요?',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 6),
            const Text('채팅 또는 음성으로 목적지를 알려줘. 모비가 실제 API로 경로를 탐색할게.'),
            const SizedBox(height: 14),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: isBusy ? null : onOpenChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text(
                  '채팅으로 질문하기',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: isBusy ? null : onToggleVoice,
                icon: Icon(isListening ? Icons.stop_circle : Icons.mic),
                label: Text(
                  isListening ? '음성 인식 종료하고 질문하기' : '음성으로 질문하기',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isListening ? Icons.hearing : Icons.info_outline,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(voiceStatusMessage)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NavStoppedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '경로 안내를 취소했어. 보행 내비게이션과 탑승 버스 상세 정보 갱신을 종료했어.',
        ),
      ),
    );
  }
}

class _RealtimeNavCard extends StatelessWidget {
  const _RealtimeNavCard({
    required this.status,
    required this.routePlan,
    required this.userPosition,
    required this.isLoading,
    required this.onStop,
    this.errorMessage,
  });

  final V3LiveStatus? status;
  final V3RoutePlanResponse? routePlan;
  final Position? userPosition;
  final bool isLoading;
  final VoidCallback onStop;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final plan = routePlan?.recommendedPlan;
    final segment =
        plan?.segments.isNotEmpty == true ? plan!.segments.first : null;
    final s = status;
    final firstArrival =
        (s != null && s.arrivals.isNotEmpty) ? s.arrivals.first : null;
    final serviceStatus = s?.serviceStatus ?? segment?.serviceStatus;
    final walking = s?.walkingRouteToBoardStop;
    final egressWalking = s?.walkingRouteFromAlightStop;
    final walkToBoardMinutes = _walkingMinutes(walking);
    final busEtaMinutes = firstArrival?.arrivalMinutes;
    final rideMinutes = segment?.estimatedMinutes;
    final walkFromAlightMinutes = _walkingMinutes(egressWalking);
    final totalMinutes = _journeyTotalMinutes(
      walkToBoardMinutes: walkToBoardMinutes,
      busEtaMinutes: busEtaMinutes,
      rideMinutes: rideMinutes,
      walkFromAlightMinutes: walkFromAlightMinutes,
      fallback: plan?.totalEstimatedMinutes,
    );

    final destName =
        plan?.destinationName ?? segment?.alightStop.stopName ?? '목적지';
    final routeNo = segment?.routeNo ?? s?.routeNo ?? '미확인';
    final boardName =
        s?.selectedBoardStop?.stopName ?? segment?.boardStop.stopName ?? '미확인';
    final alightName = s?.selectedAlightStop?.stopName ??
        segment?.alightStop.stopName ??
        '미확인';
    final congestion = _congestionLabel(s?.congestion);
    final lowFloor = firstArrival?.lowFloor == null
        ? '미확인'
        : firstArrival!.lowFloor!
            ? '저상버스'
            : '일반버스';
    final walkingProvider = walking == null
        ? '확인 중'
        : walking.provider == 'TMAP'
            ? 'TMAP 보행자 경로 API'
            : '${walking.provider} 보조 경로';
    final walkText = (walking == null || walking.totalDistanceMeters == null)
        ? '미확인'
        : '약 ${walking.totalDistanceMeters!.round()}m · 약 ${(((walking.totalDurationSeconds ?? 0) / 60).ceil()).clamp(1, 999)}분'
            '${walking.fallbackUsed ? ' (직선거리 기준)' : ''}';
    final busMsg = (s == null || s.busPositions.isEmpty)
        ? '현재 버스 위치는 아직 조회되지 않았어.'
        : '현재 ${s.busPositions.length}대의 버스 위치를 조회했어.';
    final updated = s?.lastUpdatedAt;
    final updatedText = updated == null ? '미확인' : _hhmm(updated.toLocal());
    final clockStart = DateTime.now();
    final clockEnd = totalMinutes == null
        ? null
        : clockStart.add(Duration(minutes: totalMinutes));

    final markers = _buildNavMarkers(s, userPosition, segment);
    final walkPolyline = walking?.polyline ?? const <V3GeoPoint>[];

    return Semantics(
      container: true,
      label: '실시간 길찾기 패널',
      child: Card(
        color: Theme.of(context)
            .colorScheme
            .secondaryContainer
            .withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.navigation_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '정류장까지 보행 내비게이션',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '경로 계산: $walkingProvider · 지도 타일: OpenStreetMap',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 260,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: markers.isEmpty
                      ? const Center(child: Text('표시할 위치 좌표가 없어.'))
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child:
                              _buildFlutterMap(context, markers, walkPolyline),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  for (final type in markers.map((m) => m.type).toSet())
                    _LiveRouteLegend(type: type),
                ],
              ),
              const Divider(height: 20),
              _CompactJourneyCard(
                routeNo: routeNo,
                destinationName: destName,
                boardStopName: boardName,
                alightStopName: alightName,
                busEtaMinutes: busEtaMinutes,
                remainingStops: firstArrival?.remainingStops,
                rideMinutes: rideMinutes,
                walkToBoardMinutes: walkToBoardMinutes,
                walkFromAlightMinutes: walkFromAlightMinutes,
                totalMinutes: totalMinutes,
                clockStart: clockStart,
                clockEnd: clockEnd,
                congestion: congestion,
                lowFloor: lowFloor,
                arrivals: s?.arrivals ?? const <V3BusArrival>[],
              ),
              const SizedBox(height: 10),
              if (walking?.instructions.isNotEmpty == true) ...[
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 6),
                  title: const Text(
                    'TMAP 보행 상세 보기',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('승차 정류장까지 $walkText'),
                  children: [
                    for (final instruction in walking!.instructions.take(3))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('• ${instruction.text}'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Text(busMsg),
              if (serviceStatus != null) ...[
                const SizedBox(height: 6),
                Text(
                  serviceStatus.message,
                  style: TextStyle(
                    color: serviceStatus.operatingNow
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '마지막 갱신: $updatedText · 30초마다 자동 갱신 중',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (s != null) ...[
                const SizedBox(height: 4),
                Text(
                  '데이터 source: ${s.fallbackSource}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (s.warnings.isNotEmpty)
                  for (final warning in s.warnings)
                    Text(
                      '주의: $warning',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
              ],
              if (errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  '갱신 실패(마지막 갱신 기준 표시 중): $errorMessage',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('경로 취소하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFlutterMap(BuildContext context, List<V3LiveRouteMarker> markers,
      List<V3GeoPoint> walkPolyline) {
    final navigationMarkers = markers.where(
      (marker) => marker.type == 'USER' || marker.type == 'BOARD_STOP',
    );
    final points = <LatLng>[
      ...navigationMarkers.map((m) => LatLng(m.latitude, m.longitude)),
      ...walkPolyline.map((p) => LatLng(p.latitude, p.longitude)),
    ];
    // 마커가 하나도 없더라도(예: 위치 미확보) 승차 정류장 좌표라도 있으면
    // 지도를 그릴 수 있게 모든 마커 좌표를 후보로 둔다.
    if (points.isEmpty) {
      points.addAll(markers.map((m) => LatLng(m.latitude, m.longitude)));
    }
    if (points.isEmpty) return const SizedBox();

    // 점이 1개거나 거의 한 지점에 몰려 있으면 bounds가 퇴화(degenerate)해
    // CameraFit가 비정상 줌을 만들어 지도가 회색으로만 보인다.
    // 이 경우 중심+고정 줌으로 안전하게 렌더링한다.
    final distinct = _distinctPoints(points);
    final MapOptions options;
    if (distinct.length < 2) {
      options = MapOptions(
        initialCenter: distinct.first,
        initialZoom: 16,
        minZoom: 3,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      );
    } else {
      options = MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(distinct),
          padding: const EdgeInsets.all(24.0),
          maxZoom: 18,
        ),
        minZoom: 3,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      );
    }

    return FlutterMap(
      options: options,
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.mobi.smart.transport.ai',
          maxNativeZoom: 19,
          // 인앱 브라우저 등에서 일부 타일 로딩이 실패해도 회색 빈 화면 대신
          // 빈 타일로 처리해 지도 자체는 계속 표시한다.
          errorTileCallback: (tile, error, stackTrace) {},
        ),
        if (walkPolyline.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: walkPolyline
                    .map((p) => LatLng(p.latitude, p.longitude))
                    .toList(),
                color: Colors.green,
                strokeWidth: 4.0,
              ),
            ],
          ),
        MarkerLayer(
          markers: markers.map((m) {
            final color = _liveRouteColor(m.type);
            final radius = m.type == 'BUS'
                ? 10.0
                : m.type == 'NEARBY'
                    ? 6.0
                    : 8.0;
            return Marker(
              point: LatLng(m.latitude, m.longitude),
              width: radius * 2,
              height: radius * 2,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 3.0,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

String _congestionLabel(String? value) {
  return switch (value?.toUpperCase()) {
    'LOW' => '여유',
    'NORMAL' => '보통',
    'HIGH' => '혼잡',
    'UNKNOWN' || null || '' => '정보 없음',
    _ => value!,
  };
}

/// 거의 같은 좌표(약 11m 이내)는 하나로 합쳐, bounds 퇴화를 판별한다.
List<LatLng> _distinctPoints(List<LatLng> points) {
  final seen = <String>{};
  final out = <LatLng>[];
  for (final p in points) {
    final key =
        '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';
    if (seen.add(key)) out.add(p);
  }
  return out;
}

String _hhmm(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

int? _walkingMinutes(V3WalkingRoute? route) {
  final seconds = route?.totalDurationSeconds;
  if (seconds == null) return null;
  return (seconds / 60).ceil().clamp(1, 999);
}

int? _journeyTotalMinutes({
  required int? walkToBoardMinutes,
  required int? busEtaMinutes,
  required int? rideMinutes,
  required int? walkFromAlightMinutes,
  required int? fallback,
}) {
  if (busEtaMinutes == null || rideMinutes == null) return fallback;
  final accessAndWait = busEtaMinutes > (walkToBoardMinutes ?? 0)
      ? busEtaMinutes
      : (walkToBoardMinutes ?? 0);
  return accessAndWait + rideMinutes + (walkFromAlightMinutes ?? 0);
}

/// V3LiveStatus + 선택 경로에서 실시간 지도 마커 목록을 만든다.
List<V3LiveRouteMarker> _buildNavMarkers(
  V3LiveStatus? s,
  Position? userPosition,
  V3RoutePlanSegment? segment,
) {
  final markers = <V3LiveRouteMarker>[];
  final user = s?.userLocation;
  if (user != null) {
    markers.add(V3LiveRouteMarker(
        type: 'USER',
        label: '내 위치',
        latitude: user.latitude,
        longitude: user.longitude));
  } else if (userPosition != null) {
    markers.add(V3LiveRouteMarker(
        type: 'USER',
        label: '내 위치',
        latitude: userPosition.latitude,
        longitude: userPosition.longitude));
  }
  for (final stop in s?.nearbyStops ?? const <V3NearbyStop>[]) {
    markers.add(V3LiveRouteMarker(
        type: 'NEARBY',
        label: stop.stopName,
        latitude: stop.latitude,
        longitude: stop.longitude));
  }
  final board = s?.selectedBoardStop;
  final boardLat = board?.latitude ?? segment?.boardStop.latitude;
  final boardLng = board?.longitude ?? segment?.boardStop.longitude;
  if (boardLat != null && boardLng != null) {
    markers.add(V3LiveRouteMarker(
        type: 'BOARD_STOP',
        label: '승차',
        latitude: boardLat,
        longitude: boardLng));
  }
  final alight = s?.selectedAlightStop;
  final alightLat = alight?.latitude ?? segment?.alightStop.latitude;
  final alightLng = alight?.longitude ?? segment?.alightStop.longitude;
  if (alightLat != null && alightLng != null) {
    markers.add(V3LiveRouteMarker(
        type: 'ALIGHT_STOP',
        label: '하차',
        latitude: alightLat,
        longitude: alightLng));
  }
  for (final bus in s?.busPositions ?? const <V3BusPosition>[]) {
    if (bus.latitude != null && bus.longitude != null) {
      markers.add(V3LiveRouteMarker(
          type: 'BUS',
          label: '${bus.routeNo}번',
          latitude: bus.latitude!,
          longitude: bus.longitude!));
    }
  }
  return markers;
}

class _CompactJourneyCard extends StatelessWidget {
  const _CompactJourneyCard({
    required this.routeNo,
    required this.destinationName,
    required this.boardStopName,
    required this.alightStopName,
    required this.busEtaMinutes,
    required this.remainingStops,
    required this.rideMinutes,
    required this.walkToBoardMinutes,
    required this.walkFromAlightMinutes,
    required this.totalMinutes,
    required this.clockStart,
    required this.clockEnd,
    required this.congestion,
    required this.lowFloor,
    required this.arrivals,
  });

  final String routeNo;
  final String destinationName;
  final String boardStopName;
  final String alightStopName;
  final int? busEtaMinutes;
  final int? remainingStops;
  final int? rideMinutes;
  final int? walkToBoardMinutes;
  final int? walkFromAlightMinutes;
  final int? totalMinutes;
  final DateTime clockStart;
  final DateTime? clockEnd;
  final String congestion;
  final String lowFloor;
  final List<V3BusArrival> arrivals;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF1D1D1F);
    const muted = Color(0xFFB0B0B5);
    const blue = Color(0xFF4385FF);
    const orange = Color(0xFFFF6B55);
    final routeMinutes = rideMinutes == null ? '운행 시간 확인 중' : '$rideMinutes분';
    final stopCount =
        remainingStops == null ? '정류장 수 확인 중' : '$remainingStops정류장 전';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, height: 1.35),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '최적',
                style: TextStyle(color: blue, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                totalMinutes == null ? '총 소요 시간 확인 중' : '$totalMinutes분',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (clockEnd != null)
                Text(
                  '${_hhmm(clockStart)} - ${_hhmm(clockEnd!)}',
                  style: const TextStyle(color: muted, fontSize: 16),
                ),
              const SizedBox(height: 14),
              _JourneyTimeline(
                walkToBoardMinutes: walkToBoardMinutes,
                busEtaMinutes: busEtaMinutes,
                walkFromAlightMinutes: walkFromAlightMinutes,
              ),
              const Divider(height: 28, color: Color(0xFF3B3B3F)),
              Row(
                children: [
                  const Icon(Icons.directions_bus_filled,
                      color: blue, size: 20),
                  const SizedBox(width: 5),
                  const Text(
                    '버스',
                    style: TextStyle(color: blue, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      boardStopName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(width: 24),
                  Text(
                    routeNo,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    busEtaMinutes == null ? '도착 확인 중' : '$busEtaMinutes분 뒤',
                    style: const TextStyle(
                      color: orange,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      stopCount,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Text(
                  '$routeMinutes · 혼잡도 $congestion · $lowFloor',
                  style: const TextStyle(color: muted),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '하차  $alightStopName',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 4),
              Text(
                '목적지  $destinationName',
                style: const TextStyle(color: muted),
              ),
              if (arrivals.length > 1) ...[
                const SizedBox(height: 10),
                Text(
                  '다음 버스  ${arrivals.skip(1).take(2).map((item) => item.displayLabel).join(' / ')}',
                  style: const TextStyle(color: muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _JourneyTimeline extends StatelessWidget {
  const _JourneyTimeline({
    required this.walkToBoardMinutes,
    required this.busEtaMinutes,
    required this.walkFromAlightMinutes,
  });

  final int? walkToBoardMinutes;
  final int? busEtaMinutes;
  final int? walkFromAlightMinutes;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            _TimelineSegment(
              flex: _timelineFlex(walkToBoardMinutes),
              color: const Color(0xFF55585D),
              icon: Icons.directions_walk,
              label: _minuteLabel(walkToBoardMinutes),
            ),
            _TimelineSegment(
              flex: _timelineFlex(busEtaMinutes),
              color: const Color(0xFF3974F3),
              icon: Icons.directions_bus_filled,
              label: _minuteLabel(busEtaMinutes),
            ),
            _TimelineSegment(
              flex: _timelineFlex(walkFromAlightMinutes),
              color: const Color(0xFF55585D),
              icon: Icons.directions_walk,
              label: _minuteLabel(walkFromAlightMinutes),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineSegment extends StatelessWidget {
  const _TimelineSegment({
    required this.flex,
    required this.color,
    required this.icon,
    required this.label,
  });

  final int flex;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: ColoredBox(
        color: color,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 14),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int _timelineFlex(int? minutes) => (minutes ?? 1).clamp(1, 60);

String _minuteLabel(int? minutes) => minutes == null ? '-' : '$minutes분';

class _LiveRouteLegend extends StatelessWidget {
  const _LiveRouteLegend({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, color: _liveRouteColor(type), size: 12),
        const SizedBox(width: 4),
        Text(_liveRouteLabel(type)),
      ],
    );
  }
}

Color _liveRouteColor(String type) {
  return switch (type) {
    'USER' => Colors.indigo,
    'BOARD_STOP' => Colors.green,
    'ALIGHT_STOP' => Colors.orange,
    'BUS' => Colors.red,
    'NEARBY' => Colors.blueGrey,
    _ => Colors.purple,
  };
}

String _liveRouteLabel(String type) {
  return switch (type) {
    'USER' => '내 위치',
    'BOARD_STOP' => '승차',
    'ALIGHT_STOP' => '하차',
    'BUS' => '버스',
    'NEARBY' => '근처정류장',
    _ => '목적지',
  };
}

class _CombinedChatControlCard extends StatelessWidget {
  const _CombinedChatControlCard({
    required this.controller,
    required this.isBusy,
    required this.wakeWord,
    required this.onSend,
    required this.onQuickAction,
  });

  final TextEditingController controller;
  final bool isBusy;
  final String wakeWord;
  final VoidCallback onSend;
  final ValueChanged<String> onQuickAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '음성 및 텍스트 제어',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '메시지 직접 입력',
                    ),
                    onSubmitted: (_) => isBusy ? null : onSend(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: isBusy ? null : onSend,
                  icon: const Icon(Icons.send),
                  tooltip: '전송',
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    label: const Text('호출'),
                    onPressed: isBusy ? null : () => onQuickAction(wakeWord),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('경로 묻기 (사창사거리)'),
                    onPressed: isBusy
                        ? null
                        : () => onQuickAction(
                            '$wakeWord, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('도착 묻기'),
                    onPressed: isBusy
                        ? null
                        : () => onQuickAction('$wakeWord, 그 버스 언제 와?'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('탑승 가능 묻기'),
                    onPressed: isBusy
                        ? null
                        : () => onQuickAction('$wakeWord, 지금 앞에 온 버스 타도 돼?'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('놓침 알림'),
                    onPressed: isBusy
                        ? null
                        : () => onQuickAction('$wakeWord, 나 못 탔어.'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('목적지 변경 (충북대병원)'),
                    onPressed:
                        isBusy ? null : () => onQuickAction('목적지 충북대병원으로 바꿔줘'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugExpansionPanel extends StatelessWidget {
  const _DebugExpansionPanel({
    required this.isBusy,
    required this.dataMode,
    required this.traceId,
    required this.traceEvents,
    required this.isAgentTraceExpanded,
    required this.onToggleTrace,
    // Mock Control callbacks
    required this.onArrivedAtStop,
    required this.onLeftWaitingArea,
    required this.onDangerZone,
    required this.onReturnedToStop,
    required this.onWrongBusNear,
    required this.onTargetBusMid,
    required this.onTargetBusNear,
    required this.onNoBeacon,
    required this.onBusPassed,
    required this.onRefreshArrivals,
    required this.latestBeaconDecision,
    required this.latestGeofenceMessage,
    // Head Tracking
    required this.headTracking,
    required this.useMockHeadTracking,
    required this.onToggleMockHeadTracking,
    // Debug Panel
    required this.apiBaseUrl,
    required this.healthMessage,
    required this.sessionState,
    required this.lastAgentResponse,
    required this.lastArrivals,
    required this.activeCueType,
  });

  final bool isBusy;
  final String dataMode;
  final String? traceId;
  final List<V3AgentTraceEvent>? traceEvents;
  final bool isAgentTraceExpanded;
  final VoidCallback onToggleTrace;

  final VoidCallback onArrivedAtStop;
  final VoidCallback onLeftWaitingArea;
  final VoidCallback onDangerZone;
  final VoidCallback onReturnedToStop;
  final VoidCallback onWrongBusNear;
  final VoidCallback onTargetBusMid;
  final VoidCallback onTargetBusNear;
  final VoidCallback onNoBeacon;
  final VoidCallback onBusPassed;
  final VoidCallback onRefreshArrivals;
  final V3BeaconDecisionResponse? latestBeaconDecision;
  final String? latestGeofenceMessage;

  final HeadTrackingDebugSnapshot headTracking;
  final bool useMockHeadTracking;
  final ValueChanged<bool> onToggleMockHeadTracking;

  final String apiBaseUrl;
  final String healthMessage;
  final V3GuidanceState? sessionState;
  final V3AgentResponse? lastAgentResponse;
  final V3BusArrivalsResponse? lastArrivals;
  final String? activeCueType;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: ExpansionTile(
        title: Text(
          '디버그 및 제어 도구 (Debug Tools)',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        leading: const Icon(Icons.bug_report_outlined),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          if (traceEvents != null && traceEvents!.isNotEmpty) ...[
            _AgentTraceCard(
              traceId: traceId,
              events: traceEvents!,
              expanded: isAgentTraceExpanded,
              onToggle: onToggleTrace,
            ),
            const SizedBox(height: 12),
          ],
          if (dataMode != 'PUBLIC_API') ...[
            V3MockControlPanel(
              isBusy: isBusy,
              onArrivedAtStop: onArrivedAtStop,
              onLeftWaitingArea: onLeftWaitingArea,
              onDangerZone: onDangerZone,
              onReturnedToStop: onReturnedToStop,
              onWrongBusNear: onWrongBusNear,
              onTargetBusMid: onTargetBusMid,
              onTargetBusNear: onTargetBusNear,
              onNoBeacon: onNoBeacon,
              onBusPassed: onBusPassed,
              onRefreshArrivals: onRefreshArrivals,
              latestBeaconDecision: latestBeaconDecision,
              latestGeofenceMessage: latestGeofenceMessage,
            ),
            const SizedBox(height: 12),
          ],
          _HeadTrackingCard(
            snapshot: headTracking,
            enabled: useMockHeadTracking,
            onChanged: onToggleMockHeadTracking,
          ),
          const SizedBox(height: 12),
          V3DebugPanel(
            baseUrl: apiBaseUrl,
            healthMessage: healthMessage,
            sessionState: sessionState,
            lastAgentResponse: lastAgentResponse,
            lastArrivals: lastArrivals,
            lastBeaconDecision: latestBeaconDecision,
            headTracking: headTracking,
            activeCueType: activeCueType,
          ),
        ],
      ),
    );
  }
}

class _ArrivalCard extends StatelessWidget {
  const _ArrivalCard({
    required this.routeRecommendation,
    required this.routePlanningStatus,
    required this.routePlan,
    required this.arrivals,
    required this.onRecommendSachang,
    required this.onRecommendHospital,
    required this.onRecommendSangdang,
    required this.onRefreshArrivals,
    required this.onChooseDestination,
    required this.onStartGuidance,
    required this.isBusy,
  });

  final V3RouteRecommendResponse? routeRecommendation;
  final V3RoutePlanResponse? routePlan;
  final String? routePlanningStatus;
  final V3BusArrivalsResponse? arrivals;
  final VoidCallback onRecommendSachang;
  final VoidCallback onRecommendHospital;
  final VoidCallback onRecommendSangdang;
  final VoidCallback onRefreshArrivals;
  final ValueChanged<String> onChooseDestination;
  final VoidCallback onStartGuidance;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final firstRecommendation =
        routeRecommendation?.recommendations.isNotEmpty == true
            ? routeRecommendation!.recommendations.first
            : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Route / Arrival Panel',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            if (firstRecommendation == null &&
                routePlan?.recommendedPlan == null)
              const Text('추천 결과 없음')
            else if (firstRecommendation != null)
              Text(
                '${firstRecommendation.destination}: ${firstRecommendation.stopName}에서 ${firstRecommendation.routeNo}번 · ${firstRecommendation.fallbackSource}',
              ),
            if (routePlanningStatus != null) ...[
              const SizedBox(height: 6),
              Text(routePlanningStatus!),
            ],
            if (routePlan?.question != null) ...[
              const SizedBox(height: 8),
              Text(
                routePlan!.question!,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
            if (routePlan?.destination?.candidates.isNotEmpty == true &&
                (routePlan!.status == 'NEEDS_CHOICE' ||
                    routePlan!.status == 'NEEDS_CONFIRMATION')) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final candidate in routePlan!.destination!.candidates)
                    OutlinedButton(
                      onPressed: isBusy
                          ? null
                          : () => onChooseDestination(candidate.name),
                      child: Text('${candidate.name} 선택'),
                    ),
                ],
              ),
            ],
            if (routePlan?.recommendedPlan != null) ...[
              const SizedBox(height: 12),
              _RoutePlanCard(plan: routePlan!.recommendedPlan!),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: isBusy ? null : onStartGuidance,
                icon: const Icon(Icons.navigation),
                label: const Text('이 경로로 안내 시작'),
              ),
            ],
            if (routePlan?.alternatives.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Text(
                '대안 경로',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              for (final alternative in routePlan!.alternatives)
                _AlternativeRouteCard(plan: alternative),
            ],
            if (routeRecommendation?.planningSummary != null) ...[
              const SizedBox(height: 6),
              Text(
                '${routeRecommendation!.planningModel}: ${routeRecommendation!.planningSummary}',
              ),
            ],
            if (routeRecommendation?.planningDataSource != null) ...[
              const SizedBox(height: 4),
              Text(
                  '경로 계산 데이터 source: ${routeRecommendation!.planningDataSource}'),
            ],
            if (routeRecommendation?.mapsGrounded == true) ...[
              const SizedBox(height: 4),
              const Text('Google Maps 최신 위치 정보 grounding 사용'),
            ],
            if (routeRecommendation?.mapsEvidence.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              _MapsEvidenceCard(
                evidence: routeRecommendation!.mapsEvidence,
              ),
            ],
            if (routeRecommendation?.stopEvidence != null) ...[
              const SizedBox(height: 12),
              _PublicStopCatalogEvidenceCard(
                evidence: routeRecommendation!.stopEvidence!,
              ),
            ],
            if (routeRecommendation?.evidence != null) ...[
              const SizedBox(height: 12),
              _PublicDataEvidenceCard(
                evidence: routeRecommendation!.evidence!,
              ),
            ],
            const SizedBox(height: 8),
            Text('도착정보 source: ${arrivals?.fallbackSource ?? '-'}'),
            const SizedBox(height: 4),
            for (final arrival in arrivals?.arrivals ?? const <V3BusArrival>[])
              Text(
                  '• ${arrival.displayLabel} · congestion=${arrival.congestion ?? '없음'}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: isBusy ? null : onRecommendSachang,
                  child: const Text('사창사거리 추천'),
                ),
                OutlinedButton(
                  onPressed: isBusy ? null : onRecommendHospital,
                  child: const Text('충북대병원 추천'),
                ),
                OutlinedButton(
                  onPressed: isBusy ? null : onRecommendSangdang,
                  child: const Text('상당산성 경로계산'),
                ),
                OutlinedButton(
                  onPressed: isBusy ? null : onRefreshArrivals,
                  child: const Text('도착정보 갱신'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutePlanCard extends StatelessWidget {
  const _RoutePlanCard({required this.plan});

  final V3RoutePlanCandidate plan;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typeLabel = plan.type == 'DIRECT' ? '직통 추천' : '1회 환승 추천';
    final firstSegment = plan.segments.isEmpty ? null : plan.segments.first;
    final arrivals = firstSegment?.arrivals;
    final firstArrival =
        arrivals == null || arrivals.isEmpty ? null : arrivals.first;
    return Semantics(
      container: true,
      label: '구조화된 버스 경로 계획, $typeLabel',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.35),
          border: Border.all(color: colorScheme.primary, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$typeLabel · ${plan.destinationName}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 6),
              Text(plan.summary),
              const SizedBox(height: 6),
              Text('출처: ${_routePlanSourceLabel(plan)}'),
              const SizedBox(height: 4),
              Text(
                  '검증 상태: ${_verificationStatusLabel(plan.verificationStatus)}'),
              if (plan.warnings.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final warning in plan.warnings)
                  Text(
                    '주의: $warning',
                    style: TextStyle(color: colorScheme.error),
                  ),
              ],
              const SizedBox(height: 6),
              Text(plan.boardingInstruction),
              if (plan.recommendedReason != null) ...[
                const SizedBox(height: 6),
                Text(plan.recommendedReason!),
              ],
              if (firstSegment != null) ...[
                const SizedBox(height: 8),
                Text(
                  '승차 방향: ${firstSegment.directionHint ?? '방향 미확인'}',
                  style: TextStyle(
                      color: colorScheme.primary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  firstArrival == null
                      ? '첫 도착정보: 미확인'
                      : '첫 도착정보: ${firstArrival.displayLabel}',
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '보행 약 ${plan.estimatedWalkMeters.toStringAsFixed(0)}m · ${plan.totalBusStopCount}정류장 · source ${plan.fallbackSource}',
              ),
              const SizedBox(height: 8),
              for (final segment in plan.segments)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• ${segment.routeNo}번: ${segment.boardStop.stopName} → ${segment.alightStop.stopName} (${segment.directionHint ?? '방향 미확인'})',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _routePlanSourceLabel(V3RoutePlanCandidate plan) {
  return switch (plan.planSource) {
    'ODSAY_ENRICHED' => 'ODsay 경로 + 청주 실시간 도착정보 검증',
    'ODSAY' => 'ODsay 경로',
    _ => '청주 버스 공공데이터 자체 경로',
  };
}

String _verificationStatusLabel(String status) {
  return switch (status) {
    'VERIFIED_WITH_TAGO' => '청주 버스 데이터 검증 완료',
    'PARTIAL' => '일부 구간만 검증됨',
    'ODSAY_ONLY' => '실시간 도착정보 미확인',
    _ => '자체 경로 계산',
  };
}

class _AlternativeRouteCard extends StatelessWidget {
  const _AlternativeRouteCard({required this.plan});

  final V3RoutePlanCandidate plan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '${plan.type == 'DIRECT' ? '직통' : '1회 환승'} · ${plan.summary} · 점수 ${plan.score.toStringAsFixed(1)}',
          ),
        ),
      ),
    );
  }
}

class _PublicStopCatalogEvidenceCard extends StatelessWidget {
  const _PublicStopCatalogEvidenceCard({required this.evidence});

  final V3PublicBusStopEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final host = Uri.tryParse(evidence.endpoint)?.host ?? 'api.odcloud.kr';
    return Semantics(
      container: true,
      label: '실제 공공 API 정류소 증빙, ${evidence.stopName}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.42),
          border: Border.all(color: colorScheme.primary, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.fact_check_outlined, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '실제 공공 API 정류소 증빙',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '청주시 승인 API · PUBLIC_API',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text('${evidence.stopName} · 서비스ID ${evidence.serviceId}'),
              Text(
                '좌표 ${evidence.latitude.toStringAsFixed(6)}, ${evidence.longitude.toStringAsFixed(6)}',
              ),
              Text('검증 레코드 ${evidence.totalCount}개 · $host'),
              const SizedBox(height: 6),
              Text(
                '이 카드는 정류소 위치 근거입니다. 버스 도착 예정 시간은 아래 카드의 별도 출처를 확인해 주세요.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapsEvidenceCard extends StatelessWidget {
  const _MapsEvidenceCard({required this.evidence});

  final List<V3MapsGroundingEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Google Maps 최신 위치 정보 증빙',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
          border: Border.all(color: colorScheme.secondary),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.map_outlined, color: colorScheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Google Maps 위치 정보 증빙',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final source in evidence.take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• ${source.title}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PublicDataEvidenceCard extends StatelessWidget {
  const _PublicDataEvidenceCard({required this.evidence});

  final V3RoutePlanningEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final isPublicData = evidence.isPublicData;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor =
        isPublicData ? colorScheme.primary : colorScheme.tertiary;
    final sourceLabel = switch (evidence.source) {
      'PUBLIC_API' => '실시간 공공 API',
      'CACHE' => '공공 API 정규화 캐시',
      'MOCK' => '시연 데이터 · 실제 공공 API 아님',
      _ => '공공 데이터 확인 불가',
    };

    return Semantics(
      container: true,
      label: '버스 도착 정보 증빙, $sourceLabel',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: 0.08),
          border: Border.all(color: accentColor, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.verified_outlined, color: accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '버스 도착 정보 증빙',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                sourceLabel,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text('${evidence.stopName} · ${evidence.routeNo}번'),
              Text('정류장 ID: ${evidence.stopId}'),
              const SizedBox(height: 10),
              if (evidence.arrivals.isEmpty)
                const Text('표시할 도착 정보가 없습니다.')
              else
                for (final arrival in evidence.arrivals)
                  _EvidenceArrivalRow(arrival: arrival),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceArrivalRow extends StatelessWidget {
  const _EvidenceArrivalRow({required this.arrival});

  final V3BusArrival arrival;

  @override
  Widget build(BuildContext context) {
    final lowFloorLabel = switch (arrival.lowFloor) {
      true => '저상버스',
      false => '일반버스',
      null => '저상버스 여부 미확인',
    };
    final remainingStops = arrival.remainingStops == null
        ? '남은 정류장 미확인'
        : '${arrival.remainingStops}정류장 전';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.directions_bus_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${arrival.routeNo}번 버스',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                        '$remainingStops · $lowFloorLabel · 혼잡도 ${arrival.congestion ?? '미확인'}'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${arrival.arrivalMinutes}분',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutePlanningOverlay extends StatefulWidget {
  const _RoutePlanningOverlay({required this.message});

  final String message;

  @override
  State<_RoutePlanningOverlay> createState() => _RoutePlanningOverlayState();
}

class _RoutePlanningOverlayState extends State<_RoutePlanningOverlay> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _seconds++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Semantics(
            liveRegion: true,
            label: widget.message,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  '생각 중... ${_seconds > 0 ? '($_seconds초)' : ''}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoutePlanningPreparation {
  const _RoutePlanningPreparation({this.position});

  final Position? position;
}

class _HeadTrackingCard extends StatelessWidget {
  const _HeadTrackingCard({
    required this.snapshot,
    required this.enabled,
    required this.onChanged,
  });

  final HeadTrackingDebugSnapshot snapshot;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        value: enabled,
        onChanged: onChanged,
        title: const Text('Optional Head Tracking Debug'),
        subtitle: Text(
          'status=${snapshot.statusLabel}, yaw=${_angle(snapshot.yaw)}, pitch=${_angle(snapshot.pitch)}, roll=${_angle(snapshot.roll)}',
        ),
      ),
    );
  }

  String _angle(double? value) =>
      value == null ? '-' : '${value.toStringAsFixed(1)}°';
}
