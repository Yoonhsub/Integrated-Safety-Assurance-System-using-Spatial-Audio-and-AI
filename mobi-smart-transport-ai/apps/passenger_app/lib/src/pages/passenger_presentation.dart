import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/speech_priority_coordinator.dart';

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

class PassengerLanding extends StatefulWidget {
  const PassengerLanding({
    super.key,
    required this.onOnline,
    this.speech,
    this.onSignOut,
    this.showSignOut = false,
  });
  final VoidCallback onOnline;
  final SpeechPriorityCoordinator? speech;
  final VoidCallback? onSignOut;
  final bool showSignOut;

  @override
  State<PassengerLanding> createState() => _PassengerLandingState();
}

enum _LandingDestination { routeInfo, vision }

class _PassengerLandingState extends State<PassengerLanding> {
  final _speechOwner = Object();
  Timer? _tapWindow;
  _LandingDestination? _pending;
  int _speechRequest = 0;
  bool _opening = false;

  SpeechPriorityCoordinator get _speech =>
      widget.speech ?? sharedSpeechPriority;
  bool get _usesTapConfirmation =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _describe(String description, int request) async {
    try {
      await _speech.speakObservation(
        _speechOwner,
        description,
        () => mounted && request == _speechRequest && !_opening,
      );
    } catch (error) {
      debugPrint('MOBI home description: ${error.runtimeType}');
    }
  }

  Future<void> _stopDescription() async {
    try {
      await _speech.stopObservation(_speechOwner);
    } catch (error) {
      debugPrint('MOBI home description stop: ${error.runtimeType}');
    }
  }

  Future<void> _open(_LandingDestination destination) async {
    if (_opening) return;
    _opening = true;
    _pending = null;
    _tapWindow?.cancel();
    if (_speechRequest > 0) {
      _speechRequest++;
      unawaited(_stopDescription());
    }
    try {
      if (destination == _LandingDestination.routeInfo) {
        widget.onOnline();
      } else {
        await Navigator.of(context).pushNamed('/standalone-vision');
      }
    } finally {
      _opening = false;
    }
  }

  void _tap(_LandingDestination destination, String description) {
    if (_opening) return;
    if (!_usesTapConfirmation || _pending == destination) {
      unawaited(_open(destination));
      return;
    }
    _pending = destination;
    _tapWindow?.cancel();
    _tapWindow =
        Timer(const Duration(milliseconds: 500), () => _pending = null);
    unawaited(_describe(description, ++_speechRequest));
  }

  Widget _screenReaderButton(
    _LandingDestination destination,
    String label,
    String description,
    Widget child,
  ) =>
      _usesTapConfirmation
          ? Semantics(
              excludeSemantics: true,
              button: true,
              label: label,
              hint: description,
              onTap: () => unawaited(_open(destination)),
              child: child,
            )
          : child;

  @override
  void dispose() {
    _tapWindow?.cancel();
    if (_speechRequest > 0) {
      _speechRequest++;
      unawaited(_stopDescription());
    }
    super.dispose();
  }

  static const _routeLabel = '노선 정보 검색';
  static const _routeDescription = '채팅이나 음성으로 버스 노선과 도착 정보를 물어보세요.';
  static const _visionLabel = '장애물 탐지';
  static const _visionDescription = '카메라로 객체를 감지하고 화면 기준 위치를 소리로 확인합니다.';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('MOBI.',
                style:
                    TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
            actions: [
              if (widget.showSignOut)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: mobiInk,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: widget.onSignOut,
                  child: const Text('로그아웃'),
                ),
            ]),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          Text('무엇을 도와드릴까요?',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          if (_usesTapConfirmation) ...[
            const Text('한 번 누르면 설명을 듣고, 같은 버튼을 빠르게 두 번 누르면 열립니다.'),
            const SizedBox(height: 16),
          ],
          _screenReaderButton(
            _LandingDestination.routeInfo,
            _routeLabel,
            _routeDescription,
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: mobiInk,
                foregroundColor: Colors.white,
              ),
              onPressed: () =>
                  _tap(_LandingDestination.routeInfo, _routeDescription),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text(_routeLabel),
            ),
          ),
          const SizedBox(height: 8),
          const Text(_routeDescription),
          const SizedBox(height: 24),
          _screenReaderButton(
            _LandingDestination.vision,
            _visionLabel,
            _visionDescription,
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: mobiInk,
                backgroundColor: Colors.white,
                side: const BorderSide(color: mobiInk, width: 2),
              ),
              onPressed: () =>
                  _tap(_LandingDestination.vision, _visionDescription),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text(_visionLabel),
            ),
          ),
          const SizedBox(height: 8),
          const Text(_visionDescription),
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
      ])));
}
