import 'package:flutter/material.dart';
import 'src/local_vision/local_vision_page.dart';

/// Explicit offline camera test entry point. No Firebase or protected API.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(title: 'MOBI 로컬 카메라 시험', home: LocalVisionPage()));
}
