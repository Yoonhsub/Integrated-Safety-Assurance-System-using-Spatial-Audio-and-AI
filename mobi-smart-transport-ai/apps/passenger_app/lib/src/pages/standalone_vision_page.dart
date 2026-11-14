import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../local_vision/local_vision_page.dart';
import '../services/audio_shutdown.dart';
import '../services/local_demo_beacon_mapping.dart';
import '../services/native_directional_cue_output.dart';
import '../services/spatial_verification_engine.dart';
import '../services/speech_priority_coordinator.dart';
import '../widgets/guidance_beacon_panel.dart';

/// Device-only demonstration. No AuthSession, API client, Lease or server UID.
/// Owns the same existing engine/coordinator pair used by online Guidance.
class StandaloneVisionPage extends StatefulWidget {
  const StandaloneVisionPage({super.key, this.engine});
  // Optional existing engine injection for offline widget verification.
  final SpatialVerificationEngine? engine;
  @override
  State<StandaloneVisionPage> createState() => _StandaloneVisionPageState();
}

class _StandaloneVisionPageState extends State<StandaloneVisionPage>
    with WidgetsBindingObserver {
  SpatialVerificationEngine? _engine;
  SpeechPriorityCoordinator? _priority;
  late final LocalDemoBeaconMapping _mapping;
  String? _target;
  bool _disposed = false, _foreground = true, _cameraOpen = false;
  int _revision = 0;
  String? _error;
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _bleCurrent => !_disposed && _foreground && !_cameraOpen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mapping = LocalDemoBeaconMapping.fromEnvironment();
    if (_supported) {
      final output = NativeDirectionalCueOutput();
      _engine = widget.engine ??
          SpatialVerificationEngine(
            output,
            FlutterSpeechEngine.platform(
              requireOfflineKoreanVoice: true,
              requestNativeFocus: true,
              diagnostic: output.recordTtsEvent,
            ),
            allowDirectTestCommands: false,
          );
      _priority = SpeechPriorityCoordinator(_engine!);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Camera and BLE children already stop on background; their pinned guards
    // also reject any delayed callback while this page is inactive.
  }

  Future<void> _openCamera() async {
    if (!_bleCurrent || _engine == null || _priority == null) return;
    final revision = ++_revision;
    setState(() {
      _cameraOpen = true;
      _error = null;
    });
    PriorityLease? barrier;
    try {
      // Finish any existing informational BLE speech before handing over audio.
      barrier = await _priority!.acquirePriority();
      if (!mounted || _disposed || revision != _revision) return;
      barrier.release();
      barrier = null;
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => LocalVisionPage(
                bundledModel: true,
                previewEngine: _engine,
                previewPriority: _priority,
                previewScope: 'LOCAL_DEMO:camera:$revision',
                sessionCurrent: () =>
                    mounted &&
                    !_disposed &&
                    _foreground &&
                    _cameraOpen &&
                    revision == _revision,
              )));
    } catch (error) {
      debugPrint('Standalone camera audio handover: ${error.runtimeType}');
      if (mounted) {
        setState(() => _error = '오디오 종료 상태를 확인해 주세요. 로컬 카메라를 열지 못했습니다.');
      }
    } finally {
      barrier?.release();
      if (mounted && !_disposed && revision == _revision) {
        setState(() {
          _cameraOpen = false;
          _revision++;
        });
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    final engine = _engine, priority = _priority;
    if (engine != null) {
      unawaited(observeAudioCleanup(() async {
        try {
          await engine.dispose();
        } finally {
          priority!.dispose();
        }
      }, channel: 'LOCAL_DEMO audio', report: debugPrint));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: const Text('장애물 탐지'),
      actions: [
        IconButton(
          tooltip: '이어폰·BLE 기기 점검',
          icon: const Icon(Icons.headphones_outlined),
          onPressed: () => Navigator.of(context).pushNamed('/device-check'),
        ),
      ],
    );
    if (!_supported) {
      return Scaffold(
        appBar: appBar,
        body: const Center(child: Text('휴대폰 단독 카메라·음향은 Android에서 지원합니다.')),
      );
    }
    final targets = <String, (String, String)>{};
    for (final row in _mapping.identities) {
      final bus = row.busId, route = row.routeNo;
      if (bus != null && route != null) targets['$bus/$route'] = (bus, route);
    }
    final target = targets[_target];
    return Scaffold(
      appBar: appBar,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Backend 미연결 · 카메라와 음향은 휴대폰에서 실행합니다. PC·USB 연결이 필요하지 않습니다.'),
        const SizedBox(height: 16),
        Text('카메라로 주변 확인', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _cameraOpen ? null : _openCamera,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(_cameraOpen ? '카메라 화면 준비 중' : '로컬 카메라·음향 시작'),
        ),
        const Text(
            '모델은 앱에 포함되어 있습니다. 카메라 시작 후 화면 음향 시연 스위치를 직접 켜세요. 한국어 오프라인 TTS 음성이 설치되어 있어야 합니다.'),
        if (_cameraOpen)
          Semantics(
              liveRegion: true,
              child: LinearProgressIndicator(semanticsLabel: '카메라 화면 준비 중')),
        if (_error != null)
          Semantics(
              liveRegion: true,
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!_cameraOpen) ...[
          const Divider(),
          const Text('BLE · 서버 없이 실제 스캔 / 로컬 시연 매핑만 사용'),
          if (targets.isNotEmpty)
            DropdownButton<String>(
              value: _target,
              hint: const Text('시연용 목표 버스 선택'),
              isExpanded: true,
              items: targets.entries
                  .map((e) => DropdownMenuItem(
                        value: e.key,
                        child: Text('${e.value.$2}번 · ${e.value.$1} (시연 매핑)'),
                      ))
                  .toList(),
              onChanged: (value) => setState(() {
                _target = value;
                _revision++;
              }),
            ),
          GuidanceBeaconPanel(
            key: ValueKey(_revision),
            sessionId: 'LOCAL_DEMO_NO_SERVER_SESSION',
            scopeVersion: _revision,
            ownerUid: 'LOCAL_DEMO_NO_ACCOUNT',
            targetBusId: target?.$1,
            routeNo: target?.$2,
            priority: _priority!,
            captureGuard: () {
              final revision = _revision;
              return () => _bleCurrent && revision == _revision;
            },
            captureAudioGuard: () {
              final revision = _revision;
              return () => _bleCurrent && revision == _revision;
            },
            authChanges: const Stream<Object?>.empty(),
            demoMapping: _mapping,
          ),
        ],
      ]),
    );
  }
}
