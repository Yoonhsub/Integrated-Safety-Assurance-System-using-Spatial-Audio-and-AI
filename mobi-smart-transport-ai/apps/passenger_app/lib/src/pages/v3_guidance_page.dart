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
  static const bool _webDemoOriginEnabled = bool.fromEnvironment(
    'MOBI_WEB_DEMO_ORIGIN_ENABLED',
    defaultValue: true,
  );
  static const double _webDemoOriginLat = 36.6359;
  static const double _webDemoOriginLng = 127.4596;

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
  bool _usingWebDemoOrigin = false;
  bool _useMockHeadTracking = false;
  HeadTrackingDebugSnapshot _headTracking =
      HeadTrackingDebugSnapshot.disabled();
  Timer? _liveRouteTimer;
  V3LiveRouteStatusResponse? _liveRouteStatus;
  Position? _lastRoutePosition;
  String? _liveRouteError;
  bool _liveRoutePanelVisible = false;
  bool _isLiveRouteLoading = false;
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

  Future<_RoutePlanningPreparation> _beginRoutePlanning() async {
    _liveRouteTimer?.cancel();
    _liveRouteTimer = null;
    setState(() {
      _isRoutePlanning = true;
      _routePlanningStatus = _routePlanningMessage;
      _liveRoutePanelVisible = false;
      _liveRouteStatus = null;
      _liveRouteError = null;
    });
    await _cueService.playDing();

    try {
      final position = await _currentPosition();
      if (mounted) {
        setState(() {
          _usingWebDemoOrigin = false;
        });
      }
      return _RoutePlanningPreparation(position: position);
    } catch (_) {
      if (kIsWeb && _webDemoOriginEnabled) {
        if (mounted) {
          setState(() {
            _usingWebDemoOrigin = true;
          });
        }
        return _RoutePlanningPreparation(
          position: _webDemoPosition(),
          usesDemoOrigin: true,
        );
      }
      return const _RoutePlanningPreparation();
    }
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
    _liveRouteTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _liveRoutePanelVisible = true;
      _liveRouteStatus = null;
      _liveRouteError = null;
      _lastRoutePosition = position;
    });
    await _refreshLiveRouteStatus();
    if (!mounted || !_liveRoutePanelVisible) return;
    _liveRouteTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_isLiveRouteLoading) {
        unawaited(_refreshLiveRouteStatus());
      }
    });
  }

  Future<void> _refreshLiveRouteStatus() async {
    if (_isLiveRouteLoading) return;
    final plan = _lastRoutePlan?.recommendedPlan;
    if (plan == null || plan.segments.isEmpty) return;
    final segment = plan.segments.first;
    setState(() {
      _isLiveRouteLoading = true;
    });
    try {
      final status = await _client.liveRouteStatus(
        routeNo: segment.routeNo,
        routeId: segment.routeId,
        boardStopId: segment.boardStop.stopId,
        alightStopId: segment.alightStop.stopId,
        userLat: _lastRoutePosition?.latitude,
        userLng: _lastRoutePosition?.longitude,
        boardLat: segment.boardStop.latitude,
        boardLng: segment.boardStop.longitude,
        alightLat: segment.alightStop.latitude,
        alightLng: segment.alightStop.longitude,
        mode: widget.dataMode,
      );
      if (!mounted || !_liveRoutePanelVisible) return;
      setState(() {
        _liveRouteStatus = status;
        _liveRouteError = null;
      });
    } on V3ApiException catch (error) {
      if (!mounted || !_liveRoutePanelVisible) return;
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

  void _stopLiveRoutePolling({bool clearStatus = false}) {
    _liveRouteTimer?.cancel();
    _liveRouteTimer = null;
    if (!mounted) return;
    setState(() {
      _liveRoutePanelVisible = false;
      _isLiveRouteLoading = false;
      if (clearStatus) {
        _liveRouteStatus = null;
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
    final locationLabel = preparation.usesDemoOrigin
        ? '웹 시연 기준 위치(사창사거리)로'
        : preparation.position == null
            ? '현재 위치 없이'
            : '현재 위치 기준으로';
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
    if (!await Geolocator.isLocationServiceEnabled()) {
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
        timeLimit: Duration(seconds: 8),
      ),
    );
  }

  Position _webDemoPosition() {
    return Position(
      latitude: _webDemoOriginLat,
      longitude: _webDemoOriginLng,
      timestamp: DateTime.now(),
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: true,
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
        _usingWebDemoOrigin = false;
        _liveRoutePanelVisible = false;
        _liveRouteStatus = null;
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
                  if (_usingWebDemoOrigin) ...[
                    const SizedBox(height: 12),
                    const _WebDemoOriginBanner(),
                  ],
                  if (_liveRoutePanelVisible) ...[
                    const SizedBox(height: 12),
                    _LiveRouteStatusCard(
                      status: _liveRouteStatus,
                      routePlan: _lastRoutePlan,
                      isLoading: _isLiveRouteLoading,
                      errorMessage: _liveRouteError,
                      onClose: () => _stopLiveRoutePolling(clearStatus: true),
                    ),
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

class _WebDemoOriginBanner extends StatelessWidget {
  const _WebDemoOriginBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '웹 시연 기준 위치 사용 중: 브라우저 위치 권한을 사용할 수 없어 '
          '사창사거리 좌표를 기준으로 경로를 계산합니다. 위치 권한을 허용하면 실제 사용자 위치를 사용합니다.',
        ),
      ),
    );
  }
}

class _LiveRouteStatusCard extends StatelessWidget {
  const _LiveRouteStatusCard({
    required this.status,
    required this.routePlan,
    required this.isLoading,
    required this.onClose,
    this.errorMessage,
  });

  final V3LiveRouteStatusResponse? status;
  final V3RoutePlanResponse? routePlan;
  final bool isLoading;
  final VoidCallback onClose;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final plan = routePlan?.recommendedPlan;
    final segment =
        plan?.segments.isNotEmpty == true ? plan!.segments.first : null;
    final firstArrival =
        status?.arrivals.isNotEmpty == true ? status!.arrivals.first : null;
    final serviceStatus = status?.serviceStatus ?? segment?.serviceStatus;
    final eta =
        firstArrival == null ? '미확인' : '${firstArrival.arrivalMinutes}분 뒤';
    final remainingStops = firstArrival?.remainingStops == null
        ? '미확인'
        : '${firstArrival!.remainingStops}정류장 전';
    final congestion = firstArrival?.congestion ?? '미제공';
    final markers = status?.markers ?? const <V3LiveRouteMarker>[];
    final busPositionMessage = status?.busPositions.isEmpty != false
        ? '현재 버스 위치는 아직 조회되지 않았어.'
        : '현재 ${status!.busPositions.length}대의 버스 위치를 조회했어.';

    return Semantics(
      container: true,
      label: '실시간 경로 상태 패널',
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
                  const Icon(Icons.route_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '실시간 경로 상태',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: '실시간 경로 패널 닫기',
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (segment == null)
                const Text('확정된 경로가 없어.')
              else ...[
                Text(
                  '${segment.routeNo}번 · ${plan!.destinationName}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                _LiveMetric(label: '승차', value: segment.boardStop.stopName),
                _LiveMetric(label: '하차', value: segment.alightStop.stopName),
                _LiveMetric(label: '목적지', value: plan.destinationName),
                _LiveMetric(label: '도착 예정', value: eta),
                _LiveMetric(label: '남은 정류장', value: remainingStops),
                _LiveMetric(label: '혼잡도', value: congestion),
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
                Text(busPositionMessage),
                const SizedBox(height: 10),
                const Text(
                  '실제 지도 타일이 아닌 간이 위치도',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 170,
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
                            painter: _LiveRouteSketchPainter(markers),
                            child: const SizedBox.expand(),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    for (final type
                        in markers.map((marker) => marker.type).toSet())
                      _LiveRouteLegend(type: type),
                  ],
                ),
              ],
              if (status != null) ...[
                const SizedBox(height: 8),
                Text('데이터 source: ${status!.fallbackSource}'),
                if (status!.warnings.isNotEmpty)
                  for (final warning in status!.warnings)
                    Text(
                      '주의: $warning',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
              ],
              if (errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMessage!,
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

class _LiveRouteSketchPainter extends CustomPainter {
  const _LiveRouteSketchPainter(this.markers);

  final List<V3LiveRouteMarker> markers;

  @override
  void paint(Canvas canvas, Size size) {
    const padding = 20.0;
    final latitudes = markers.map((marker) => marker.latitude);
    final longitudes = markers.map((marker) => marker.longitude);
    final minLat = latitudes.reduce((a, b) => a < b ? a : b);
    final maxLat = latitudes.reduce((a, b) => a > b ? a : b);
    final minLng = longitudes.reduce((a, b) => a < b ? a : b);
    final maxLng = longitudes.reduce((a, b) => a > b ? a : b);

    Offset offsetFor(V3LiveRouteMarker marker) {
      final lngSpan = maxLng - minLng;
      final latSpan = maxLat - minLat;
      final xRatio = lngSpan == 0 ? 0.5 : (marker.longitude - minLng) / lngSpan;
      final yRatio = latSpan == 0 ? 0.5 : (marker.latitude - minLat) / latSpan;
      return Offset(
        padding + xRatio * (size.width - padding * 2),
        size.height - padding - yRatio * (size.height - padding * 2),
      );
    }

    final routeMarkers =
        markers.where((marker) => marker.type != 'BUS').toList();
    if (routeMarkers.length >= 2) {
      final path = Path()
        ..moveTo(
            offsetFor(routeMarkers.first).dx, offsetFor(routeMarkers.first).dy);
      for (final marker in routeMarkers.skip(1)) {
        final point = offsetFor(marker);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.blueGrey
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
    }

    for (final marker in markers) {
      final point = offsetFor(marker);
      canvas.drawCircle(point, marker.type == 'BUS' ? 8 : 7,
          Paint()..color = _liveRouteColor(marker.type));
    }
  }

  @override
  bool shouldRepaint(covariant _LiveRouteSketchPainter oldDelegate) {
    return oldDelegate.markers != markers;
  }
}

Color _liveRouteColor(String type) {
  return switch (type) {
    'USER' => Colors.indigo,
    'BOARD_STOP' => Colors.green,
    'ALIGHT_STOP' => Colors.orange,
    'BUS' => Colors.red,
    _ => Colors.purple,
  };
}

String _liveRouteLabel(String type) {
  return switch (type) {
    'USER' => '내 위치',
    'BOARD_STOP' => '승차',
    'ALIGHT_STOP' => '하차',
    'BUS' => '버스',
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
  const _RoutePlanningPreparation({
    this.position,
    this.usesDemoOrigin = false,
  });

  final Position? position;
  final bool usesDemoOrigin;
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
