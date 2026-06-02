import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/v3_guidance_models.dart';
import '../services/audio_haptic_cue_service.dart';
import '../services/v3_agent_api_client.dart';
import '../widgets/chat_overlay.dart';
import '../widgets/debug_panel.dart';
import '../widgets/mock_control_panel.dart';
import '../widgets/quick_action_panel.dart';

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

  static const String _apiBaseUrl = String.fromEnvironment(
    'MOBI_API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  static const String _sessionId = 'demo-session';

  late final V3AgentApiClient _client;
  late final AudioHapticCueService _cueService;
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

  // 실시간 채팅 상태
  final List<ChatMessage> _chatMessages = [];
  bool _isChatOpen = false;

  String get _wakeWord => widget.agentName;

  @override
  void initState() {
    super.initState();
    _client = const V3AgentApiClient(baseUrl: _apiBaseUrl);
    _cueService = AudioHapticCueService();
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
      final arrivals = await _client.arrivals(
        stopId: 'mock-stop-001',
        routeNo: '502',
        mode: widget.dataMode,
      );
      setState(() {
        _healthStatus = health;
        _sessionState = session;
        _lastArrivals = arrivals;
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
    setState(() {
      _chatMessages.add(ChatMessage(
        text: text.trim(),
        isUser: true,
        timestamp: DateTime.now(),
      ));
    });
    await _sendUtteranceFromSource(utterance: text, fromChat: true);
  }

  Future<void> _sendUtteranceFromSource({
    String? utterance,
    required bool fromChat,
  }) async {
    final text = (utterance ?? _utteranceController.text).trim();
    if (text.isEmpty) return;

    final shouldPlanRoute = _looksLikeRouteRequest(text);
    final planningPreparation =
        shouldPlanRoute ? await _beginRoutePlanning() : null;

    try {
      await _runGuarded(() async {
        final response = await _client.converse(
          sessionId: _sessionId,
          wakeWord: _wakeWord,
          utterance: text,
          mode: widget.dataMode,
          originLat: planningPreparation?.position?.latitude,
          originLng: planningPreparation?.position?.longitude,
        );
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
        setState(() {
          _lastAgentResponse = response;
          _isAgentTraceExpanded = false;
          _sessionState = state;
          if (routePlan != null) {
            _lastRoutePlan = routePlan;
            _lastRouteRecommendation = null;
            _routePlanningStatus = planningStatus;
          }
          if (recommendation != null) {
            _lastRouteRecommendation = recommendation;
            _routePlanningStatus = planningStatus;
          }
          // 채팅에서 보낸 경우 에이전트 응답도 채팅 메시지에 추가
          if (fromChat) {
            _chatMessages.add(ChatMessage(
              text: response.message,
              isUser: false,
              timestamp: DateTime.now(),
            ));
          }
        });
        if (routePlan?.recommendedPlan != null) {
          await _activateLiveRoutePanel(
              routePlan!, planningPreparation?.position);
        } else if (shouldPlanRoute) {
          _stopLiveRoutePolling(clearStatus: true);
        }
        await _cueService.playCue(response.cue,
            fallbackMessage: response.message);
        if (response.cue.isNone && response.ttsMode != 'NONE') {
          await _speakAgentMessage(
            response.message,
            forceLocal: response.ttsMode == 'SAFETY_LOCAL',
          );
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

  Future<void> _speakAgentMessage(String message,
      {bool forceLocal = false}) async {
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
          await _speakAgentMessage(spokenGuidance);
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
    // 1분(60초) 단위 최신화. 서버에도 30초 캐시가 있어 과호출을 막는다.
    _liveRouteTimer = Timer.periodic(const Duration(seconds: 60), (_) {
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
    // 사용자 위치는 폴링마다 가능한 한 최신값을 사용한다(서버 호출은 60초로 제한).
    final userPos = _cachedPosition ?? _lastRoutePosition;
    setState(() {
      _isLiveRouteLoading = true;
    });
    try {
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
        destName: segment.alightStop.stopName,
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

  /// '길찾기 중지': 지도/실시간 패널을 끄고 1분 폴링을 멈춘다.
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
    });
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

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );
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
        title: const Text('V3 버스 탑승 보조'),
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
      // 채팅 FAB 버튼
      floatingActionButton: _isChatOpen
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
                  if (_lastAgentResponse?.trace.isNotEmpty == true) ...[
                    const SizedBox(height: 12),
                    _AgentTraceCard(
                      traceId: _lastAgentResponse?.traceId,
                      events: _lastAgentResponse!.trace,
                      expanded: _isAgentTraceExpanded,
                      onToggle: () => setState(() {
                        _isAgentTraceExpanded = !_isAgentTraceExpanded;
                      }),
                    ),
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
                  const SizedBox(height: 12),
                  _UtteranceCard(
                    controller: _utteranceController,
                    isBusy: _isBusy,
                    onSend: _sendUtterance,
                  ),
                  const SizedBox(height: 12),
                  V3QuickActionPanel(
                    isBusy: _isBusy,
                    wakeWord: _wakeWord,
                    onWakeOnly: () => _sendUtterance(_wakeWord),
                    onFindRoute: () => _sendUtterance(
                        '$_wakeWord, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?'),
                    onQueryArrival: () =>
                        _sendUtterance('$_wakeWord, 그 버스 언제 와?'),
                    onSelectArrival: () =>
                        _sendUtterance('응, 6분 뒤 오는 걸로 안내해줘.'),
                    onAskCanBoard: () =>
                        _sendUtterance('$_wakeWord, 지금 앞에 온 버스 타도 돼?'),
                    onMissedBus: () => _sendUtterance('$_wakeWord, 나 못 탔어.'),
                    onChangeDestination: () =>
                        _sendUtterance('목적지 충북대병원으로 바꿔줘'),
                  ),
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
                  V3MockControlPanel(
                    isBusy: _isBusy,
                    onArrivedAtStop: () => _mockGeofence('ARRIVED_AT_STOP'),
                    onLeftWaitingArea: () => _mockGeofence('LEFT_WAITING_AREA'),
                    onDangerZone: () => _mockGeofence('DANGER_ZONE'),
                    onReturnedToStop: () => _mockGeofence('RETURNED_TO_STOP'),
                    onWrongBusNear: () => _mockBeacons(const <V3BeaconSignal>[
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
                    ]),
                    onTargetBusMid: () => _mockBeacons(const <V3BeaconSignal>[
                      V3BeaconSignal(
                          busId: 'BUS_2',
                          routeNo: '502',
                          rssi: -70,
                          distanceMeters: 6.0),
                    ]),
                    onTargetBusNear: () => _mockBeacons(const <V3BeaconSignal>[
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
                  ),
                  const SizedBox(height: 12),
                  _HeadTrackingCard(
                    snapshot: _headTracking,
                    enabled: _useMockHeadTracking,
                    onChanged: _toggleMockHeadTracking,
                  ),
                  const SizedBox(height: 12),
                  V3DebugPanel(
                    baseUrl: _apiBaseUrl,
                    healthMessage: _healthStatus?.message ?? '확인 전',
                    sessionState: _sessionState,
                    lastAgentResponse: _lastAgentResponse,
                    lastArrivals: _lastArrivals,
                    lastBeaconDecision: _lastBeaconDecision,
                    headTracking: _headTracking,
                    activeCueType: _cueService.activeCueType,
                  ),
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
              '위치 권한이 필요해요. 정확한 경로를 안내하려면 브라우저에서 위치 접근을 허용해줘. '
              '위치 없이도 등록된 목적지는 안내할 수 있지만, 현재 위치 기준 경로는 권한이 있어야 정확해.',
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

class _NavStoppedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '길찾기를 중지했어. 지도 갱신을 멈췄어. 새 목적지를 말하면 다시 시작할게.',
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

    final destName =
        plan?.destinationName ?? segment?.alightStop.stopName ?? '목적지';
    final routeNo = segment?.routeNo ?? s?.routeNo ?? '미확인';
    final boardName = s?.selectedBoardStop?.stopName ??
        segment?.boardStop.stopName ??
        '미확인';
    final alightName = s?.selectedAlightStop?.stopName ??
        segment?.alightStop.stopName ??
        '미확인';
    final eta =
        firstArrival == null ? '미확인' : '${firstArrival.arrivalMinutes}분 뒤';
    final remaining = firstArrival?.remainingStops == null
        ? '미확인'
        : '${firstArrival!.remainingStops}정류장 전';
    final congestion = s?.congestion ?? '미제공';
    final walkText = (walking == null || walking.totalDistanceMeters == null)
        ? '미확인'
        : '약 ${walking.totalDistanceMeters!.round()}m · 약 ${(((walking.totalDurationSeconds ?? 0) / 60).ceil()).clamp(1, 999)}분'
            '${walking.fallbackUsed ? ' (직선거리 기준)' : ''}';
    final busMsg = (s == null || s.busPositions.isEmpty)
        ? '현재 버스 위치는 아직 조회되지 않았어.'
        : '현재 ${s.busPositions.length}대의 버스 위치를 조회했어.';
    final updated = s?.lastUpdatedAt;
    final updatedText = updated == null ? '미확인' : _hhmm(updated.toLocal());

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
                      '실시간 길찾기',
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
              // 길찾기 중지: 지도/경로 UI를 끄고 1분 폴링을 멈춘다.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('길찾기 중지'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '실제 지도 타일이 아닌 간이 위치도',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 180,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: markers.isEmpty
                      ? const Center(child: Text('표시할 위치 좌표가 없어.'))
                      : CustomPaint(
                          painter: _NavMapPainter(markers, walkPolyline),
                          child: const SizedBox.expand(),
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
              Text(
                '$routeNo번 · $destName',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 6),
              _LiveMetric(label: '승차 정류장', value: boardName),
              _LiveMetric(label: '하차 정류장', value: alightName),
              _LiveMetric(label: '탑승 버스', value: '$routeNo번'),
              _LiveMetric(label: '정류장까지 도보', value: walkText),
              _LiveMetric(label: '버스 도착 예정', value: eta),
              _LiveMetric(label: '남은 정류장', value: remaining),
              _LiveMetric(label: '혼잡도', value: congestion),
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
                '마지막 갱신: $updatedText · 1분마다 자동 갱신 중',
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
            ],
          ),
        ),
      ),
    );
  }
}

String _hhmm(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// V3LiveStatus + 선택 경로에서 간이 위치도 마커 목록을 만든다.
List<V3LiveRouteMarker> _buildNavMarkers(
  V3LiveStatus? s,
  Position? userPosition,
  V3RoutePlanSegment? segment,
) {
  final markers = <V3LiveRouteMarker>[];
  final user = s?.userLocation;
  if (user != null) {
    markers.add(V3LiveRouteMarker(
        type: 'USER', label: '내 위치', latitude: user.latitude, longitude: user.longitude));
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
        type: 'BOARD_STOP', label: '승차', latitude: boardLat, longitude: boardLng));
  }
  final alight = s?.selectedAlightStop;
  final alightLat = alight?.latitude ?? segment?.alightStop.latitude;
  final alightLng = alight?.longitude ?? segment?.alightStop.longitude;
  if (alightLat != null && alightLng != null) {
    markers.add(V3LiveRouteMarker(
        type: 'ALIGHT_STOP', label: '하차', latitude: alightLat, longitude: alightLng));
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

class _LiveMetric extends StatelessWidget {
  const _LiveMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text('$label: $value'),
    );
  }
}

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

class _NavMapPainter extends CustomPainter {
  const _NavMapPainter(this.markers, this.walkPolyline);

  final List<V3LiveRouteMarker> markers;
  final List<V3GeoPoint> walkPolyline;

  @override
  void paint(Canvas canvas, Size size) {
    const padding = 22.0;
    // 마커 + 보행 polyline 전체를 포함하는 bounding box로 정규화한다.
    final lats = <double>[
      ...markers.map((m) => m.latitude),
      ...walkPolyline.map((p) => p.latitude),
    ];
    final lngs = <double>[
      ...markers.map((m) => m.longitude),
      ...walkPolyline.map((p) => p.longitude),
    ];
    if (lats.isEmpty) return;
    final minLat = lats.reduce((a, b) => a < b ? a : b);
    final maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLng = lngs.reduce((a, b) => a < b ? a : b);
    final maxLng = lngs.reduce((a, b) => a > b ? a : b);

    Offset project(double lat, double lng) {
      final lngSpan = maxLng - minLng;
      final latSpan = maxLat - minLat;
      final xRatio = lngSpan == 0 ? 0.5 : (lng - minLng) / lngSpan;
      final yRatio = latSpan == 0 ? 0.5 : (lat - minLat) / latSpan;
      return Offset(
        padding + xRatio * (size.width - padding * 2),
        size.height - padding - yRatio * (size.height - padding * 2),
      );
    }

    // 1) 보행 경로 polyline(현재 위치 -> 승차 정류장)
    if (walkPolyline.length >= 2) {
      final path = Path()
        ..moveTo(project(walkPolyline.first.latitude, walkPolyline.first.longitude).dx,
            project(walkPolyline.first.latitude, walkPolyline.first.longitude).dy);
      for (final p in walkPolyline.skip(1)) {
        final pt = project(p.latitude, p.longitude);
        path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.green
          ..strokeWidth = 3.5
          ..style = PaintingStyle.stroke,
      );
    }

    // 2) 승차 -> 하차 방향 보조선
    final board = markers.where((m) => m.type == 'BOARD_STOP').toList();
    final alight = markers.where((m) => m.type == 'ALIGHT_STOP').toList();
    if (board.isNotEmpty && alight.isNotEmpty) {
      final a = project(board.first.latitude, board.first.longitude);
      final b = project(alight.first.latitude, alight.first.longitude);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = Colors.blueGrey.withValues(alpha: 0.6)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    // 3) 마커
    for (final marker in markers) {
      final point = project(marker.latitude, marker.longitude);
      final radius = marker.type == 'BUS'
          ? 8.0
          : marker.type == 'NEARBY'
              ? 4.0
              : 7.0;
      canvas.drawCircle(point, radius, Paint()..color = _liveRouteColor(marker.type));
    }
  }

  @override
  bool shouldRepaint(covariant _NavMapPainter oldDelegate) {
    return oldDelegate.markers != markers ||
        oldDelegate.walkPolyline != walkPolyline;
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

class _UtteranceCard extends StatelessWidget {
  const _UtteranceCard({
    required this.controller,
    required this.isBusy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isBusy;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '음성 실패 대비 텍스트 fallback',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'utterance',
              ),
              onSubmitted: (_) => isBusy ? null : onSend(),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: isBusy ? null : onSend,
              icon: const Icon(Icons.send),
              label: const Text('Agent에 보내기'),
            ),
          ],
        ),
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

class _RoutePlanningOverlay extends StatelessWidget {
  const _RoutePlanningOverlay({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Semantics(
            liveRegion: true,
            label: message,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  '생각 중...',
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
