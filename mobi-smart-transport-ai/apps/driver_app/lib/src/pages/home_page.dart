import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MOBI 기사 앱')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          Text('탑승 요청 목록', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          SizedBox(height: 16),
          Card(
            child: ListTile(
              title: Text('아직 실제 요청 연동 전입니다.'),
              subtitle: Text('심현석의 rideRequests API와 연동 예정'),
            ),
          ),
        ],
      ),
    );
  }
}
