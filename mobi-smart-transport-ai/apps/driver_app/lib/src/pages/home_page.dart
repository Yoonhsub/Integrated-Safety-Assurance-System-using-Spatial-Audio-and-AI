import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<_MockRideRequest> _rideRequests = const [
    _MockRideRequest(
      passengerLabel: '시각 보조가 필요한 승객',
      boardingPointText: '중앙 정류장 인근',
      destinationText: '시청 방향',
      assistanceText: '탑승 위치 확인과 음성 안내가 필요한 요청입니다.',
    ),
  ];

  final Set<int> _confirmedRequestIndexes = <int>{};

  void _confirmRideRequest(int index) {
    setState(() {
      _confirmedRequestIndexes.add(index);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('mock 탑승 요청을 확인 완료 상태로 변경했습니다.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingRequestCount =
        _rideRequests.length - _confirmedRequestIndexes.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MOBI 기사 앱'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HeaderSection(),
              const SizedBox(height: 24),
              _InfoCard(
                title: '운행 상태',
                statusLabel: pendingRequestCount > 0 ? '요청 수신' : '대기 중',
                description: pendingRequestCount > 0
                    ? '확인 대기 중인 mock 탑승 요청이 $pendingRequestCount건 있습니다.'
                    : '현재 확인 대기 중인 mock 탑승 요청이 없습니다.',
                icon: Icons.directions_bus_filled_outlined,
                semanticHint: '기사 앱 운행 상태와 mock 탑승 요청 수신 상태를 안내하는 영역입니다.',
              ),
              const SizedBox(height: 16),
              const _InfoCard(
                title: '탑승 요청 연결',
                statusLabel: 'mock 목록 표시',
                description:
                    '실제 GET /drivers/{driverId}/ride-requests API 연동 전까지 mock 탑승 요청 목록을 표시합니다.',
                icon: Icons.notifications_active_outlined,
                semanticHint: '실제 탑승 요청 API 연동 전 mock 목록을 표시하는 영역입니다.',
              ),
              const SizedBox(height: 16),
              _RideRequestListSection(
                rideRequests: _rideRequests,
                confirmedRequestIndexes: _confirmedRequestIndexes,
                onConfirm: _confirmRideRequest,
              ),
              const SizedBox(height: 16),
              const _DriverMvpNoticeCard(),
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
            '탑승 요청을 안전하게 확인하세요',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '시각장애인과 노약자 승객의 탑승 요청을 확인할 수 있는 기사 앱 기본 화면입니다.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _RideRequestListSection extends StatelessWidget {
  const _RideRequestListSection({
    required this.rideRequests,
    required this.confirmedRequestIndexes,
    required this.onConfirm,
  });

  final List<_MockRideRequest> rideRequests;
  final Set<int> confirmedRequestIndexes;
  final ValueChanged<int> onConfirm;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'mock 탑승 요청 목록, 총 ${rideRequests.length}건',
      hint: '실제 rideRequests API 연동 전 mock 요청 목록입니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '탑승 요청 목록',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          for (final entry in rideRequests.asMap().entries) ...[
            _MockRideRequestCard(
              request: entry.value,
              isConfirmed: confirmedRequestIndexes.contains(entry.key),
              onConfirm: () => onConfirm(entry.key),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _MockRideRequestCard extends StatelessWidget {
  const _MockRideRequestCard({
    required this.request,
    required this.isConfirmed,
    required this.onConfirm,
  });

  final _MockRideRequest request;
  final bool isConfirmed;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final statusLabel = isConfirmed ? '확인 완료' : '확인 대기';

    return Semantics(
      container: true,
      label:
          'mock 탑승 요청, 상태 $statusLabel, ${request.passengerLabel}, 승차 위치 ${request.boardingPointText}, 목적지 ${request.destinationText}',
      hint: '실제 API 요청이 아닌 기사 앱 화면 확인용 mock 탑승 요청입니다.',
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusHeader(
                title: 'mock 탑승 요청',
                statusLabel: statusLabel,
              ),
              const SizedBox(height: 14),
              _RequestInfoRow(
                label: '승객',
                value: request.passengerLabel,
              ),
              const SizedBox(height: 8),
              _RequestInfoRow(
                label: '승차 위치',
                value: request.boardingPointText,
              ),
              const SizedBox(height: 8),
              _RequestInfoRow(
                label: '목적지',
                value: request.destinationText,
              ),
              const SizedBox(height: 8),
              _RequestInfoRow(
                label: '지원 필요 사항',
                value: request.assistanceText,
              ),
              const SizedBox(height: 18),
              Semantics(
                button: true,
                label: isConfirmed ? '이미 확인된 mock 탑승 요청' : 'mock 탑승 요청 확인',
                hint: isConfirmed
                    ? '이미 확인 완료된 요청입니다.'
                    : '두 번 탭하면 mock 탑승 요청 상태를 확인 완료로 변경합니다.',
                child: SizedBox(
                  height: 64,
                  child: ElevatedButton.icon(
                    onPressed: isConfirmed ? null : onConfirm,
                    icon: Icon(
                      isConfirmed
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                    ),
                    label: Text(
                      isConfirmed ? '확인 완료' : '요청 확인',
                      style: const TextStyle(
                        fontSize: 20,
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
    );
  }
}

class _RequestInfoRow extends StatelessWidget {
  const _RequestInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, $value',
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyLarge,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: value),
          ],
        ),
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
                    _StatusHeader(
                      title: title,
                      statusLabel: statusLabel,
                    ),
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
  const _StatusHeader({
    required this.title,
    required this.statusLabel,
  });

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
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        Semantics(
          label: '상태 $statusLabel',
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outline,
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              child: Text(
                statusLabel,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DriverMvpNoticeCard extends StatelessWidget {
  const _DriverMvpNoticeCard();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'MVP 안내, 현재 화면은 기사 앱 탑승 요청 흐름을 확인하기 위한 초안입니다.',
      hint: '실제 탑승 요청 목록과 요청 처리 기능은 rideRequests 파이프라인 확정 후 연결됩니다.',
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
                  '현재 화면은 4월 MVP 기준의 기사 앱 UI 초안입니다. '
                  '실제 탑승 요청 목록과 요청 처리 기능은 rideRequests 파이프라인 확정 후 연결됩니다.',
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

class _MockRideRequest {
  const _MockRideRequest({
    required this.passengerLabel,
    required this.boardingPointText,
    required this.destinationText,
    required this.assistanceText,
  });

  final String passengerLabel;
  final String boardingPointText;
  final String destinationText;
  final String assistanceText;
}