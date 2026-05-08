import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MOBI 승객 앱'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _HeaderSection(),
              SizedBox(height: 24),
              _VoiceActionButton(),
              SizedBox(height: 24),
              _StatusCard(
                title: '음성 안내 상태',
                description: '아직 음성 안내가 시작되지 않았습니다.',
                icon: Icons.volume_up_outlined,
              ),
              SizedBox(height: 16),
              _StatusCard(
                title: '안전 상태',
                description: '안전 상태 정보는 이후 geofence 구현 경계 확정 후 연결됩니다.',
                icon: Icons.shield_outlined,
              ),
              SizedBox(height: 16),
              _StatusCard(
                title: '버스 도착 정보',
                description: '버스 도착 정보는 공공데이터 mock 기준 확정 후 표시됩니다.',
                icon: Icons.directions_bus_outlined,
              ),
              SizedBox(height: 16),
              _StatusCard(
                title: '탑승 요청 상태',
                description: '탑승 요청 상태는 rideRequests 구조 확정 후 표시됩니다.',
                icon: Icons.accessible_forward_outlined,
              ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '안전한 이동을 도와드릴게요',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
  const _VoiceActionButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '음성으로 목적지 입력하기',
      hint: '두 번 탭하면 음성 입력 기능이 시작됩니다.',
      child: SizedBox(
        height: 120,
        child: ElevatedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('음성 입력 기능은 다음 섹션에서 연결됩니다.'),
              ),
            );
          },
          icon: const Icon(Icons.mic, size: 42),
          label: const Text(
            '음성으로 목적지 입력',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
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
    required this.description,
    required this.icon,
  });

  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title, $description',
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
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
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