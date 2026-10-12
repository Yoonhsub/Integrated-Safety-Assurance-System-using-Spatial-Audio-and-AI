import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'pages/home_page.dart';

class MobiApp extends StatelessWidget {
  const MobiApp({super.key, this.firebaseConfigured = false});

  final bool firebaseConfigured;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MOBI Driver App',
      theme: ThemeData(useMaterial3: true),
      home: AuthGate(
        configurationReady: firebaseConfigured,
        appLabel: 'MOBI 기사 앱',
        builder: (context, account) => const HomePage(),
      ),
    );
  }
}
