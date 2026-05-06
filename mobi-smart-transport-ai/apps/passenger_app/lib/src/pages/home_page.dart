import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MOBI 사용자 앱')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            Text('어디로 가시나요?', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            SizedBox(height: 24),
            _AccessibleActionButton(label: '목적지를 음성으로 입력하기'),
            SizedBox(height: 16),
            _AccessibleActionButton(label: '현재 버스 도착 정보 확인'),
            SizedBox(height: 16),
            _AccessibleActionButton(label: '탑승 요청 보내기'),
            SizedBox(height: 16),
            _AccessibleActionButton(label: '안전 상태 다시 듣기'),
          ],
        ),
      ),
    );
  }
}

class _AccessibleActionButton extends StatelessWidget {
  const _AccessibleActionButton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ElevatedButton(
        onPressed: () {},
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(72)),
        child: Text(label, style: const TextStyle(fontSize: 22)),
      ),
    );
  }
}
