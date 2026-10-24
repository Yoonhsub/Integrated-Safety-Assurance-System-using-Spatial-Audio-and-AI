import 'package:flutter/material.dart';
import 'auth_gate.dart';
import 'auth_only_configuration.dart';
import 'firebase_auth_service.dart';

/// No business page, Backend client, camera, audio or guidance session is built.
class AuthOnlyApp extends StatelessWidget {
  const AuthOnlyApp({
    super.key,
    required this.configurationReady,
    required this.configuration,
    required this.requiredRole,
    required this.appLabel,
    this.session,
  });

  final bool configurationReady;
  final AuthOnlyConfiguration configuration;
  final String requiredRole;
  final String appLabel;
  final AuthSession? session;

  Widget _gate() => AuthGate(
        configurationReady: configurationReady,
        requiredRole: requiredRole,
        authOnly: configuration,
        session: session,
        appLabel: appLabel,
        builder: (_, __) => const SizedBox.shrink(),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '$appLabel 인증 테스트',
        theme: ThemeData(useMaterial3: true),
        home: _gate(),
        // Deep links must not reach the ordinary guidance/vision routes.
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _gate(),
        ),
      );
}
