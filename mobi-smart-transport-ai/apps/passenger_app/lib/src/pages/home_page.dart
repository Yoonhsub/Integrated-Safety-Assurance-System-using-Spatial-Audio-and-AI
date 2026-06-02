import 'package:flutter/material.dart';

import '../services/api_base_url.dart';
import '../services/audio_haptic_cue_service.dart';
import '../services/backend_api_client.dart';
import '../services/v3_agent_api_client.dart';
import '../services/voice_guide_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.agentName,
    required this.onEditAgentName,
    required this.onReturnToModeSelection,
    required this.dataMode,
  });

  final String agentName;
  final VoidCallback onEditAgentName;
  final VoidCallback onReturnToModeSelection;
  final String dataMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static final String _apiBaseUrl = resolveApiBaseUrl();

  static const String _defaultBusStopId = 'mock-stop-001';
  static const String _passengerUserId = 'passenger-demo-001';
  static const String _defaultTargetDriverId = 'ride-driver-001';
  static const String _v3VoiceSessionId = 'home-voice-session';
  static const double _webDemoOriginLat = 36.6359;
  static const double _webDemoOriginLng = 127.4596;

  BusArrivalSummary? _busArrivalSummary;
  bool _isLoadingBusArrivals = true;
  String _selectedStopId = _defaultBusStopId;
  String? _selectedRouteId;
  String? _selectedBusNo;
  final String _targetDriverId = _defaultTargetDriverId;

  final VoiceGuideService _voiceGuideService = VoiceGuideService();
  final AudioHapticCueService _cueService = AudioHapticCueService();

  final BackendApiClient _backendApiClient = BackendApiClient(
    baseUrl: _apiBaseUrl,
    useMockData: false,
  );

  final V3AgentApiClient _v3AgentApiClient = V3AgentApiClient(
    baseUrl: _apiBaseUrl,
  );

  BackendHealthStatus? _backendHealthStatus;
  bool _isLoadingBackendHealth = true;

  RideRequestCreateResult? _rideRequestCreateResult;
  bool _isCreatingRideRequest = false;

  RideRequestStatusResult? _rideRequestStatusResult;
  bool _isLoadingRideRequestStatus = false;

  FirebaseStatusResult? _firebaseStatus;
  bool _isLoadingFirebaseStatus = false;
  bool _isInitializingFirebase = false;
  bool _firebaseReset = false;
  FirebaseInitializeResult? _firebaseInitResult;

  @override
  void dispose() {
    _voiceGuideService.cancelListening();
    _cueService.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadBackendHealthStatus();
    _loadPassengerHomeSnapshot();
    _loadBusArrivalSummary();
    _loadFirebaseStatus();
  }

  Future<void> _loadFirebaseStatus() async {
    setState(() {
      _isLoadingFirebaseStatus = true;
    });

    final status = await _backendApiClient.fetchFirebaseStatus();

    if (!mounted) return;

    setState(() {
      _firebaseStatus = status;
      _isLoadingFirebaseStatus = false;
    });
  }

  Future<void> _initializeFirebaseDemo() async {
    setState(() {
      _isInitializingFirebase = true;
    });

    final result =
        await _backendApiClient.initializeFirebaseDemo(reset: _firebaseReset);

    if (!mounted) return;

    setState(() {
      _firebaseInitResult = result;
      _isInitializingFirebase = false;
    });

    final snackMessage = !result.ok
        ? result.message
        : result.isRealFirebase
            ? 'Firebase 데모 DB 초기화 완료'
            : '서비스 계정이 없어 mock DB에 초기화됨';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(snackMessage)),
    );

    if (result.ok && result.seededPaths.isNotEmpty) {
      await _showSeededPathsDialog(result);
    }

    // 초기화 후 상태/건강/도착 정보를 다시 로드한다.
    await _loadFirebaseStatus();
    if (!mounted) return;
    await _loadBackendHealthStatus();
    if (!mounted) return;
    await _loadBusArrivalSummary();
  }

  Future<void> _showSeededPathsDialog(FirebaseInitializeResult result) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            result.isRealFirebase ? 'Firebase 초기화 완료' : 'mock DB 초기화 완료',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('mode: ${result.mode}${result.reset ? ' (reset)' : ''}'),
                const SizedBox(height: 8),
                const Text('seed된 경로:'),
                const SizedBox(height: 4),
                ...result.seededPaths.map((path) => Text('• $path')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadBusArrivalSummary() async {
    final busArrivalSummary = await _backendApiClient.fetchBusArrivalSummary(
      stopId: _defaultBusStopId,
    );

    if (!mounted) return;

    setState(() {
      _busArrivalSummary = busArrivalSummary;
      _selectedStopId = busArrivalSummary.stopId;
      _selectedRouteId = busArrivalSummary.selectedRouteId;
      _selectedBusNo = busArrivalSummary.selectedBusNo;
      _isLoadingBusArrivals = false;
    });
  }

  Future<void> _loadPassengerHomeSnapshot() async {
    final snapshot = await _backendApiClient.fetchPassengerHomeSnapshot();

    if (!mounted) return;

    setState(() {
      _homeSnapshot = snapshot;
      _isLoadingHomeSnapshot = false;
    });
  }

  Future<void> _loadBackendHealthStatus() async {
    final healthStatus = await _backendApiClient.fetchHealthStatus();

    if (!mounted) return;

    setState(() {
      _backendHealthStatus = healthStatus;
      _isLoadingBackendHealth = false;
    });
  }

  Future<void> _createRideRequest() async {
    final draft = _buildRideRequestDraft();

    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('탑승 요청에 필요한 노선 또는 버스 선택 정보가 없습니다.'),
        ),
      );
      return;
    }

    setState(() {
      _isCreatingRideRequest = true;
    });

    final result = await _backendApiClient.createRideRequest(draft: draft);

    if (!mounted) return;

    setState(() {
      _rideRequestCreateResult = result;
      _isCreatingRideRequest = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.description),
      ),
    );
  }

  RideRequestDraft? _buildRideRequestDraft() {
    final routeId = _selectedRouteId;
    final busNo = _selectedBusNo;

    if (routeId == null || routeId.isEmpty || busNo == null || busNo.isEmpty) {
      return null;
    }

    return RideRequestDraft(
      userId: _passengerUserId,
      stopId: _selectedStopId,
      routeId: routeId,
      busNo: busNo,
      targetDriverId: _targetDriverId,
    );
  }

  PassengerHomeSnapshot? _homeSnapshot;
  bool _isLoadingHomeSnapshot = true;

  bool _isListening = false;
  bool _isSubmittingVoiceDestination = false;
  String _voiceStatusMessage = '아직 음성 안내가 시작되지 않았습니다.';

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      final recognizedWords = _voiceGuideService.lastRecognizedWords.trim();
      final message = await _voiceGuideService.stopListening();

      if (!mounted) return;

      setState(() {
        _isListening = false;
        _voiceStatusMessage = message;
      });

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

      if (recognizedWords.isNotEmpty) {
        await _submitRecognizedDestination(recognizedWords);
      }

      return;
    }

    await _cueService.playDing();
    final message = await _voiceGuideService.startListening(
      onResult: (recognizedWords) {
        if (!mounted) return;

        setState(() {
          _voiceStatusMessage = recognizedWords.isEmpty
              ? '목적지 입력을 기다리고 있습니다.'
              : '인식 중: $recognizedWords';
        });
      },
    );

    if (!mounted) return;

    setState(() {
      _isListening = true;
      _voiceStatusMessage = message;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('띠링. 목적지를 말해줘.')),
    );
  }

  Future<void> _submitRecognizedDestination(String recognizedWords) async {
    if (_isSubmittingVoiceDestination) return;

    setState(() {
      _isSubmittingVoiceDestination = true;
      _voiceStatusMessage = '인식된 목적지로 경로를 계산하고 있습니다: $recognizedWords';
    });

    try {
      final utterance = recognizedWords.contains(widget.agentName)
          ? recognizedWords
          : '${widget.agentName}, $recognizedWords';
      final response = await _v3AgentApiClient.converse(
        sessionId: _v3VoiceSessionId,
        wakeWord: widget.agentName,
        utterance: utterance,
        mode: widget.dataMode,
        originLat: _webDemoOriginLat,
        originLng: _webDemoOriginLng,
      );

      if (!mounted) return;

      setState(() {
        _voiceStatusMessage = response.message;
      });

      await _speakWithGeminiOrDing(response.message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response.message)));
    } on V3ApiException catch (error) {
      if (!mounted) return;
      final message = '음성 목적지 처리 실패: $error';
      setState(() {
        _voiceStatusMessage = message;
      });
      await _cueService.playDing();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingVoiceDestination = false;
        });
      }
    }
  }

  Future<void> _speakCurrentStatusGuide() async {
    final message = '안녕, 나는 ${widget.agentName}야. 내 말 잘 들려?';

    setState(() {
      _voiceStatusMessage = message;
    });

    await _speakWithGeminiOrDing(message);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _speakWithGeminiOrDing(String message) async {
    try {
      final audioBytes = await _v3AgentApiClient.synthesizeSpeech(text: message);
      await _cueService.playGeneratedSpeech(audioBytes);
    } on V3ApiException {
      await _cueService.playDing();
    }
  }

  Future<void> _loadRideRequestStatus() async {
    final requestId = _rideRequestCreateResult?.requestId;

    if (requestId == null || requestId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('조회할 탑승 요청 식별자가 없습니다.'),
        ),
      );
      return;
    }

    setState(() {
      _isLoadingRideRequestStatus = true;
    });

    final result = await _backendApiClient.fetchRideRequestStatus(
      requestId: requestId,
    );

    if (!mounted) return;

    setState(() {
      _rideRequestStatusResult = result;
      _isLoadingRideRequestStatus = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.description),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final voiceButtonLabel = _isListening ? '음성 입력 종료' : '음성으로 목적지 입력';
    final safetyStatus = _homeSnapshot?.safetyStatus;
    final rideRequestStatus = _homeSnapshot?.rideRequestStatus;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MOBI 탑승객 데모', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '초기 화면으로',
            onPressed: widget.onReturnToModeSelection,
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: '에이전트 이름 변경',
            onPressed: widget.onEditAgentName,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HeaderSection(),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: widget.dataMode == 'live'
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                      : Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.dataMode == 'live' ? Icons.cloud_done : Icons.science,
                      size: 18,
                      color: widget.dataMode == 'live'
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.dataMode == 'live' ? '실제 API 데이터 모드' : 'Mock 데이터 모드',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: widget.dataMode == 'live'
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('시연 시나리오 선택', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _StatusCard(
                title: '에이전트 호출 이름',
                statusLabel: widget.agentName,
                description: '${widget.agentName}라고 부르면 버스 탑승 보조 에이전트가 응답합니다.',
                icon: Icons.record_voice_over_outlined,
                semanticHint: '오른쪽 위 편집 버튼에서 에이전트 이름을 다시 정할 수 있습니다.',
              ),
              const SizedBox(height: 16),
              _StatusCard(
                title: '백엔드 연결 상태',
                statusLabel: _isLoadingBackendHealth
                    ? '확인 중'
                    : (_backendHealthStatus?.isAvailable ?? false)
                        ? '연결 성공'
                        : '연결 실패',
                description:
                    _backendHealthStatus?.message ?? '백엔드 연결 상태를 확인하는 중입니다.',
                icon: Icons.cloud_done_outlined,
                semanticHint: '실제 /health API 연결 성공 또는 실패 상태를 표시하는 영역입니다.',
              ),
              const SizedBox(height: 16),
              _FirebaseDemoCard(
                status: _firebaseStatus,
                isLoadingStatus: _isLoadingFirebaseStatus,
                isInitializing: _isInitializingFirebase,
                reset: _firebaseReset,
                lastInitResult: _firebaseInitResult,
                onResetChanged: (value) {
                  setState(() {
                    _firebaseReset = value;
                  });
                },
                onCheckStatus: _isLoadingFirebaseStatus ? null : _loadFirebaseStatus,
                onInitialize:
                    _isInitializingFirebase ? null : _initializeFirebaseDemo,
              ),
              const SizedBox(height: 16),
              Semantics(
                button: true,
                label: 'V3 버스 탑승 보조 화면 열기',
                hint: '두 번 탭하면 V3 음성 기반 버스 탑승 보조 화면으로 이동합니다.',
                child: SizedBox(
                  height: 64,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed('/v3-guidance'),
                    icon: const Icon(Icons.assistant_navigation),
                    label: Text(
                      '${widget.agentName} 버스 탑승 보조 열기',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _VoiceActionButton(
                label: voiceButtonLabel,
                isListening: _isListening,
                onPressed: _toggleVoiceInput,
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                label: '현재 상태 음성 안내',
                hint: '두 번 탭하면 백엔드 연결 상태, 버스 도착 정보, 탑승 요청 상태를 음성으로 안내합니다.',
                child: SizedBox(
                  height: 64,
                  child: OutlinedButton.icon(
                    onPressed: _speakCurrentStatusGuide,
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: const Text(
                      '현재 상태 음성 안내',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _StatusCard(
                title: '음성 안내 상태',
                statusLabel: _isSubmittingVoiceDestination
                    ? '경로 계산 중'
                    : _isListening
                        ? '입력 중'
                        : '대기 중',
                description: _voiceStatusMessage,
                icon: Icons.volume_up_outlined,
                semanticHint: _isListening
                    ? '현재 음성 입력을 기다리는 중입니다.'
                    : _isSubmittingVoiceDestination
                        ? '인식된 목적지를 에이전트에게 보내는 중입니다.'
                        : '음성 입력이 시작되지 않았거나 종료된 상태입니다.',
              ),
              const SizedBox(height: 16),
              _StatusCard(
                title: '안전 상태',
                statusLabel: _isLoadingHomeSnapshot
                    ? '불러오는 중'
                    : safetyStatus?.statusLabel ?? 'mock 대기',
                description:
                    safetyStatus?.description ?? '안전 상태 정보를 불러오는 중입니다.',
                icon: Icons.shield_outlined,
                semanticHint: safetyStatus?.semanticHint ??
                    '실제 geofence API 연동 전 mock 안전 상태를 표시하는 영역입니다.',
              ),
              const SizedBox(height: 16),
              _StatusCard(
                title: '버스 도착 정보',
                statusLabel: _isLoadingBusArrivals
                    ? '불러오는 중'
                    : _busArrivalSummary?.statusLabel ?? '도착 정보 없음',
                description:
                    _busArrivalSummary?.description ?? '버스 도착 정보를 불러오는 중입니다.',
                icon: Icons.directions_bus_outlined,
                semanticHint: _busArrivalSummary?.semanticHint ??
                    '버스 도착 정보 API 또는 mock 도착 정보를 불러오는 중입니다.',
              ),
              const SizedBox(height: 16),
              _StatusCard(
                title: '탑승 요청 상태',
                statusLabel: _isCreatingRideRequest
                    ? '요청 중'
                    : _isLoadingRideRequestStatus
                        ? '조회 중'
                        : _rideRequestStatusResult?.statusLabel ??
                            _rideRequestCreateResult?.statusLabel ??
                            rideRequestStatus?.statusLabel ??
                            '요청 전',
                description: _isCreatingRideRequest
                    ? '탑승 요청을 생성하는 중입니다.'
                    : _isLoadingRideRequestStatus
                        ? '탑승 요청 상태를 조회하는 중입니다.'
                        : _rideRequestStatusResult?.description ??
                            _rideRequestCreateResult?.description ??
                            rideRequestStatus?.description ??
                            '탑승 요청 상태를 불러오는 중입니다.',
                icon: Icons.accessible_forward_outlined,
                semanticHint: _rideRequestStatusResult?.semanticHint ??
                    _rideRequestCreateResult?.semanticHint ??
                    rideRequestStatus?.semanticHint ??
                    '탑승 요청 생성 전 상태를 표시하는 영역입니다.',
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                label: _isCreatingRideRequest ? '탑승 요청 생성 중' : '탑승 요청 생성',
                hint: '두 번 탭하면 기사에게 전달할 탑승 요청 생성을 시도합니다.',
                child: SizedBox(
                  height: 64,
                  child: ElevatedButton.icon(
                    onPressed:
                        _isCreatingRideRequest ? null : _createRideRequest,
                    icon: Icon(
                      _isCreatingRideRequest
                          ? Icons.hourglass_empty
                          : Icons.accessible_forward_outlined,
                    ),
                    label: Text(
                      _isCreatingRideRequest ? '탑승 요청 중...' : '탑승 요청하기',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                button: true,
                label: _isLoadingRideRequestStatus
                    ? '탑승 요청 상태 조회 중'
                    : '탑승 요청 상태 조회',
                hint: '두 번 탭하면 생성된 탑승 요청의 현재 상태를 조회합니다.',
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: _isLoadingRideRequestStatus
                        ? null
                        : _loadRideRequestStatus,
                    icon: Icon(
                      _isLoadingRideRequestStatus
                          ? Icons.hourglass_empty
                          : Icons.refresh_outlined,
                    ),
                    label: Text(
                      _isLoadingRideRequestStatus ? '상태 조회 중...' : '상태 조회',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const _MvpNoticeCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderSection extends StatelessWidget {
  const _HeaderSection();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: 'MOBI 승객 앱 홈 화면',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '안전한 이동을 도와드릴게요',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '음성 안내와 큰 버튼 중심으로 승객이 쉽게 이용할 수 있도록 구성한 홈 화면입니다.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _VoiceActionButton extends StatelessWidget {
  const _VoiceActionButton({
    required this.label,
    required this.isListening,
    required this.onPressed,
  });

  final String label;
  final bool isListening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      hint: isListening ? '두 번 탭하면 음성 입력을 종료합니다.' : '두 번 탭하면 음성 입력을 시작합니다.',
      child: SizedBox(
        height: 120,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(
            isListening ? Icons.stop_circle_outlined : Icons.mic,
            size: 42,
          ),
          label: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(120),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    required this.statusLabel,
    required this.description,
    required this.icon,
    required this.semanticHint,
  });

  final String title;
  final String statusLabel;
  final String description;
  final IconData icon;
  final String semanticHint;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title, 상태 $statusLabel, $description',
      hint: semanticHint,
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusHeader(title: title, statusLabel: statusLabel),
                    const SizedBox(height: 10),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FirebaseDemoCard extends StatelessWidget {
  const _FirebaseDemoCard({
    required this.status,
    required this.isLoadingStatus,
    required this.isInitializing,
    required this.reset,
    required this.lastInitResult,
    required this.onResetChanged,
    required this.onCheckStatus,
    required this.onInitialize,
  });

  final FirebaseStatusResult? status;
  final bool isLoadingStatus;
  final bool isInitializing;
  final bool reset;
  final FirebaseInitializeResult? lastInitResult;
  final ValueChanged<bool> onResetChanged;
  final Future<void> Function()? onCheckStatus;
  final Future<void> Function()? onInitialize;

  String get _modeLabel {
    if (isLoadingStatus && status == null) return 'unknown';
    return status?.mode ?? 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    final s = status;
    final theme = Theme.of(context);

    return Semantics(
      container: true,
      label: 'Firebase 데모 DB 관리, 현재 mode $_modeLabel',
      hint: 'Firebase 상태를 확인하고 백엔드 Admin SDK를 통해 데모 데이터를 초기화할 수 있는 영역입니다.',
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.local_fire_department_outlined, size: 32),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _StatusHeader(
                      title: 'Firebase 데모 DB',
                      statusLabel: isLoadingStatus && s == null
                          ? '확인 중'
                          : _modeLabel,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (s == null && isLoadingStatus)
                const Text('Firebase 상태를 불러오는 중입니다.')
              else if (s == null)
                const Text('Firebase 상태를 아직 확인하지 못했습니다. "Firebase 상태 확인"을 눌러주세요.')
              else ...[
                _kv('mode', s.mode),
                _kv('initialized', s.initialized ? 'true' : 'false'),
                _kv('credentialsReady', s.credentialsReady ? 'true' : 'false'),
                _kv('serviceAccountExists',
                    s.serviceAccountExists ? 'true' : 'false'),
                _kv('Realtime Database URL', s.databaseUrl ?? '(미설정)'),
                if (s.lastError != null && s.lastError!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'lastError: ${s.lastError}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(s.message, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('기존 데모 데이터 덮어쓰기(reset)'),
                subtitle: const Text('demo 관련 경로만 삭제 후 다시 seed 합니다.'),
                value: reset,
                onChanged: isInitializing ? null : onResetChanged,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCheckStatus == null
                          ? null
                          : () {
                              onCheckStatus!();
                            },
                      icon: Icon(isLoadingStatus
                          ? Icons.hourglass_empty
                          : Icons.refresh_outlined),
                      label: Text(isLoadingStatus ? '확인 중...' : 'Firebase 상태 확인'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onInitialize == null
                          ? null
                          : () {
                              onInitialize!();
                            },
                      icon: Icon(isInitializing
                          ? Icons.hourglass_empty
                          : Icons.cloud_sync_outlined),
                      label: Text(
                        isInitializing ? '초기화 중...' : 'Firebase 데모 DB 초기화',
                      ),
                    ),
                  ),
                ],
              ),
              if (lastInitResult != null &&
                  lastInitResult!.seededPaths.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '최근 seed (${lastInitResult!.mode}'
                  '${lastInitResult!.reset ? ', reset' : ''}): '
                  '${lastInitResult!.seededPaths.length}개 경로',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text('$key: $value'),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.title, required this.statusLabel});

  final String title;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        Semantics(
          label: '상태 $statusLabel',
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                statusLabel,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MvpNoticeCard extends StatelessWidget {
  const _MvpNoticeCard();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'MVP 안내, 현재 화면은 승객 앱 핵심 흐름을 확인하기 위한 초안입니다.',
      hint: '실제 버스 도착 정보, 안전 상태, 탑승 요청 데이터는 담당 모듈 계약 확정 후 연결됩니다.',
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 30),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '현재 화면은 4월 MVP 기준의 승객 앱 UI 초안입니다. '
                  '버스 도착 정보, 안전 상태, 탑승 요청 데이터는 담당 모듈 계약 확정 후 연결됩니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
