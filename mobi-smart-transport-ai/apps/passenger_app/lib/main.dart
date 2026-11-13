import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'src/services/api_base_url.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? onlineIssue;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final config = FirebaseWebConfiguration.fromEnvironment();
    onlineIssue = androidApiConfigurationIssue(resolveApiBaseUrl(),
            release: kReleaseMode) ??
        (config.isCompleteForAndroid
            ? null
            : 'Android 로그인 설정이 준비되지 않았습니다. Firebase 설정을 확인해 주세요.');
  }
  const authOnly = AuthOnlyConfiguration.fromEnvironment();
  if (authOnly.enabled) {
    final configured =
        await FirebaseAuthSession.initializeWebApp(requiredRole: 'passenger');
    runApp(MobiApp(firebaseConfigured: configured));
    return;
  }
  // The Android app waits for Firebase before showing its feature selection.
  runApp(MobiApp(
      onlineConfigurationIssue: onlineIssue,
      firebaseInitialization: onlineIssue == null
          ? FirebaseAuthSession.initializeWebApp(requiredRole: 'passenger')
          : null));
}
