import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'pages/home_page.dart';

class MobiApp extends StatelessWidget {
  const MobiApp(
      {super.key,
      this.firebaseConfigured = false,
      this.authSession,
      this.authOnly = const AuthOnlyConfiguration.fromEnvironment()});

  final bool firebaseConfigured;
  final AuthSession? authSession;
  final AuthOnlyConfiguration authOnly;

  @override
  Widget build(BuildContext context) {
    if (authOnly.enabled) {
      return AuthOnlyApp(
          configurationReady: firebaseConfigured,
          configuration: authOnly,
          requiredRole: 'driver',
          appLabel: 'MOBI 기사 앱',
          session: authSession);
    }
    return MaterialApp(
      title: 'MOBI Driver App',
      theme: ThemeData(useMaterial3: true),
      home: AuthGate(
        configurationReady: firebaseConfigured,
        requiredRole: 'driver',
        session: authSession,
        appLabel: 'MOBI 기사 앱',
        builder: (context, account) => const HomePage(),
      ),
    );
  }
}
