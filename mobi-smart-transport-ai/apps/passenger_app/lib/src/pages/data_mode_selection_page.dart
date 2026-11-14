import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../services/api_base_url.dart';

class DataModeSelectionPage extends StatefulWidget {
  const DataModeSelectionPage({super.key, required this.onModeSelected});

  final void Function(String mode) onModeSelected;

  @override
  State<DataModeSelectionPage> createState() => _DataModeSelectionPageState();
}

class _DataModeSelectionPageState extends State<DataModeSelectionPage> {
  // 빌드 define이 없으면 웹은 현재 origin을 사용한다(배포본 localhost 호출 방지).
  static final String _apiBaseUrl = resolveApiBaseUrl();

  bool _isSwitching = false;
  String? _error;

  // 백엔드에 데이터 모드 전환 요청을 보내는 메서드
  Future<void> _selectMode(String mode) async {
    if (_isSwitching) return;

    if (mode == 'mock') {
      widget.onModeSelected(mode);
      return;
    }
    setState(() {
      _isSwitching = true;
      _error = null;
    });

    try {
      final response = await AuthenticatedApiClient(
        onUnauthorized: FirebaseAuthSession.instance.signOut,
      )
          .post(
            Uri.parse('$_apiBaseUrl/config/data-mode'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'mode': mode}),
          )
          .timeout(const Duration(seconds: 5));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        widget.onModeSelected(mode);
      } else {
        setState(() => _error =
            '실시간 데이터를 불러오지 못했습니다. 연결 상태를 확인하고 같은 모드를 다시 선택해 주세요. (HTTP ${response.statusCode})');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error =
          '서버에 연결하지 못했습니다. 인터넷과 서버 연결을 확인한 뒤 다시 선택해 주세요. 시연 데이터는 실제 도착정보가 아닙니다.');
    } finally {
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 앱 로고 아이콘
                Icon(
                  Icons.directions_bus,
                  size: 64,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 16),
                // 앱 제목
                Text(
                  'MOBI 스마트 교통 시스템',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                // 안내 텍스트
                Text(
                  '노선 검색에 사용할 데이터를 선택해 주세요',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 48),
                // Mock 데이터 모드 카드
                _ModeCard(
                  icon: Icons.science_outlined,
                  title: '시연 데이터',
                  description:
                      '미리 준비된 시연용 데이터로 테스트합니다.\n버스 도착 정보가 고정된 mock 데이터로 제공됩니다.',
                  color: colorScheme.tertiary,
                  isBusy: _isSwitching,
                  onTap: () => _selectMode('mock'),
                ),
                const SizedBox(height: 20),
                // 실제 API 데이터 모드 카드
                _ModeCard(
                  icon: Icons.cloud_download_outlined,
                  title: '실시간 노선 검색',
                  description: '충청북도 청주시 공공데이터 API에서\n실시간 버스 도착 정보를 가져옵니다.',
                  color: colorScheme.primary,
                  isBusy: _isSwitching,
                  onTap: () => _selectMode('live'),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _isSwitching
                      ? null
                      : () => Navigator.of(context).pushNamed('/local-vision'),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('휴대폰 로컬 카메라 관찰'),
                ),
                if (kDebugMode &&
                    !kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.android)
                  OutlinedButton.icon(
                    onPressed: _isSwitching
                        ? null
                        : () =>
                            Navigator.of(context).pushNamed('/native-audio'),
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('음성·방향 확인 (Android)'),
                  ),
                OutlinedButton.icon(
                  onPressed: _isSwitching
                      ? null
                      : () => Navigator.of(context).pushNamed('/hardware-bus'),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('실기기 연동확인'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                          style: TextStyle(color: colorScheme.error))),
                ],
                // 전환 중 로딩 표시
                if (_isSwitching) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(
                      semanticsLabel: '실시간 데이터 연결 중'),
                  const SizedBox(height: 8),
                  const Text('모드 전환 중...'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 모드 선택 카드 위젯
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.isBusy,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
        button: true,
        enabled: !isBusy,
        label: '$title. $description',
        onTap: isBusy ? null : onTap,
        excludeSemantics: true,
        child: SizedBox(
          width: double.infinity,
          child: Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: isBusy ? null : onTap,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    // 아이콘 컨테이너
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: color, size: 28),
                    ),
                    const SizedBox(width: 20),
                    // 텍스트 영역
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    // 화살표 아이콘
                    Icon(Icons.arrow_forward_ios, color: color, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ));
  }
}
