import 'package:flutter/material.dart';

import '../services/backend_api_client.dart';

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

  static const String _driverId = 'ride-driver-001';

  final BackendApiClient _backendApiClient = const BackendApiClient(
    baseUrl: _apiBaseUrl,
    useMockData: false,
  );

  BackendHealthStatus? _backendHealthStatus;
  bool _isLoadingBackendHealth = true;

  DriverRideRequestsResult? _rideRequestsResult;
  bool _isLoadingRideRequests = true;

  RideRequestStatusUpdateResult? _statusUpdateResult;
  bool _isUpdatingRideRequestStatus = false;

  @override
  void initState() {
    super.initState();
    _loadBackendHealthStatus();
    _loadDriverRideRequests();
  }

  Future<void> _loadBackendHealthStatus() async {
    final healthStatus = await _backendApiClient.fetchHealthStatus();

    if (!mounted) return;

    setState(() {
      _backendHealthStatus = healthStatus;
      _isLoadingBackendHealth = false;
    });
  }

  Future<void> _loadDriverRideRequests() async {
    final result = await _backendApiClient.fetchDriverRideRequests(
      driverId: _driverId,
    );

    if (!mounted) return;

    setState(() {
      _rideRequestsResult = result;
      _isLoadingRideRequests = false;
    });
  }

  Future<void> _refreshDriverRideRequests() async {
    setState(() {
      _isLoadingRideRequests = true;
    });

    await _loadDriverRideRequests();
  }

  Future<void> _acceptRideRequest(String? requestId) async {
  if (requestId == null || requestId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('상태를 변경할 탑승 요청 식별자가 없습니다.'),
      ),
    );
    return;
  }

  setState(() {
    _isUpdatingRideRequestStatus = true;
  });

  final result = await _backendApiClient.updateRideRequestStatus(
    requestId: requestId,
    status: 'ACCEPTED',
  );

  if (!mounted) return;

  setState(() {
    _statusUpdateResult = result;
    _isUpdatingRideRequestStatus = false;
  });

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(result.description),
    ),
  );

  if (result.isSuccess) {
    await _refreshDriverRideRequests();
  }
}

  @override
  Widget build(BuildContext context) {
    final rideRequests = _rideRequestsResult?.requests ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('MOBI 기사 앱'), centerTitle: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshDriverRideRequests,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const _HeaderSection(),
              const SizedBox(height: 16),
              _InfoCard(
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
              const SizedBox(height: 16),
              const _InfoCard(
                title: '운행 상태',
                statusLabel: '대기 중',
                description: '현재 운행 상태는 기사 앱 UI 확인용 기본 상태입니다.',
                icon: Icons.directions_bus_filled_outlined,
                semanticHint: '기사 운행 상태를 표시하는 영역입니다.',
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: '탑승 요청 목록',
                statusLabel: _isLoadingRideRequests
                    ? '불러오는 중'
                    : _rideRequestsResult?.statusLabel ?? '요청 없음',
                description: _rideRequestsResult?.description ??
                    '기사에게 배정된 탑승 요청 목록을 불러오는 중입니다.',
                icon: Icons.accessible_forward_outlined,
                semanticHint: '기사에게 배정된 탑승 요청 목록 상태를 표시하는 영역입니다.',
              ),

              if (_statusUpdateResult != null) ...[
                const SizedBox(height: 12),
                _InfoCard(
                  title: '상태 변경 결과',
                  statusLabel: _isUpdatingRideRequestStatus
                      ? '변경 중'
                      : _statusUpdateResult?.statusLabel ?? '대기',
                  description: _statusUpdateResult?.description ??
                      '탑승 요청 상태 변경 결과를 기다리는 중입니다.',
                  icon: Icons.check_circle_outline,
                  semanticHint: _statusUpdateResult?.semanticHint ??
                      '탑승 요청 상태 변경 결과를 표시하는 영역입니다.',
                ),
              ],

              const SizedBox(height: 12),
              Semantics(
                button: true,
                label: _isLoadingRideRequests ? '탑승 요청 목록 새로고침 중' : '탑승 요청 목록 새로고침',
                hint: '두 번 탭하면 기사에게 배정된 탑승 요청 목록을 다시 불러옵니다.',
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed:
                        _isLoadingRideRequests ? null : _refreshDriverRideRequests,
                    icon: Icon(
                      _isLoadingRideRequests
                          ? Icons.hourglass_empty
                          : Icons.refresh_outlined,
                    ),
                    label: Text(
                      _isLoadingRideRequests ? '불러오는 중...' : '요청 목록 새로고침',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_isLoadingRideRequests)
                const _InfoCard(
                  title: '요청 카드',
                  statusLabel: '불러오는 중',
                  description: '기사에게 배정된 탑승 요청을 불러오는 중입니다.',
                  icon: Icons.hourglass_empty,
                  semanticHint: '탑승 요청 목록 로딩 상태입니다.',
                )
              else if (rideRequests.isEmpty)
                const _InfoCard(
                  title: '요청 카드',
                  statusLabel: '요청 없음',
                  description: '현재 표시할 탑승 요청이 없습니다.',
                  icon: Icons.inbox_outlined,
                  semanticHint: '기사에게 배정된 탑승 요청이 없는 상태입니다.',
                )
              else
              ...rideRequests.map(
                (request) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _InfoCard(
                        title: request.requestLabel,
                        statusLabel: request.statusLabel,
                        description: request.description,
                        icon: Icons.assignment_outlined,
                        semanticHint: request.semanticHint,
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        button: true,
                        label: '${request.requestLabel} 수락',
                        hint: '두 번 탭하면 해당 탑승 요청을 ACCEPTED 상태로 변경합니다.',
                        child: SizedBox(
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: _isUpdatingRideRequestStatus
                                ? null
                                : () => _acceptRideRequest(request.requestId),
                            icon: Icon(
                              _isUpdatingRideRequestStatus
                                  ? Icons.hourglass_empty
                                  : Icons.check_circle_outline,
                            ),
                            label: Text(
                              _isUpdatingRideRequestStatus ? '처리 중...' : '요청 수락',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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
      label: 'MOBI 기사 앱 홈 화면',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '탑승 요청을 확인하세요',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '승객의 탑승 지원 요청을 확인하고 운행 흐름을 준비하는 기사 앱 화면입니다.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
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
                    _InfoHeader(title: title, statusLabel: statusLabel),
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

class _InfoHeader extends StatelessWidget {
  const _InfoHeader({required this.title, required this.statusLabel});

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
      label: 'MVP 안내, 현재 화면은 기사 앱 핵심 흐름을 확인하기 위한 초안입니다.',
      hint: '실제 탑승 요청 목록과 상태 변경 흐름은 담당 모듈 계약 확정 후 연결됩니다.',
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
                  '현재 화면은 V2 기준의 기사 앱 요청 목록 연동 초안입니다. '
                  '탑승 요청 상태 변경, 기사 수락 흐름, FCM 알림은 후속 섹션에서 검증합니다.',
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