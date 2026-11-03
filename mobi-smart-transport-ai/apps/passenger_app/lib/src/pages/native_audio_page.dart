import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import '../services/api_base_url.dart';
import '../services/v3_agent_api_client.dart';
import 'local_spatial_verification_page.dart';
import '../services/native_directional_cue_output.dart';
import '../services/speech_priority_coordinator.dart';

/// Normal debug app entry to the existing manual audio controls. The existing
/// child page owns playback, STOP, Live Hold and cleanup. No new coordinator.
class NativeAudioPage extends StatefulWidget {
  const NativeAudioPage({super.key});
  @override
  State<NativeAudioPage> createState() => _NativeAudioPageState();
}

class _NativeAudioPageState extends State<NativeAudioPage> {
  bool get allowed =>
      kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  NativeDirectionalCueOutput? _output;
  FlutterSpeechEngine? _tts;
  @override
  void initState() {
    super.initState();
    if (allowed) {
      _output = NativeDirectionalCueOutput();
      _tts = FlutterSpeechEngine.platform(
          requireOfflineKoreanVoice: true,
          requestNativeFocus: true,
          diagnostic: _output!.recordTtsEvent);
    }
  }

  Future<void> _logoutAccount() async {
    final auth = FirebaseAuthSession.instance;
    final current = auth.captureRequestGuard();
    try {
      await V3AgentApiClient(
              baseUrl: resolveApiBaseUrl(), visionLeaseEnabled: true)
          .revokeVisionLease();
    } on VisionLeaseException {
      debugPrint('오디오 종료: 서버 Lease 회수 확인 불가');
    } finally {
      if (current()) await auth.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!allowed || _output == null || _tts == null) {
      return const Scaffold(
          body: Center(child: Text('Android debug 앱에서 음성·방향 확인을 사용할 수 있습니다.')));
    }
    return LocalSpatialVerificationPage(
        enabled: true,
        nativeStereoOnly: true,
        stopOnBackground: true,
        onLogout: _logoutAccount,
        output: _output!,
        tts: _tts!);
  }
}
