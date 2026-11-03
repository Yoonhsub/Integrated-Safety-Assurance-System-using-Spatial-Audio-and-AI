import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'src/services/api_base_url.dart';
import 'src/local_backend/local_backend_probe.dart' show validateLocalBackend;
import 'src/local_vision/camera_backend_session.dart';
import 'src/local_vision/native_local_vision_page.dart';

void main() {
  if (!kDebugMode ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !const bool.fromEnvironment('MOBI_ANDROID_CAMERA_BACKEND')) {
    throw StateError('Explicit Android camera Backend debug entry required');
  }
  final base = resolveApiBaseUrl();
  validateLocalBackend(base);
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: LocalCameraBackendSetup(baseUrl: base)));
}

class LocalCameraBackendSetup extends StatefulWidget {
  const LocalCameraBackendSetup({super.key, required this.baseUrl});
  final String baseUrl;
  @override
  State<LocalCameraBackendSetup> createState() => _SetupState();
}

class _SetupState extends State<LocalCameraBackendSetup> {
  CameraBackendSession? connection;
  bool busy = false, ready = false;
  String status = 'PC 시험 서버와 단기 연결 파일을 준비해 주세요.';
  Future<void> _load() async {
    if (busy) return;
    setState(() => busy = true);
    CameraBackendSession? next;
    try {
      final file = await FilePicker.pickFile(
          type: FileType.custom, allowedExtensions: ['json']);
      if (file == null) return;
      final length = await file.length();
      if (length == null || length < 1 || length > 16384) {
        throw const FormatException();
      }
      final config = CameraBackendConfig.parse(
          utf8.decode(await file.readAsBytes()),
          baseUrl: widget.baseUrl);
      connection?.close();
      connection = null;
      ready = false;
      next = CameraBackendSession(config,
          diagnostic: (row) => debugPrint('CAMERA_BACKEND_TRACE $row'));
      await next.prepare();
      if (!mounted) {
        next.close();
        return;
      }
      setState(() {
        connection = next;
        status = '아래 sessionId를 PC 관리자에게 전달하고 Binding을 승인해 주세요.';
      });
    } catch (_) {
      next?.close();
      if (mounted) {
        setState(() => status = '연결 파일·ADB reverse·PC 시험 서버를 확인해 주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _bind() async {
    final current = connection;
    if (current == null || busy) return;
    setState(() => busy = true);
    try {
      await current.confirmBinding();
      if (mounted) setState(() => ready = true);
    } catch (_) {
      if (mounted) {
        setState(() => status = '현재 세션의 승인 Binding이 없습니다. PC 승인 후 다시 확인해 주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _end() async {
    final current = connection;
    var confirmed = true;
    try {
      await current?.end();
    } catch (_) {
      confirmed = false;
    } finally {
      if (mounted) {
        setState(() {
          ready = false;
          connection = null;
          status = confirmed
              ? '세션 종료 · 이전 관찰 및 자격 폐기'
              : '로컬 전송 종료 · 서버 종료 확인 실패, 기존 Lease 만료 정책 유지';
        });
      }
    }
  }

  @override
  void dispose() {
    connection?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = connection;
    if (ready && current?.producer != null) {
      return LocalVisionPage(
          key: ValueKey(current!.sessionId),
          producer: current.producer,
          remoteApi: current.api,
          ownerUid: current.config.passengerUid,
          onEndSession: _end);
    }
    return Scaffold(
        appBar: AppBar(title: const Text('Android Camera → Backend 로컬 시험')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('실제 카메라/TFLite 경로 · Preview 전용 · Firebase/안내/음향 없음'),
          const Text(
              '연결 파일에는 단기 Passenger/Producer 자격만 포함됩니다. 관리자 자격은 PC에만 둡니다.'),
          Text(widget.baseUrl),
          Text(status),
          if (current?.sessionId != null)
            SelectableText('sessionId: ${current!.sessionId}'),
          FilledButton(
              onPressed: busy ? null : _load,
              child: const Text('PC 연결 파일 선택 · 세션 준비')),
          OutlinedButton(
              onPressed: busy || current == null ? null : _bind,
              child: const Text('PC 승인 Binding 확인 · 카메라 열기')),
          OutlinedButton(
              onPressed: busy || current == null ? null : _end,
              child: const Text('세션 종료')),
        ]));
  }
}
