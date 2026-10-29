import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'src/services/api_base_url.dart';
import 'src/local_backend/local_backend_probe.dart';

void main() {
  if (!kDebugMode ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !const bool.fromEnvironment('MOBI_ANDROID_LOCAL_BACKEND')) {
    throw StateError('Explicit Android local Backend debug entry required');
  }
  final url = resolveApiBaseUrl();
  validateLocalBackend(url);
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: LocalAndroidBackendPage(baseUrl: url)));
}

class LocalAndroidBackendPage extends StatefulWidget {
  const LocalAndroidBackendPage({super.key, required this.baseUrl});
  final String baseUrl;
  @override
  State<LocalAndroidBackendPage> createState() => _Page();
}

class _Page extends State<LocalAndroidBackendPage> with WidgetsBindingObserver {
  late final LocalBackendProbe probe;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    probe = LocalBackendProbe(baseUrl: widget.baseUrl)..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) probe.logout();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    probe.removeListener(_changed);
    probe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Android 로컬 Backend 시험')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Fake 신원·메모리 저장소 전용. Firebase·카메라·Safety Event·오디오 사용 안 함.'),
        Text(widget.baseUrl),
        Text(probe.status),
        Text('sessionId: ${probe.sessionId}'),
        Text('generation: ${probe.generation}'),
        FilledButton(
            onPressed: probe.busy ? null : probe.verify,
            child: const Text('Health → 세션 → polling → reset 검사')),
        OutlinedButton(
            onPressed: probe.busy ? null : probe.endSession,
            child: const Text('Fixture 관리자 종료 → 접근 거부 검사')),
        OutlinedButton(
            onPressed: probe.logout, child: const Text('로그아웃·요청 무효화')),
        OutlinedButton(
            onPressed: probe.relogin, child: const Text('동일 UID 새 로그인 세대')),
        for (final item in probe.records.reversed.take(40))
          Text(
              '${item['phase']} ${item['method'] ?? ''} ${item['path'] ?? ''} ${item['status'] ?? item['check'] ?? item['result'] ?? ''} ${item['attemptId'] ?? ''}'),
      ]));
}
