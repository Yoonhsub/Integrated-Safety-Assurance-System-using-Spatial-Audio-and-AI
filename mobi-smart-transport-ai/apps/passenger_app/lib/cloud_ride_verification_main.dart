import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/pages/home_page.dart';

/// Opt-in target only; lib/main.dart and normal routing remain unchanged.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final plan = CloudRidePlan.fromEnvironment(role: 'passenger');
    final web = FirebaseWebConfiguration.fromEnvironment();
    if (!await FirebaseAuthSession.initializeWebApp(
        configuration: web, requiredRole: 'passenger')) {
      throw StateError('Firebase configuration is unavailable');
    }
    final binding = plan.bind(
        session: FirebaseAuthSession.instance, web: web, role: 'passenger');
    runApp(MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AuthGate(
            configurationReady: true,
            session: binding.session,
            requiredRole: 'passenger',
            appLabel: 'Firebase 승객 업무 검증',
            builder: (_, account) => HomePage.cloudVerification(
                binding: binding,
                agentName: '모비',
                onEditAgentName: () {},
                onReturnToModeSelection: () {}))));
  } catch (_) {
    // No fallback initialization, authentication bypass, or API call.
    runApp(const MaterialApp(
        home: Scaffold(
            body:
                Center(child: Text('검토·승인된 Firebase 업무 실행 계획이 없어 차단했습니다.')))));
  }
}
