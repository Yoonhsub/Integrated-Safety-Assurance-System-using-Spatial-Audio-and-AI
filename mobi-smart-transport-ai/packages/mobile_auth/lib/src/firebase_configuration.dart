import 'package:firebase_core/firebase_core.dart';

/// Firebase web configuration is supplied per web app at build/run time.
/// Firebase API keys identify a web app; they are not Admin credentials.
class FirebaseWebConfiguration {
  const FirebaseWebConfiguration({
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
    required this.projectId,
    required this.authDomain,
  });

  factory FirebaseWebConfiguration.fromEnvironment() {
    return const FirebaseWebConfiguration(
      apiKey: String.fromEnvironment('MOBI_FIREBASE_API_KEY'),
      appId: String.fromEnvironment('MOBI_FIREBASE_APP_ID'),
      messagingSenderId: String.fromEnvironment(
        'MOBI_FIREBASE_MESSAGING_SENDER_ID',
      ),
      projectId: String.fromEnvironment('MOBI_FIREBASE_PROJECT_ID'),
      authDomain: String.fromEnvironment('MOBI_FIREBASE_AUTH_DOMAIN'),
    );
  }

  final String apiKey;
  final String appId;
  final String messagingSenderId;
  final String projectId;
  final String authDomain;

  bool get isComplete =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty &&
      authDomain.isNotEmpty;

  FirebaseOptions toFirebaseOptions() => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: messagingSenderId,
        projectId: projectId,
        authDomain: authDomain,
      );
}
