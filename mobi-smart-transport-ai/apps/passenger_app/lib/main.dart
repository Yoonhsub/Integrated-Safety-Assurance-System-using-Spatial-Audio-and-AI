import 'package:flutter/material.dart';
import 'src/app.dart';
import 'src/firebase/firebase_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 클라이언트 측 Firebase 초기화(선택). firebase_options.dart 가 없으면 안전하게 no-op.
  await bootstrapFirebase();
  runApp(const MobiApp());
}
