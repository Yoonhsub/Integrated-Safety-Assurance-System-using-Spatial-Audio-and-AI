import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/pages/door_approach_demo_page.dart';
import 'src/services/spatial_verification_output.dart';
import 'src/services/browser_speech_stub.dart'
    if (dart.library.js_interop) 'src/services/browser_speech_web.dart';

Future<void> main() async {
  if (!kDebugMode ||
      !kIsWeb ||
      !const bool.fromEnvironment('MOBI_LOCAL_DOOR_APPROACH') ||
      !{'localhost', '127.0.0.1'}.contains(Uri.base.host)) {
    throw StateError('Explicit localhost debug door approach replay required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  for (final family in ['OfflineKorean', 'Roboto', 'monospace']) {
    await (FontLoader(family)..addFont(rootBundle.load('offline-test.ttf')))
        .load();
  }
  final speech = createBrowserSpeechEngine();
  if (speech == null) throw StateError('Browser TTS unavailable');
  runApp(MaterialApp(
      theme: ThemeData(fontFamily: 'OfflineKorean'),
      home: DoorApproachDemoPage(output: WebSpatialTestOutput(), tts: speech)));
}
