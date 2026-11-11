import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

const mobiInk = Color(0xFF173550);
const mobiBlue = Color(0xFF2378F3);
ThemeData passengerTheme() => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: mobiBlue),
      scaffoldBackgroundColor: const Color(0xFFF6F8FB),
      appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF6F8FB),
          foregroundColor: mobiInk,
          centerTitle: false),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 56),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)))),
      textTheme: const TextTheme(
          headlineMedium: TextStyle(
              fontWeight: FontWeight.w800, color: mobiInk, height: 1.4),
          titleLarge: TextStyle(fontWeight: FontWeight.w700, color: mobiInk)),
    );

class PassengerLanding extends StatelessWidget {
  const PassengerLanding({super.key, required this.onOnline});
  final VoidCallback onOnline;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('MOBI.',
                style:
                    TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2))),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('당신의 이동을 더 편하게',
              style: TextStyle(color: mobiBlue, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text('주변을 인식하고,\n소리로 확인하세요.',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          const Text('카메라 화면에 보이는 객체와 화면 속 위치를 안내합니다.',
              style: TextStyle(height: 1.7)),
          const SizedBox(height: 24),
          Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                  color: mobiInk, borderRadius: BorderRadius.circular(24)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.center_focus_strong,
                        color: Colors.white, size: 42),
                    const SizedBox(height: 18),
                    const Text('카메라로 주변 확인',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.bold)),
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text('휴대폰 단독 모드 · 로그인이나 PC 연결 없이 사용할 수 있습니다.',
                            style: TextStyle(
                                color: Color(0xFFCDDFEF), height: 1.7))),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                            onPressed: () => Navigator.of(context)
                                .pushNamed('/standalone-vision'),
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('카메라 인식 시작'))),
                  ])),
          const SizedBox(height: 20),
          OutlinedButton.icon(
              onPressed: onOnline,
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('온라인 서비스 연결')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pushNamed('/device-check'),
              icon: const Icon(Icons.headphones_outlined),
              label: const Text('이어폰·BLE 기기 점검')),
          const SizedBox(height: 24),
          const Text('화면 기준의 정보성 시연입니다. 실제 거리·출입문·승차 가능 여부는 판단하지 않습니다.',
              style: TextStyle(color: Color(0xFF617087), height: 1.7)),
        ])),
      );
}

class DeviceCheckPage extends StatelessWidget {
  const DeviceCheckPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('기기 점검')),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
        Text('소리와 연결을 확인하세요', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const Text('실제 연결 상태는 각 점검 화면에서 확인합니다. 여기서 자동으로 소리나 스캔을 시작하지 않습니다.',
            style: TextStyle(height: 1.7)),
        const SizedBox(height: 24),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.volume_up_outlined),
                          title: Text('음성·방향 소리'),
                          subtitle: Text('기존 Android 오디오 점검 · 온라인 로그인 필요')),
                      OutlinedButton(
                          onPressed: () =>
                              Navigator.of(context).pushNamed('/native-audio'),
                          child: const Text('음성·방향 확인 (Android)')),
                    ]))),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.bluetooth_searching),
                          title: Text('BLE 비콘 점검'),
                          subtitle: Text('휴대폰 단독 모드에서 등록된 시연 매핑을 확인합니다.')),
                      OutlinedButton(
                          onPressed: () => Navigator.of(context)
                              .pushNamed('/standalone-vision'),
                          child: const Text('휴대폰 단독 모드 열기')),
                    ]))),
        const SizedBox(height: 16),
        const Text('고급 하드웨어 진단', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
            'BLE/WT901/HRTF · 테스트 매핑과 가정 방향을 사용합니다. 실제 위험 Guidance와 구분됩니다.',
            style: TextStyle(height: 1.7)),
        const SizedBox(height: 12),
        OutlinedButton(
            onPressed: () => Navigator.of(context).pushNamed('/hardware-bus'),
            child: const Text('실기기 연동확인 · BLE/WT901/HRTF')),
        if (kDebugMode &&
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android)
          OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).pushNamed('/door-approach'),
              child: const Text('탑승문 접근·중단 시연 (실측 BLE)')),
      ])));
}
