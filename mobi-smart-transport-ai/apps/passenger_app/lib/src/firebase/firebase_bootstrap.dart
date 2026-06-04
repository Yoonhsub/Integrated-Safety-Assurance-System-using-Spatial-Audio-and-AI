import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';

/// FlutterFire 클라이언트 초기화 부트스트랩.
///
/// 이 데모의 핵심 데이터 쓰기는 Flutter 클라이언트가 아니라 FastAPI 백엔드의
/// Firebase Admin SDK 를 통해 수행한다(`POST /firebase/initialize`).
/// 클라이언트 측 Firebase 초기화는 `lib/firebase_options.dart` 가 존재할 때만
/// 의미가 있으며, 본 데모는 web 플랫폼만 구성되어 있다(flutterfire configure --platforms=web).
///
/// 초기화 실패(예: 옵션이 없는 플랫폼)에도 앱이 죽지 않도록 try/catch 로 감싼다.
Future<void> bootstrapFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 3));
    if (kDebugMode) {
      debugPrint('FlutterFire 클라이언트 초기화 완료 (${defaultTargetPlatform.name}).');
    }
  } catch (error, stackTrace) {
    // web 외 플랫폼은 firebase_options.dart 에 구성이 없어 UnsupportedError 가 날 수 있다.
    // 데모 데이터 쓰기는 백엔드 Admin SDK 가 담당하므로 클라이언트 초기화 실패는 치명적이지 않다.
    if (kDebugMode) {
      debugPrint('FlutterFire 클라이언트 초기화 건너뜀/실패(무시하고 계속): $error');
      debugPrint('$stackTrace');
    }
  }
}
