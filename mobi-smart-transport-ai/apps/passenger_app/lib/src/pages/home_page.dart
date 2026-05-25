import 'package:flutter/material.dart';
import '../services/backend_api_client.dart';
import '../services/voice_guide_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _apiBaseUrl = String.fromEnvironment(
    'MOBI_API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  static const String _defaultBusStopId = 'mock-stop-001';

BusArrivalSummary? _busArrivalSummary;
bool _isLoadingBusArrivals = true;

  final VoiceGuideService _voiceGuideService = VoiceGuideService();

  final BackendApiClient _backendApiClient = const BackendApiClient(
    baseUrl: _apiBaseUrl,
    useMockData: false,
  );

  BackendHealthStatus? _backendHealthStatus;
  bool _isLoadingBackendHealth = true;

  RideRequestCreateResult? _rideRequestCreateResult;
  bool _isCreatingRideRequest = false;

  RideRequestStatusResult? _rideRequestStatusResult;
  bool _isLoadingRideRequestStatus = false;

  @override
    void initState() {
      super.initState();
      _loadBackendHealthStatus();
      _loadPassengerHomeSnapshot();
      _loadBusArrivalSummary();
}

Future<void> _loadBusArrivalSummary() async {
  final busArrivalSummary = await _backendApiClient.fetchBusArrivalSummary(
    stopId: _defaultBusStopId,
  );

  if (!mounted) return;

  setState(() {
    _busArrivalSummary = busArrivalSummary;
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
  setState(() {
    _isCreatingRideRequest = true;
  });

  final result = await _backendApiClient.createRideRequest();

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

  PassengerHomeSnapshot? _homeSnapshot;
  bool _isLoadingHomeSnapshot = true;

  bool _isListening = false;
  String _voiceStatusMessage = '아직 음성 안내가 시작되지 않았습니다.';

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      final message = await _voiceGuideService.stopListening();

      if (!mounted) return;

      setState(() {
        _isListening = false;
        _voiceStatusMessage = message;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

      return;
    }

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

    final guideMessage = await _voiceGuideService.speakGuide('목적지를 말씀해주세요.');

    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(guideMessage)));
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
      appBar: AppBar(title: const Text('MOBI 승객 앱'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HeaderSection(),
              const SizedBox(height: 16),
              _StatusCard(
                title: '백엔드 연결 상태',
                statusLabel: _isLoadingBackendHealth
                  ? '확인 중'
                  : (_backendHealthStatus?.isAvailable ?? false)
                    ? '연결 성공'
                    : '연결 실패',
                description: _backendHealthStatus?.message ??
                  '백엔드 연결 상태를 확인하는 중입니다.',
                icon: Icons.cloud_done_outlined,
                semanticHint: '실제 /health API 연결 성공 또는 실패 상태를 표시하는 영역입니다.',
              ),
              const SizedBox(height: 24),
              _VoiceActionButton(
                label: voiceButtonLabel,
                isListening: _isListening,
                onPressed: _toggleVoiceInput,
              ),
              const SizedBox(height: 24),
              _StatusCard(
                title: '음성 안내 상태',
                statusLabel: _isListening ? '입력 중' : '대기 중',
                description: _voiceStatusMessage,
                icon: Icons.volume_up_outlined,
                semanticHint: _isListening
                    ? '현재 음성 입력을 기다리는 중입니다.'
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
                description: _busArrivalSummary?.description ??
                   '버스 도착 정보를 불러오는 중입니다.',
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
                    onPressed: _isCreatingRideRequest ? null : _createRideRequest,
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
                    onPressed:
                        _isLoadingRideRequestStatus ? null : _loadRideRequestStatus,
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
