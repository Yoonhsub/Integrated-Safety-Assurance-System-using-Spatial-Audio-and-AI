import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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

  // 백엔드에 데이터 모드 전환 요청을 보내는 메서드
  Future<void> _selectMode(String mode) async {
    if (_isSwitching) return;
    setState(() => _isSwitching = true);

    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/config/data-mode'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'mode': mode}),
      ).timeout(const Duration(seconds: 5));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        widget.onModeSelected(mode);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('모드 전환 실패: HTTP ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('백엔드 연결 실패: $e')),
      );
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
                Icon(Icons.directions_bus, size: 64, color: colorScheme.primary),
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
                  '데모 테스트 모드를 선택해주세요',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 48),
                // Mock 데이터 모드 카드
                _ModeCard(
                  icon: Icons.science_outlined,
                  title: 'Mock 데이터 테스트',
                  description: '미리 준비된 시연용 데이터로 테스트합니다.\n버스 도착 정보가 고정된 mock 데이터로 제공됩니다.',
                  color: colorScheme.tertiary,
                  isBusy: _isSwitching,
                  onTap: () => _selectMode('mock'),
                ),
                const SizedBox(height: 20),
                // 실제 API 데이터 모드 카드
                _ModeCard(
                  icon: Icons.cloud_download_outlined,
                  title: '실제 API 데이터 테스트',
                  description: '충청북도 청주시 공공데이터 API에서\n실시간 버스 도착 정보를 가져옵니다.',
                  color: colorScheme.primary,
                  isBusy: _isSwitching,
                  onTap: () => _selectMode('live'),
                ),
                // 전환 중 로딩 표시
                if (_isSwitching) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
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
    return SizedBox(
      width: double.infinity,
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
    );
  }
}
