import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final configured =
      await FirebaseAuthSession.initializeWebApp(requiredRole: 'driver');
  runApp(MobiApp(firebaseConfigured: configured));
}
