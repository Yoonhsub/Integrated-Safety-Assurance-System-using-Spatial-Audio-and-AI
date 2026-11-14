import 'package:flutter/material.dart';

class ConcurrentHardwareTestPage extends StatelessWidget {
  const ConcurrentHardwareTestPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('기기 점검')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('동시 하드웨어 점검은 Android 앱에서 지원합니다. '
                '웹에서는 카메라·BLE·센서를 시작하지 않습니다.'),
          ),
        ),
      );
}
