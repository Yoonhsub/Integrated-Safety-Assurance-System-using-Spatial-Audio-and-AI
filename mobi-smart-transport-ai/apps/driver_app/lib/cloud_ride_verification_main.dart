import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/pages/home_page.dart';
import 'src/services/backend_api_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final plan = CloudRidePlan.fromEnvironment(role: 'driver');
    final web = FirebaseWebConfiguration.fromEnvironment();
    if (!await FirebaseAuthSession.initializeWebApp(
        configuration: web, requiredRole: 'driver')) {
      throw StateError('Firebase configuration is unavailable');
    }
    final binding = plan.bind(
        session: FirebaseAuthSession.instance, web: web, role: 'driver');
    final api = BackendApiClient(
        baseUrl: plan.backendUrl,
        useMockData: false,
        publicClient: binding.publicClient,
        authClient: binding.authClient);
    runApp(MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AuthGate(
            configurationReady: true,
            session: binding.session,
            requiredRole: 'driver',
            appLabel: 'Firebase 기사 업무 검증',
            builder: (_, account) =>
                HomePage(apiClient: api, session: binding.session))));
  } catch (_) {
    runApp(const MaterialApp(
        home: Scaffold(
            body:
                Center(child: Text('검토·승인된 Firebase 업무 실행 계획이 없어 차단했습니다.')))));
  }
}
