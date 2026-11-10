import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'frame_pump.dart';
import 'vision_codec.dart';
import 'vision_worker.dart';
import '../widgets/vision_observation_panel.dart';
import '../services/v3_agent_api_client.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/spatial_verification_engine.dart';
import '../services/vision_screen_audio.dart';
import '../widgets/vision_screen_audio_panel.dart';
import '../features/hardware_bus/wit_sensor_panel.dart';

/// Offline by default. Optional transport and opt-in screen-only information audio.
/// Safety output remains disabled. The shared engine is owned by Guidance.
class LocalVisionPage extends StatefulWidget {
  const LocalVisionPage(
      {super.key,
      this.producer,
      this.remoteApi,
      this.ownerUid,
      this.onEndSession,
      this.beforeStart,
      this.onResult,
      this.onStop,
      this.sessionCurrent,
      this.authChanges,
      this.remoteSessionId,
      this.bundledModel = false,
      this.previewPriority,
      this.previewEngine,
      this.previewScope = 'camera-preview'});
  final DartVisionProducerClient? producer;
  final V3AgentApiClient? remoteApi;
  final String? ownerUid;
  final Future<void> Function()? onEndSession;
  final Future<void> Function()? beforeStart;
  final Future<void> Function(LocalObservation)? onResult;
  final Future<void> Function()? onStop;
  final bool Function()? sessionCurrent;
  final Stream<String?>? authChanges;
  final String? remoteSessionId;
  final bool bundledModel;
  final SpeechPriorityCoordinator? previewPriority;
  final SpatialVerificationEngine? previewEngine;
  final String previewScope;
  @override
  State<LocalVisionPage> createState() => _LocalVisionPageState();
}

class _LocalVisionPageState extends State<LocalVisionPage>
    with WidgetsBindingObserver {
  static const _hardwarePermissions =
      MethodChannel('mobi.passenger/hardware-permissions');
  StreamSubscription<String?>? _authSubscription;
  final _clock = Stopwatch()..start();
  final _runTime = Stopwatch();
  late final FramePump _pump;
  VisionScreenAudio? _previewAudio;
  Uint8List? _model;
  VisionWorker? _worker;
  CameraController? _camera;
  CameraDescription? _description;
  bool _starting = false, _picking = false, _front = false;
  bool _disposing = false, _ending = false;
  int _generation = 0;
  Future<void>? _stopping;
  String _status = '통합 비전 모델 파일을 선택해 주세요';

  Future<bool> _ensureHeadTrackingReady() async {
    if (!Platform.isAndroid) return false;
    final state =
        await _hardwarePermissions.invokeMapMethod<String, dynamic>('request');
    return state?['granted'] == true && state?['locationEnabled'] == true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pump = FramePump(
        (frame) => _worker!.infer(frame), () => _clock.elapsedMicroseconds,
        onResult: widget.onResult ?? widget.producer?.submit);
    _authSubscription = widget.authChanges?.listen((_) {
      if (widget.sessionCurrent?.call() == false) {
        unawaited(_stop(reason: '로그인 또는 안내 세션이 종료되었습니다'));
      }
    }, onError: (Object _) {
      unawaited(_stop(reason: '로그인 상태를 확인할 수 없어 카메라를 중지했습니다'));
    });
    if (widget.previewPriority != null && widget.previewEngine != null) {
      _previewAudio = VisionScreenAudio(
          priority: widget.previewPriority!,
          engine: widget.previewEngine!,
          sessionGeneration: widget.previewScope,
          confirmationFrames: 3,
          requireDoorInBus: true,
          isCurrent: () =>
              mounted &&
              !_disposing &&
              _pump.active &&
              widget.sessionCurrent?.call() != false);
    }
    _pump.addListener(_changed);
    if (widget.bundledModel) unawaited(_loadBundledModel());
  }

  void _changed() {
    if (!mounted || _disposing) return;
    setState(() {});
    final item = _pump.observation;
    if (item != null && _pump.active && _pump.error == null) {
      _previewAudio?.observe(item.toDetectionResult(),
          age: Duration(
              microseconds:
                  _clock.elapsedMicroseconds - item.frame.receivedMicros));
    }
    if (_pump.error != null && _camera != null) {
      unawaited(_stop(reason: _pump.error!));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_stop(reason: '앱 비활성화 · 카메라 중지됨'));
    }
  }

  Future<void> _loadBundledModel() async {
    setState(() {
      _picking = true;
      _status = '통합 비전 v4 모델 준비 중';
    });
    try {
      final data = await rootBundle.load(
          'assets/models/yolo11n_unified_bus_obstacle_stop_v4_float32.tflite');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await compute(verifyModel, bytes);
      if (mounted && !_disposing) {
        setState(() {
          _model = bytes;
          _status = '통합 비전 v4 모델 준비 완료 · 카메라 시작을 눌러 주세요';
        });
      }
    } catch (_) {
      if (mounted && !_disposing) {
        setState(() => _status = '모델 준비 실패 · 다시 준비해 주세요');
      }
    } finally {
      if (mounted && !_disposing) setState(() => _picking = false);
    }
  }

  Future<void> _chooseModel() async {
    if (_starting || _camera != null || _picking) return;
    setState(() => _picking = true);
    try {
      final file = await FilePicker.pickFile(
          type: FileType.custom, allowedExtensions: ['tflite']);
      if (file == null) return;
      final length = await file.length();
      if (length == null || length <= 0 || length > 16 * 1024 * 1024) {
        throw const FormatException('모델 파일 크기가 잘못됐습니다.');
      }
      final bytes = await file.readAsBytes();
      await compute(verifyModel, bytes);
      if (mounted) {
        setState(() {
          _model = bytes;
          _status = '비전 모델 SHA256 확인 완료';
        });
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _model = null;
          _status = e.message;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _status = '모델 파일을 읽을 수 없습니다');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _start() async {
    if (!Platform.isAndroid || _model == null || _starting || _camera != null) {
      return;
    }
    await _stopping;
    if (!mounted || _disposing || _starting || _camera != null) return;
    final generation = ++_generation;
    setState(() {
      _starting = true;
      _status = '모델·카메라 준비 중';
    });
    try {
      if (widget.sessionCurrent?.call() == false) {
        throw StateError('Guidance session ended');
      }
      await widget.beforeStart?.call();
      if (!mounted ||
          _disposing ||
          generation != _generation ||
          widget.sessionCurrent?.call() == false) {
        await widget.onStop?.call();
        return;
      }
      await widget.producer?.retryPending(discardExpired: true);
      final worker = await VisionWorker.open(_model!);
      if (!mounted || generation != _generation) {
        await worker.close();
        return;
      }
      _worker = worker;
      final devices = await availableCameras();
      if (!mounted || generation != _generation) return;
      if (devices.isEmpty) throw CameraException('NoCamera', '');
      final wanted =
          _front ? CameraLensDirection.front : CameraLensDirection.back;
      final matches = devices.where((d) => d.lensDirection == wanted);
      if (matches.isEmpty) throw CameraException('LensUnavailable', '');
      _description = matches.first;
      final camera = CameraController(_description!, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _camera = camera;
      camera.addListener(() {
        if (_camera == camera && camera.value.hasError) {
          unawaited(_stop(reason: '카메라 연결이 소실되었습니다'));
        }
      });
      await camera.initialize();
      if (!mounted || generation != _generation) {
        await _stop();
        return;
      }
      _pump.start();
      _runTime
        ..reset()
        ..start();
      await camera.startImageStream((image) => _onFrame(image, generation));
      if (mounted && generation == _generation) {
        setState(() => _status = '휴대폰 내부 카메라 관찰 중');
      }
    } on CameraException catch (e) {
      final text = switch (e.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' =>
          '카메라 권한이 거부되었습니다. 앱 설정에서 허용해 주세요',
        'CameraAccessRestricted' => '기기 정책으로 카메라 접근이 제한되었습니다',
        'NoCamera' => '사용 가능한 카메라 장치가 없습니다',
        'LensUnavailable' => '선택한 전면/후면 카메라가 없습니다',
        _ => '카메라 초기화 실패 · 기기 및 카메라 사용 여부를 확인해 주세요',
      };
      await _stop(reason: text);
    } on VisionLeaseException {
      await _stop(reason: '서버 카메라 연결 실패 · 로그인 상태와 서버 연결을 확인한 뒤 다시 시작해 주세요');
    } on VisionProducerException catch (e) {
      await _stop(reason: e.message);
    } catch (_) {
      await _stop(reason: 'TFLite 모델 또는 네이티브 런타임을 시작할 수 없습니다');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onFrame(CameraImage image, int generation) {
    if (_disposing || generation != _generation) return;
    if (widget.sessionCurrent?.call() == false) {
      unawaited(_stop(reason: '안내 세션 종료 · 카메라 중지'));
      return;
    }
    final camera = _camera, description = _description;
    if (!_pump.active || camera == null || description == null) return;
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
                : image.format.group == ImageFormatGroup.bgra8888
                    ? 'bgra8888'
                    : 'unsupported';
    _pump.submit(VisionFrame(
        width: image.width,
        height: image.height,
        format: format,
        planes: image.planes
            .map((p) => FramePlane(Uint8List.fromList(p.bytes), p.bytesPerRow,
                p.bytesPerPixel ?? 1))
            .toList(),
        rotation: frameRotation(description.sensorOrientation, degrees,
            description.lensDirection == CameraLensDirection.front),
        mirror: description.lensDirection == CameraLensDirection.front,
        receivedAt: DateTime.now().toUtc(),
        receivedMicros: _clock.elapsedMicroseconds));
  }

  Future<void> _stop({String reason = '카메라 중지됨'}) {
    final previewStop = _previewAudio?.stop(notify: !_disposing);
    if (_stopping != null) return _stopping!;
    _generation++;
    final camera = _camera, worker = _worker;
    _camera = null;
    _worker = null;
    _runTime.stop();
    widget.producer?.cancel();
    final idle = _pump.stop();
    if (mounted && !_disposing) setState(() => _status = reason);
    final future = () async {
      try {
        if (camera?.value.isStreamingImages == true) {
          await camera!.stopImageStream();
        }
      } catch (_) {/* device already disconnected */}
      try {
        await camera?.dispose();
      } catch (_) {/* already disconnected */}
      await idle;
      await worker?.close();
      await previewStop;
      try {
        await widget.onStop?.call();
      } on VisionLeaseException {
        if (mounted && !_disposing) {
          setState(() => _status = '카메라 중지됨 · 서버 연결 해제 확인 불가');
        }
      }
    }();
    _stopping = future;
    return future.whenComplete(() {
      _stopping = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authSubscription?.cancel());
    _pump.removeListener(_changed);
    _previewAudio?.dispose(); // Retire UI callbacks before any lease release.
    unawaited(_stop());
    _pump.dispose();
    _model = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Scaffold(
          body: Center(child: Text('로컬 카메라 추론은 Android에서 지원합니다.')));
    }
    final item = _pump.observation;
    final busy = _starting || _picking || _stopping != null || _ending;
    return Scaffold(
        appBar: AppBar(title: const Text('카메라 인식')),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Wrap(spacing: 12, runSpacing: 8, children: [
                  if (_previewAudio != null)
                    FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFB03132)),
                        onPressed: _previewAudio!.stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('음성 중지')),
                  OutlinedButton.icon(
                      onPressed:
                          _camera == null && !_starting ? null : () => _stop(),
                      icon: const Icon(Icons.videocam_off_outlined),
                      label: const Text('카메라 중지')),
                ]))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const SizedBox(height: 12),
          if (item == null)
            const SizedBox(
                height: 160, child: Center(child: Text('현재 유효한 로컬 관찰이 없습니다')))
          else
            AspectRatio(
                aspectRatio: item.width / item.height,
                child: Stack(fit: StackFit.expand, children: [
                  Image.memory(item.jpeg,
                      fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(painter: _BoxPainter(item.boxes)),
                ])),
          if (item != null && item.boxes.isNotEmpty)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('현재 인식 결과',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          for (final box in item.boxes.take(3))
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                    '${visionClassNames[box.classId] ?? box.classId} · ${(box.confidence * 100).round()}%',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge)),
                          if (item.boxes.length > 3)
                            Text('외 ${item.boxes.length - 3}개 · 검출 이미지에서 확인'),
                        ]))),
          const SizedBox(height: 12),
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      '화면 기준의 정보성 시연입니다. 실제 거리·공간 방향·출입문·승차 가능 여부를 판단하지 않습니다.'))),
          ExpansionTile(
              title: const Text('실시간 카메라 Preview'),
              maintainState: true,
              children: [
                if (_camera?.value.isInitialized == true) ...[
                  const Text('실시간 카메라 Preview · 아래 bbox는 추론 프레임 기준'),
                  AspectRatio(
                      aspectRatio: _camera!.value.aspectRatio,
                      child: CameraPreview(_camera!)),
                ],
              ]),
          Text(widget.producer == null && widget.onResult == null
              ? 'LOCAL_DEMO · Backend 미연결 · 로컬 결과만 표시'
              : _pump.error != null
                  ? 'UNAVAILABLE · 온라인 전송 중지 · 로컬 시연은 앱 첫 화면에서 별도로 선택해 주세요'
                  : 'ONLINE 연결 경로 · 서버 수신 여부는 아래 서버 관찰에서 확인'),
          Text(widget.producer == null && widget.onResult == null
              ? '휴대폰 내부 관찰 · 서버로 전송하지 않습니다. 승차 판단에 사용하지 않습니다.'
              : _previewAudio == null
                  ? '현재 안내 세션으로 검출 결과만 전송합니다. 영상 업로드·자동 음성 안내는 없습니다.'
                  : '현재 안내 세션으로 검출 결과만 전송합니다. 영상 업로드·위험 안내는 없습니다. 화면 음향 시연은 직접 켠 경우만 출력합니다.'),
          Text(_pump.lost ? '카메라 프레임 수신 소실 또는 지연 · 관찰 만료' : _status),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: busy || _camera != null
                    ? null
                    : widget.bundledModel
                        ? _loadBundledModel
                        : _chooseModel,
                child: Text(widget.bundledModel ? '모델 다시 준비' : 'TFLite 모델 선택')),
            FilledButton(
                onPressed:
                    busy || _model == null || _camera != null ? null : _start,
                child: const Text('카메라 시작')),
          ]),
          if (_previewAudio != null)
            VisionScreenAudioPanel(
                audio: _previewAudio!,
                cameraActive: _pump.active,
                showStopButton: false),
          if (_previewAudio != null)
            ExpansionTile(
                title: const Text('WT901 Head Tracking (기본 OFF)'),
                subtitle: const Text('센서 연결·정면 보정·검증된 카메라 화각이 모두 필요'),
                maintainState: true,
                children: [
                  WitSensorPanel(
                      stateOnly: true, ensureReady: _ensureHeadTrackingReady),
                ]),
          if (widget.onEndSession != null)
            OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => _ending = true);
                        await _stop(reason: '세션 종료 · 카메라/전송 중지');
                        try {
                          await widget.onEndSession!();
                        } finally {
                          if (mounted) setState(() => _ending = false);
                        }
                      },
                child: const Text('세션 종료 · 카메라/전송 중지')),
          SwitchListTile(
              title: const Text('전면 카메라 사용'),
              value: _front,
              onChanged: busy || _camera != null
                  ? null
                  : (v) => setState(() => _front = v)),
          if (_worker != null)
            Text(
                'TFLite 로드 ${_worker!.loadMs.toStringAsFixed(1)}ms · warm-up ${_worker!.warmUpMs.toStringAsFixed(1)}ms'),
          if (widget.remoteApi != null &&
              (widget.producer != null || widget.remoteSessionId != null) &&
              _pump.active &&
              _pump.error == null &&
              _pump.processed > 0)
            VisionObservationPanel(
                key: ValueKey(_generation),
                sessionId: widget.remoteSessionId ?? widget.producer!.sessionId,
                ownerUid: widget.ownerUid,
                fetch: widget.remoteApi!.fetchVisionObservations,
                hideSpeechControls: true),
          ExpansionTile(
              title: const Text('인식 상세 정보'),
              maintainState: true,
              children: [
                if (item != null) VisionObservationPanel.localCamera(item),
                Text(
                    '처리 ${_pump.processed} · 최신 프레임 대체 ${_pump.replaced} · 만료 폐기 ${_pump.expired} · 중복/역순 거부 ${_pump.rejected}'),
                Text(
                    '처리 FPS ${_runTime.elapsedMilliseconds == 0 ? '0' : (_pump.processed * 1000 / _runTime.elapsedMilliseconds).toStringAsFixed(1)} · 앱 RSS ${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}MiB'),
                const Text('실기기 성능·발열·bbox 정합성 확인이 필요합니다.'),
              ]),
        ]));
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.boxes);
  final List<LocalBox> boxes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final color = switch (b.classId) {
        'bus' => Colors.greenAccent,
        'bus_door' => Colors.orangeAccent,
        'bus_stop' => Colors.cyanAccent,
        _ => Colors.amberAccent,
      };
      final rect = Rect.fromLTWH(b.x * size.width, b.y * size.height,
          b.w * size.width, b.h * size.height);
      canvas.drawRect(
          rect,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      final label = TextPainter(
          text: TextSpan(
              text: '${b.classId} ${(b.confidence * 100).round()}%',
              style: TextStyle(
                  color: color, backgroundColor: Colors.black87, fontSize: 12)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: size.width);
      label.paint(canvas, Offset(rect.left, rect.top));
    }
  }

  @override
  bool shouldRepaint(_BoxPainter oldDelegate) => oldDelegate.boxes != boxes;
}
