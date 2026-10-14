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

/// Phone-only observations. No backend, Producer identity, TTS or safety input.
class LocalVisionPage extends StatefulWidget {
  const LocalVisionPage({super.key});
  @override
  State<LocalVisionPage> createState() => _LocalVisionPageState();
}

class _LocalVisionPageState extends State<LocalVisionPage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch()..start();
  final _runTime = Stopwatch();
  late final FramePump _pump;
  Uint8List? _model;
  VisionWorker? _worker;
  CameraController? _camera;
  CameraDescription? _description;
  bool _starting = false, _picking = false, _front = false;
  bool _disposing = false;
  int _generation = 0;
  Future<void>? _stopping;
  String _status = '버스·문 모델 파일을 선택해 주세요';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pump = FramePump(
        (frame) => _worker!.infer(frame), () => _clock.elapsedMicroseconds);
    _pump.addListener(_changed);
  }

  void _changed() {
    if (!mounted || _disposing) return;
    setState(() {});
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
          _status = '버스·문 모델 SHA256 확인 완료';
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
    if (!mounted || _disposing) return;
    final generation = ++_generation;
    setState(() {
      _starting = true;
      _status = '모델·카메라 준비 중';
    });
    try {
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
      await camera.startImageStream(_onFrame);
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
    } catch (_) {
      await _stop(reason: 'TFLite 모델 또는 네이티브 런타임을 시작할 수 없습니다');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onFrame(CameraImage image) {
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
    if (_stopping != null) return _stopping!;
    _generation++;
    final camera = _camera, worker = _worker;
    _camera = null;
    _worker = null;
    _runTime.stop();
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
    _pump.removeListener(_changed);
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
    final busy = _starting || _picking || _stopping != null;
    return Scaffold(
        appBar: AppBar(title: const Text('휴대폰 로컬 Vision')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('휴대폰 내부 관찰 · 서버로 전송하지 않습니다. 승차 판단에 사용하지 않습니다.'),
          Text(_pump.lost ? '카메라 프레임 수신 소실 또는 지연 · 관찰 만료' : _status),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: busy || _camera != null ? null : _chooseModel,
                child: const Text('TFLite 모델 선택')),
            FilledButton(
                onPressed:
                    busy || _model == null || _camera != null ? null : _start,
                child: const Text('카메라 시작')),
            OutlinedButton(
                onPressed: _camera == null && !_starting ? null : () => _stop(),
                child: const Text('카메라 중지')),
          ]),
          SwitchListTile(
              title: const Text('전면 카메라 사용'),
              value: _front,
              onChanged: busy || _camera != null
                  ? null
                  : (v) => setState(() => _front = v)),
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
          if (item != null) ...[
            Text(item.boxes.isEmpty
                ? '버스·문 감지 없음'
                : item.boxes
                    .map((b) => b.classId == 'bus' ? '버스 감지' : '버스 문 감지')
                    .toSet()
                    .join(' · ')),
            Text(
                '추론 ${item.inferenceMs.toStringAsFixed(1)}ms · 처리 ${item.processingMs.toStringAsFixed(1)}ms'),
            Text(
                '프레임 수신 ${item.frame.receivedAt.toIso8601String()} · 실제 촬영 시각 미검증'),
          ],
          Text(
              '처리 ${_pump.processed} · 최신 프레임 대체 ${_pump.replaced} · 만료 폐기 ${_pump.expired}'),
          Text(
              '처리 FPS ${_runTime.elapsedMilliseconds == 0 ? '0' : (_pump.processed * 1000 / _runTime.elapsedMilliseconds).toStringAsFixed(1)} · 앱 RSS ${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}MiB'),
          const Text('실기기 성능·발열·bbox 정합성 확인이 필요합니다.'),
        ]));
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.boxes);
  final List<LocalBox> boxes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final color =
          b.classId == 'bus' ? Colors.greenAccent : Colors.orangeAccent;
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
