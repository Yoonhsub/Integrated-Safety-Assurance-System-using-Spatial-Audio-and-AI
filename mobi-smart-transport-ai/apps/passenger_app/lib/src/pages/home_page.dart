import 'package:flutter/material.dart';

import '../services/voice_guide_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final VoiceGuideService _voiceGuideService = const VoiceGuideService();

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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

      return;
    }

    final message = await _voiceGuideService.startListening();

    if (!mounted) return;

    setState(() {
      _isListening = true;
      _voiceStatusMessage = message;
    });

    final guideMessage = await _voiceGuideService.speakGuide(
      '목적지를 말씀해주세요.',
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(guideMessage)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final voiceButtonLabel =
        _isListening ? '음성 입력 종료' : '음성으로 목적지 입력';

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
            children: [
              const _HeaderSection(),
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
              const _StatusCard(
                title: '안전 상태',
                statusLabel: '연결 예정',
                description: '안전 상태 정보는 geofence API 계약 확정 후 표시됩니다.',
                icon: Icons.shield_outlined,
                semanticHint: '아직 실제 안전 상태 API와 연결되지 않은 안내 영역입니다.',
              ),
              const SizedBox(height: 16),
              const _StatusCard(
                title: '버스 도착 정보',
                statusLabel: '연결 예정',
                description: '버스 도착 정보는 공공데이터 mock 기준 확정 후 표시됩니다.',
                icon: Icons.directions_bus_outlined,
                semanticHint: '아직 실제 버스 도착 정보와 연결되지 않은 안내 영역입니다.',
              ),
              const SizedBox(height: 16),
              const _StatusCard(
                title: '탑승 요청 상태',
                statusLabel: '요청 전',
                description: '탑승 요청 상태는 rideRequests 파이프라인 확정 후 표시됩니다.',
                icon: Icons.accessible_forward_outlined,
                semanticHint: '아직 탑승 요청이 생성되지 않은 상태입니다.',
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
      label: 'MOBI 승객 앱 홈 화면',
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
      hint: isListening
          ? '두 번 탭하면 음성 입력을 종료합니다.'
          : '두 번 탭하면 음성 입력을 시작합니다.',
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
            style: const TextStyle(
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