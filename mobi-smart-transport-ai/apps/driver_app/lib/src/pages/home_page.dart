import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MOBI 기사 앱'),
        centerTitle: true,
      ),
      body: const SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderSection(),
              SizedBox(height: 24),
              _DriverStatusCard(),
              SizedBox(height: 16),
              _RideRequestNoticeCard(),
              SizedBox(height: 16),
              _SampleRideRequestCard(),
              SizedBox(height: 16),
              _DriverMvpNoticeCard(),
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

class _DriverStatusCard extends StatelessWidget {
  const _DriverStatusCard();

  @override
  Widget build(BuildContext context) {
    return const _InfoCard(
      title: '운행 상태',
      statusLabel: '대기 중',
      description: '현재는 탑승 요청 수신을 준비하는 기본 화면입니다.',
      icon: Icons.directions_bus_filled_outlined,
      semanticHint: '기사 앱 운행 상태를 안내하는 영역입니다.',
    );
  }
}

class _RideRequestNoticeCard extends StatelessWidget {
  const _RideRequestNoticeCard();

  @override
  Widget build(BuildContext context) {
    return const _InfoCard(
      title: '탑승 요청 연결',
      statusLabel: '연결 예정',
      description: '탑승 요청 정보는 rideRequests 파이프라인 확정 후 표시됩니다.',
      icon: Icons.notifications_active_outlined,
      semanticHint: '아직 실제 탑승 요청 데이터와 연결되지 않은 안내 영역입니다.',
    );
  }
}

class _SampleRideRequestCard extends StatelessWidget {
  const _SampleRideRequestCard();
  
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '정적 예시 탑승 요청 카드, 실제 요청 정보가 아닌 화면 초안입니다.',
      hint: 'rideRequests 구조 확정 후 실제 탑승 요청 목록으로 교체됩니다.',
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StatusHeader(
                title: '탑승 요청 예시',
                statusLabel: '예시',
              ),
              const SizedBox(height: 12),
              Text(
                '승객의 탑승 요청 정보가 이 영역에 표시될 예정입니다.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '정류장, 노선, 차량, 요청 상태 등 세부 정보는 담당 파이프라인 확정 후 연결합니다.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              Semantics(
                button: true,
                label: '탑승 요청 확인 예시 버튼',
                hint: '현재는 실제 요청 처리 없이 화면 구조만 확인합니다.',
                child: SizedBox(
                  height: 64,
                  child: ElevatedButton.icon(
                    onPressed: null,
                    icon: Icon(Icons.check_circle_outline),
                    label: Text(
                      '요청 확인 준비 중',
                      style: TextStyle(
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
              padding: EdgeInsets.symmetric(
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