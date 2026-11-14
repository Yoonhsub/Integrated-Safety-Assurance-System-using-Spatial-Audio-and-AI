import 'compact_control_surface.dart';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../local_vision/frame_pump.dart';
import '../../local_vision/vision_codec.dart';
import '../../local_vision/vision_worker.dart';
import '../../services/directional_guidance.dart';
import '../../services/spatial_verification_engine.dart';
import '../../services/speech_priority_coordinator.dart';
import '../../services/vision_scene_summary.dart';
import '../../services/vision_screen_audio.dart';

/// Independent camera lifetime. No BLE, WT, backend or safety ownership.
abstract class ConcurrentCameraSource extends ChangeNotifier {
  bool get running;
  bool get starting;
  String get status;
  LocalObservation? get observation;
  Future<void> start();
  Future<void> stop();
}

class NativeConcurrentCameraSource extends ConcurrentCameraSource {
  NativeConcurrentCameraSource() {
    _pump = FramePump(
        (frame) => _worker!.infer(frame), () => _clock.elapsedMicroseconds);
    _pump.addListener(_changed);
  }
  final _clock = Stopwatch()..start();
  late final FramePump _pump;
  VisionWorker? _worker;
  CameraController? _camera;
  CameraDescription? _description;
  Future<void>? _opening, _closing;
  bool _disposed = false;
  int _generation = 0;
  @override
  bool get running => _pump.active;
  @override
  bool get starting => _opening != null;
  @override
  String status = '카메라 꺼짐 · 다른 장치 연결은 유지됩니다';
  @override
  LocalObservation? get observation => _pump.observation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    _notify();
    if (_pump.error != null && _closing == null) {
      unawaited(_fail('추론 오류: ${_pump.error}. 카메라를 다시 시작해 주세요'));
    }
  }

  Future<void> _fail(String message) async {
    try {
      await stop();
      status = message;
    } catch (_) {
      status = '$message / 카메라 종료 확인 실패: 앱을 다시 시작해 주세요';
    }
    _notify();
  }

  bool _valid(int generation) => !_disposed && generation == _generation;
  @override
  Future<void> start() {
    if (_disposed || running || starting || _closing != null) {
      return Future.value();
    }
    final generation = ++_generation;
    status = '모델·카메라 준비 중';
    final task = _open(generation);
    _opening = task;
    _notify();
    return task.whenComplete(() {
      if (identical(_opening, task)) _opening = null;
      _notify();
    });
  }

  Future<void> _open(int generation) async {
    try {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        throw StateError('Android only');
      }
      final data = await rootBundle.load(
          'assets/models/yolo11n_unified_bus_obstacle_stop_v4_float32.tflite');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await compute(verifyModel, bytes);
      if (!_valid(generation)) return;
      _worker = await VisionWorker.open(bytes);
      if (!_valid(generation)) return;
      final cameras = await availableCameras();
      if (!_valid(generation)) return;
      _description = cameras
          .firstWhere((c) => c.lensDirection == CameraLensDirection.back);
      final camera = CameraController(_description!, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _camera = camera;
      await camera.initialize();
      if (!_valid(generation)) return;
      camera.addListener(() {
        if (identical(_camera, camera) &&
            camera.value.hasError &&
            _closing == null) {
          unawaited(_fail('카메라 연결 오류: 다시 시작해 주세요'));
        }
      });
      _pump.start();
      await camera.startImageStream((image) => _frame(image, generation));
      if (_valid(generation)) status = '카메라 탐지 실행 중';
    } catch (e) {
      if (_valid(generation)) {
        status = e is CameraException && e.code.contains('Access')
            ? '카메라 권한을 앱 설정에서 확인하고 다시 시작해 주세요'
            : '모델·카메라 시작 실패 · 다른 카메라 앱을 닫고 다시 시작해 주세요';
        await _cleanup();
      }
    } finally {
      _notify();
    }
  }

  void _frame(CameraImage image, int generation) {
    if (!_valid(generation) || !_pump.active) return;
    final camera = _camera, description = _description;
    if (camera == null || description == null) return;
    final degrees = switch (camera.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final format =
        image.format.group == ImageFormatGroup.nv21 || image.format.raw == 17
            ? 'nv21'
            : image.format.group == ImageFormatGroup.yuv420
                ? 'yuv420'
                : 'unsupported';
    _pump.submit(VisionFrame(
        width: image.width,
        height: image.height,
        format: format,
        planes: image.planes
            .map((p) => FramePlane(Uint8List.fromList(p.bytes), p.bytesPerRow,
                p.bytesPerPixel ?? 1))
            .toList(),
        rotation: frameRotation(description.sensorOrientation, degrees, false),
        mirror: false,
        receivedAt: DateTime.now().toUtc(),
        receivedMicros: _clock.elapsedMicroseconds));
  }

  Future<void> _cleanup() async {
    final idle = _pump.stop();
    final camera = _camera, worker = _worker;
    _camera = null;
    _worker = null;
    try {
      if (camera?.value.isStreamingImages == true) {
        await camera!.stopImageStream();
      }
    } catch (_) {/* disconnected */}
    try {
      await camera?.dispose();
    } catch (_) {/* disconnected */}
    try {
      await idle;
    } finally {
      await worker?.close();
    }
  }

  @override
  Future<void> stop() {
    if (_closing != null) return _closing!;
    ++_generation;
    status = '카메라 중지 · BLE/WT 연결은 유지됩니다';
    final opening = _opening;
    final task = () async {
      await opening;
      await _cleanup();
    }();
    _closing = task;
    _notify();
    return task.whenComplete(() {
      if (identical(_closing, task)) _closing = null;
      _notify();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pump.removeListener(_changed);
    unawaited(stop().catchError((Object error) {
      debugPrint('Camera cleanup failed: ${error.runtimeType}');
    }).whenComplete(_pump.dispose));
    super.dispose();
  }
}

typedef ConcurrentObservationPlayer = Future<bool> Function(
    Object owner, String command, bool Function() valid);

/// Mounted alongside BLE/WT; audio is explicitly opt-in and shared, not mixed.
class ConcurrentCameraPanel extends StatefulWidget {
  const ConcurrentCameraPanel(
      {super.key,
      required this.priority,
      required this.engine,
      required this.isCurrent,
      this.source,
      this.compact = false,
      this.playObservation});
  final SpeechPriorityCoordinator priority;
  final SpatialVerificationEngine engine;
  final bool Function() isCurrent;
  final ConcurrentCameraSource? source;
  final bool compact;
  final ConcurrentObservationPlayer? playObservation;
  @override
  State<ConcurrentCameraPanel> createState() => _ConcurrentCameraPanelState();
}

class _ConcurrentCameraPanelState extends State<ConcurrentCameraPanel>
    with WidgetsBindingObserver {
  late final ConcurrentCameraSource _source;
  final _tracker = VisionSceneSummaryTracker(confirmationFrames: 3);
  final _owner = Object();
  final _clock = Stopwatch()..start();
  Timer? _expiry;
  Future<void>? _silencing;
  bool _audio = false,
      _pingOnly = false,
      _busy = false,
      _disposed = false,
      _foreground = true;
  int _revision = 0, _sequence = 0;
  int? _lastPlayed;
  String? _lastFrame, _meaning, _activeMeaning;
  DateTime? _lastReceivedAt;
  final _viewRevision = ValueNotifier<int>(0);
  Map<String, Object?> _outputDiagnostic = const {};
  String _status = '화면 위치 소리 OFF';
  String? _audioStopFailure;
  bool get _valid => !_disposed && _foreground && widget.isCurrent();
  @override
  void initState() {
    super.initState();
    if (!identical(widget.priority.engine, widget.engine)) {
      throw ArgumentError('Shared audio owner mismatch');
    }
    _source = widget.source ?? NativeConcurrentCameraSource();
    _source.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _expiry =
        Timer.periodic(const Duration(milliseconds: 150), (_) => _expire());
  }

  void _refresh() {
    if (mounted && !_disposed) {
      _viewRevision.value++;
      setState(() {});
    }
  }

  Future<void> _silence({bool disable = false}) {
    ++_revision;
    _meaning = _activeMeaning = null;
    if (disable) {
      _audio = false;
      _status = '화면 소리 중지 · 새 요청만 허용';
    }
    _outputDiagnostic = {..._outputDiagnostic, 'phase': 'STOP_REQUESTED'};
    if (_silencing != null) return _silencing!;
    final task = () async {
      try {
        await widget.priority.stopObservation(_owner);
      } catch (_) {
        _audio = false;
        _status = '소리 정지 확인 실패: 앱을 다시 시작해 주세요';
        _audioStopFailure = _status;
      } finally {
        _refresh();
      }
    }();
    _silencing = task;
    return task.whenComplete(() => _silencing = null);
  }

  VisionSceneSummary get _scene => _tracker.snapshot(DateTime.now().toUtc());
  bool _wasFresh = false;

  void _expire() {
    final fresh =
        _valid && _source.running && _scene.isFresh(DateTime.now().toUtc());
    if (!fresh && (_meaning != null || _busy)) {
      unawaited(_silence(disable: !_valid));
    }
    if (!fresh && _wasFresh) {
      _status = '관찰 만료 · 현재 화면을 확인하기 어렵습니다';
    }
    if (fresh != _wasFresh) {
      _wasFresh = fresh;
      _refresh();
    }
  }

  void _changed() {
    final item = _source.observation;
    if (!_valid || !_source.running || item == null) {
      if (_source.running) {
        _tracker.invalidate(reason: 'missing_or_inactive_observation');
      } else {
        _tracker.clear(); // A stopped camera starts a new source lifetime.
      }
      _lastFrame = null;
      _status = '관찰 사용 불가 · 새 화면 대기';
      _expire();
      _refresh();
      return;
    }
    if (item.frame.frameId == _lastFrame) return;
    _lastFrame = item.frame.frameId;
    _lastReceivedAt = item.frame.receivedAt;
    try {
      _tracker.update(
          frameId: item.frame.frameId,
          receivedAt: item.frame.receivedAt,
          now: DateTime.now().toUtc(),
          detections: VisionScreenAudio.verifiedDoorDetections(
              item.toDetectionResult()['detections'] as List));
    } catch (_) {
      _tracker.invalidate(reason: 'malformed_observation');
      _status = '관찰 형식 확인 실패 · 새 화면 대기';
      unawaited(_silence());
      return;
    }
    final scene = _scene;
    _meaning = scene.signature;
    _refresh();
    if (_busy && _meaning != _activeMeaning) {
      _status = '장면 변경 · 이전 안내 취소';
      unawaited(_silence());
      return;
    }
    if (!scene.isFresh(DateTime.now().toUtc())) {
      _status = '오래되거나 유효하지 않은 관찰 · 새 화면 대기';
      _refresh();
      return;
    }
    if (!_audio) return;
    // Show transient uncertainty immediately, but do not chatter while confirming.
    if (scene.reason == 'confirming') return;
    final interval = _pingOnly ? 1500 : 8000;
    if (_lastPlayed != null &&
        _clock.elapsedMilliseconds - _lastPlayed! < interval) {
      return;
    }
    unawaited(_playScene(scene));
  }

  Future<void> _playScene(VisionSceneSummary scene,
      {bool detail = false}) async {
    if (_audioStopFailure != null ||
        !_valid ||
        !_source.running ||
        _busy ||
        !scene.isFresh(DateTime.now().toUtc()) ||
        widget.priority.priorityActive ||
        widget.priority.outputUncertain) {
      return;
    }
    final meaning = scene.signature;
    _meaning = meaning;
    // Never collapse multiple objects to a nearest-object directional cue.
    final side =
        scene.status == VisionSceneStatus.single && scene.groups.length == 1
            ? switch (scene.groups.single.side.name) {
                'left' => TestDirection.left,
                'right' => TestDirection.right,
                _ => TestDirection.center,
              }
            : null;
    if (_pingOnly && !detail && side == null) {
      _status = '여러 물체 또는 불확실한 화면은 한 방향의 핑으로 표현하지 않습니다. 자세히 듣기를 이용하세요.';
      _refresh();
      return;
    }
    final revision = _revision;
    bool valid() =>
        _valid &&
        (detail || _audio) &&
        revision == _revision &&
        _source.running &&
        _scene.signature == meaning &&
        scene.isFresh(DateTime.now().toUtc()) &&
        !widget.priority.priorityActive;
    final text = detail ? scene.detailText : scene.briefText;
    var admitted = false;
    final requestedAtMicros = _clock.elapsedMicroseconds;
    _outputDiagnostic = {'phase': 'REQUESTED'};
    final command = widget.engine.registerGuidance(
        DirectionalGuidance(
            guidanceId: 'concurrent-camera-${++_sequence}',
            sessionGeneration: 'concurrent-camera-${identityHashCode(this)}',
            authEpoch: 0,
            priority: GuidancePriority.observation,
            text: text,
            provenance: DirectionalGuidance.screenProvenance,
            testDirection: side,
            directionEvidence: side == null
                ? DirectionEvidence.unverified
                : DirectionEvidence.cameraScreenBbox),
        valid,
        cueOnly: _pingOnly && !detail,
        informationalTone: side == null ? null : InformationalCueTone.neutral,
        phase: (phase) {
      if (!valid()) return;
      _outputDiagnostic = {
        'phase': phase,
        'requestElapsedMicros': _clock.elapsedMicroseconds - requestedAtMicros,
        'callbackObservedAt': DateTime.now().toUtc().toIso8601String()
      };
      _refresh();
    }, admit: () {
      if (!valid()) return false;
      if (!admitted) {
        admitted = true;
        // Throttle from software output admission, including interrupted
        // speech. A dropped shared-audio slot must not consume this budget.
        _lastPlayed = _clock.elapsedMilliseconds;
      }
      return true;
    });
    if (command == null) return;
    _busy = true;
    _activeMeaning = meaning;
    _status = text;
    _refresh();
    try {
      final player = widget.playObservation;
      final played = player != null
          ? await player(_owner, command, valid)
          : await widget.priority.speakObservation(_owner, command, valid);
      if (!played && detail && valid()) {
        _status = '다른 안내가 재생 중입니다. 최신 화면에서 자세히 듣기를 다시 누르세요.';
      }
    } catch (_) {
      if (valid()) {
        _status = '소리 출력 실패 · 오디오 연결을 확인해 주세요';
        _outputDiagnostic = {..._outputDiagnostic, 'phase': 'FAILED'};
      }
    } finally {
      widget.engine.retireGuidance(command);
      _busy = false;
      _activeMeaning = null;
      _refresh();
    }
  }

  Future<void> _stopCamera() async {
    _tracker.clear();
    try {
      await _silence(disable: true);
    } finally {
      try {
        await _source.stop();
      } catch (_) {
        _status = '카메라 종료 확인 실패: 앱을 다시 시작해 주세요';
      }
      _lastFrame = null;
      _refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_stopCamera());
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _source.removeListener(_changed);
    _viewRevision.dispose();
    unawaited(
        widget.priority.stopObservation(_owner).catchError((Object error) {
      debugPrint('Camera audio cleanup failed: ${error.runtimeType}');
    }));
    if (widget.source == null) {
      _source.dispose();
    } else {
      unawaited(_source.stop().catchError((Object error) {
        debugPrint('Camera cleanup failed: ${error.runtimeType}');
      }));
    }
    super.dispose();
  }

  void _showDetails() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => ValueListenableBuilder<int>(
          valueListenable: _viewRevision,
          builder: (routeContext, _, __) {
            final observation = _source.observation;
            return Scaffold(
              key: const ValueKey('concurrent-camera-details-page'),
              appBar: AppBar(
                automaticallyImplyLeading: false,
                title: const Text('카메라 상태와 안내'),
                leading: IconButton(
                  tooltip: 'Close camera details',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(routeContext),
                ),
              ),
              body: SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (observation != null && observation.jpeg.isNotEmpty) ...[
                      Semantics(
                        image: true,
                        label:
                            'Camera preview. The model visualization does not provide distance or safety judgments.',
                        child: SizedBox(
                          height: 180,
                          width: double.infinity,
                          child: Image.memory(
                            observation.jpeg,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                const Text('Preview could not be displayed.'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(_source.status),
                    Text(_source.running
                        ? _scene.detailText
                        : '현재 화면을 확인하기 어렵습니다'),
                    Text(_lastReceivedAt == null
                        ? '프레임 수신 기록 없음'
                        : '마지막 프레임 수신: ${_lastReceivedAt!.toIso8601String()} (촬영 시각 아님)'),
                    Text(visionReceiptAgeLabel(
                        _lastReceivedAt, DateTime.now().toUtc())),
                    if (_source.observation != null)
                      Text(
                          '마지막 추론 ${_source.observation!.inferenceMs.toStringAsFixed(1)} ms · 처리 ${_source.observation!.processingMs.toStringAsFixed(1)} ms (모델 처리 진단)'),
                    Text(
                        '소프트웨어 출력: ${visionSoftwarePhaseLabel(_outputDiagnostic['phase'] as String?)}'),
                    if (_outputDiagnostic['requestElapsedMicros'] != null)
                      Text(
                          '요청 후 콜백 경과: ${_outputDiagnostic['requestElapsedMicros']} µs · 실제 귀 도달 지연 아님'),
                    Text(_audioStopFailure ?? _status),
                    const Text(
                        '시각은 기기가 받은 프레임 수신 시각이며 촬영 시각이 아닙니다. 화면의 왼쪽·가운데·오른쪽 정보만 안내합니다. 거리, 안전 경로, 실제 접근 여부는 판단하지 않습니다. 다른 장치 수집은 소리와 독립적으로 계속됩니다.'),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _compactPanel(BuildContext context, String sceneStatus) {
    final item = _source.observation;
    final cameraState = _source.starting
        ? '준비 중'
        : _source.running
            ? '실행 중'
            : '중지';
    final summary = _source.running ? _scene.briefText : '현재 화면을 확인하기 어렵습니다';
    return CompactControlSurface(
        expandInPage: true,
        label: '카메라',
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text('카메라 $cameraState · $sceneStatus',
                                style: Theme.of(context).textTheme.titleSmall)),
                        IconButton(
                            tooltip: '카메라 상태와 안내 상세',
                            onPressed: _showDetails,
                            icon: const Icon(Icons.info_outline)),
                      ]),
                      Row(children: [
                        Expanded(
                            child: FilledButton(
                                onPressed: _valid &&
                                        !_source.running &&
                                        !_source.starting
                                    ? () => _source.start()
                                    : null,
                                child: const Text('카메라 시작'))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: OutlinedButton(
                                onPressed: _source.running || _source.starting
                                    ? () => _stopCamera()
                                    : null,
                                child: const Text('카메라 중지'))),
                      ]),
                      if (item != null && item.jpeg.isNotEmpty)
                        SizedBox(
                            height: 180,
                            child: Image.memory(item.jpeg,
                                gaplessPlayback: true,
                                errorBuilder: (_, __, ___) =>
                                    const Text('미리보기 표시 불가'))),
                      Semantics(
                          label: summary,
                          child: ExcludeSemantics(
                              child: Text(summary,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis))),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('핑만 재생 (음성 제외)'),
                          value: _pingOnly,
                          onChanged: (v) async {
                            await _silence();
                            if (!_disposed) setState(() => _pingOnly = v);
                          }),
                      Row(children: [
                        Expanded(
                            child: Semantics(
                                label: '화면 위치 소리 시작',
                                child: FilledButton(
                                    onPressed: _valid &&
                                            _source.running &&
                                            !_audio &&
                                            _audioStopFailure == null
                                        ? () {
                                            _lastFrame = null;
                                            _lastPlayed = null;
                                            setState(() {
                                              _audio = true;
                                              _status = '새 프레임부터 화면 위치 소리 시작';
                                            });
                                          }
                                        : null,
                                    child: const Text('소리 시작')))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Semantics(
                                label: '화면 위치 소리 중지',
                                child: OutlinedButton(
                                    onPressed: _audio || _busy
                                        ? () => _silence(disable: true)
                                        : null,
                                    child: const Text('소리 중지')))),
                      ]),
                      Row(children: [
                        Expanded(
                            child: Text(
                                '소리 ${_audio ? 'ON' : 'OFF'}${_busy ? ' · 재생 중' : ''}')),
                        OutlinedButton(
                            onPressed: _valid &&
                                    _source.running &&
                                    !_busy &&
                                    _scene.isFresh(DateTime.now().toUtc())
                                ? () => _playScene(_scene, detail: true)
                                : null,
                            child: const Text('자세히 듣기')),
                      ]),
                      const Text('화면 위치만 안내 · 거리/접근 판단 없음',
                          style: TextStyle(fontSize: 12)),
                    ]))));
  }

  @override
  Widget build(BuildContext context) {
    final item = _source.observation;
    final sceneStatus = !_source.running
        ? '사용 불가'
        : switch (_scene.status) {
            VisionSceneStatus.single => '단일',
            VisionSceneStatus.multiple => '다중',
            VisionSceneStatus.uncertain => '불확실',
            VisionSceneStatus.unavailable => '사용 불가',
          };
    if (widget.compact) return _compactPanel(context, sceneStatus);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('카메라 탐지 · 독립 제어',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(_source.status),
              Semantics(liveRegion: true, child: Text('장면 상태: $sceneStatus')),
              Text(_lastReceivedAt == null
                  ? '프레임 수신 기록 없음'
                  : '마지막 프레임 수신: ${_lastReceivedAt!.toIso8601String()} (촬영 시각 아님)'),
              Wrap(spacing: 8, children: [
                FilledButton(
                    onPressed: _valid && !_source.running && !_source.starting
                        ? () => _source.start()
                        : null,
                    child: const Text('카메라 시작')),
                OutlinedButton(
                    onPressed: _source.running || _source.starting
                        ? () => _stopCamera()
                        : null,
                    child: const Text('카메라 중지')),
              ]),
              if (item != null && item.jpeg.isNotEmpty)
                SizedBox(
                    height: 180,
                    child: Image.memory(item.jpeg,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) =>
                            const Text('미리보기 표시 불가'))),
              if (item != null)
                Text(
                    '검출 ${item.boxes.length}개 · ${item.boxes.map((b) => visionClassNames[b.classId] ?? b.classId).join(', ')}'),
              const Text(
                  '화면 기준 좌·가운데·우 정보입니다. 거리·안전 경로·실제 접근 여부를 판단하지 않습니다. 다른 장치 수집은 소리와 독립적으로 계속됩니다.'),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('핑만 사용 (음성 제외)'),
                  value: _pingOnly,
                  onChanged: (v) async {
                    await _silence();
                    if (!_disposed) {
                      setState(() => _pingOnly = v);
                    }
                  }),
              Wrap(spacing: 8, children: [
                FilledButton(
                    onPressed: _valid &&
                            _source.running &&
                            !_audio &&
                            _audioStopFailure == null
                        ? () {
                            _lastFrame = null;
                            _lastPlayed = null;
                            setState(() {
                              _audio = true;
                              _status = '새 검출부터 화면 위치 소리 시작';
                            });
                          }
                        : null,
                    child: const Text('화면 위치 소리 시작')),
                OutlinedButton(
                    onPressed:
                        _audio || _busy ? () => _silence(disable: true) : null,
                    child: const Text('화면 위치 소리 중지')),
              ]),
              Semantics(
                  liveRegion: true,
                  child: Text(_source.running
                      ? _scene.briefText
                      : '현재 화면을 확인하기 어렵습니다')),
              const Text(
                  '시각 정보 시각은 앱의 프레임 수신 시각이며 촬영 시각이 아닙니다. 거리와 통행 가능 여부는 판단하지 않습니다.'),
              OutlinedButton(
                  onPressed: _valid &&
                          _source.running &&
                          !_busy &&
                          _scene.isFresh(DateTime.now().toUtc())
                      ? () => _playScene(_scene, detail: true)
                      : null,
                  child: const Text('자세히 듣기')),
              Text(visionReceiptAgeLabel(
                  _lastReceivedAt, DateTime.now().toUtc())),
              Text(
                  '소프트웨어 출력: ${visionSoftwarePhaseLabel(_outputDiagnostic['phase'] as String?)}'),
              Text(_audioStopFailure ?? _status),
            ])));
  }
}
