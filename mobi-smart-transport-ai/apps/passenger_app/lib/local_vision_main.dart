import 'package:flutter/material.dart';
import 'src/local_vision/local_vision_page.dart';

/// Explicit offline camera test entry point. No Firebase or protected API.
void main() {
  if (!const bool.fromEnvironment('MOBI_OFFLINE_CAMERA')) {
    throw StateError('로컬 카메라 시험은 MOBI_OFFLINE_CAMERA=true 격리 빌드가 필요합니다.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(title: 'MOBI 로컬 카메라 시험', home: LocalVisionPage()));
}
