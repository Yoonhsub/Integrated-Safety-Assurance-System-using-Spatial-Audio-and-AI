import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'src/pages/local_spatial_verification_page.dart';
import 'src/services/native_directional_cue_output.dart';
import 'src/services/speech_priority_coordinator.dart';

/// Explicit offline debug app only. No Auth/Backend/camera/sensors or auto sound.
void main() {
  if (!kDebugMode ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !const bool.fromEnvironment('MOBI_ANDROID_LOCAL_AUDIO')) {
    throw StateError('Explicit Android local audio debug entry required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final output = NativeDirectionalCueOutput();
  final tts = FlutterSpeechEngine.platform(
      requireOfflineKoreanVoice: true,
      requestNativeFocus: true,
      diagnostic: (event) {
        output.recordTtsEvent(event);
        debugPrint('ANDROID_AUDIO_TTS ${jsonEncode({'phase': event})}');
      });
  runApp(MaterialApp(
      home: LocalSpatialVerificationPage(
          enabled: true,
          nativeStereoOnly: true,
          mockBusControls: true,
          stopOnBackground: true,
          output: output,
          tts: tts)));
}
