import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/pages/local_spatial_verification_page.dart';
import 'src/services/spatial_verification_output.dart';
import 'src/services/browser_speech_stub.dart'
    if (dart.library.js_interop) 'src/services/browser_speech_web.dart';

Future<void> main() async {
  const enabled = bool.fromEnvironment('MOBI_LOCAL_SPATIAL_VERIFICATION');
  if (!enabled ||
      !kDebugMode ||
      !kIsWeb ||
      !{'localhost', '127.0.0.1'}.contains(Uri.base.host)) {
    throw StateError('Explicit localhost Web debug verification required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final font = FontLoader('OfflineKorean')
    ..addFont(rootBundle.load('offline-test.ttf'));
  await font.load();
  runApp(MaterialApp(
      theme: ThemeData(fontFamily: 'OfflineKorean'),
      home: LocalSpatialVerificationPage(
          enabled: true,
          output: WebSpatialTestOutput(),
          tts: createBrowserSpeechEngine()!)));
}
