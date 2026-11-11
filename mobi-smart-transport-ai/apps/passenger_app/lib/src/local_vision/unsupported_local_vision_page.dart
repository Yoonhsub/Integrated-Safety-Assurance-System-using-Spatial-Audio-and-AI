import 'dart:async';
import 'vision_codec.dart';
import '../services/v3_agent_api_client.dart';
import 'package:flutter/material.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/spatial_verification_engine.dart';

class LocalVisionPage extends StatelessWidget {
  const LocalVisionPage(
      {super.key,
      V3AgentApiClient? remoteApi,
      String? ownerUid,
      Future<void> Function()? onEndSession,
      Future<void> Function()? beforeStart,
      Future<void> Function(LocalObservation)? onResult,
      Future<void> Function()? onStop,
      VoidCallback? onInputUnavailable,
      bool Function()? sessionCurrent,
      Stream<String?>? authChanges,
      Duration Function()? sessionNow,
      bool embedded = false,
      bool rearCameraOnly = false,
      String? remoteSessionId,
      bool bundledModel = false,
      SpeechPriorityCoordinator? previewPriority,
      SpatialVerificationEngine? previewEngine,
      String previewScope = 'camera-preview'});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('휴대폰 로컬 Vision')),
      body: const Center(
          child: Text(
              'Android 휴대폰에서 사용할 수 있습니다. 웹 카메라와 서버 관찰 기능은 기존 경로를 이용해 주세요.')));
}
