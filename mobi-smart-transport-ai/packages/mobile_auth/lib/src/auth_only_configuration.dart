import 'firebase_configuration.dart';

/// Build-time boundary for the isolated Firebase authentication UI check.
class AuthOnlyConfiguration {
  const AuthOnlyConfiguration({
    this.enabled = false,
    this.projectId = '',
    this.runId = '',
  });

  const AuthOnlyConfiguration.fromEnvironment()
      : enabled = const bool.fromEnvironment('MOBI_AUTH_ONLY'),
        projectId = const String.fromEnvironment('MOBI_FIREBASE_PROJECT_ID'),
        runId = const String.fromEnvironment('MOBI_AUTH_TEST_RUN_ID');

  final bool enabled;
  final String projectId;
  final String runId;

  bool get isValid =>
      !enabled ||
      (!const bool.fromEnvironment('MOBI_LOCAL_DEMO') &&
          projectId == 'mobi-auth-cloud-test' &&
          RegExp(r'^auth-[a-z0-9-]{7,48}$').hasMatch(runId));

  // Public Web registrations supplied from Firebase Console and reviewed offline.
  // Unknown configurations fail before Firebase Authentication is initialized.
  bool matchesWebConfiguration(FirebaseWebConfiguration config,
      {String? requiredRole}) {
    const ids = {
      'passenger': '1:189730626159:web:407d25db8c026703170b9a',
      'driver': '1:189730626159:web:b486ec4c18abf663170b9a',
    };
    return isValid &&
        config.projectId == projectId &&
        config.authDomain == 'mobi-auth-cloud-test.firebaseapp.com' &&
        config.messagingSenderId == '189730626159' &&
        config.apiKey == 'AIzaSyAfKjXX3LtVE9iaVmcSjXKxl0VIu1x6hAU' &&
        (requiredRole == null
            ? ids.values.contains(config.appId)
            : ids[requiredRole] == config.appId);
  }

  bool accepts(String uid, String role, Object? observedRun, String? driverId) {
    if (!isValid || observedRun != runId) return false;
    if (role == 'passenger') {
      return driverId == null &&
          {'ct-$runId-passenger-a', 'ct-$runId-passenger-b'}.contains(uid);
    }
    if (role == 'driver') {
      return (uid == 'ct-$runId-driver-a' &&
              driverId == 'ct-$runId-driver-502') ||
          (uid == 'ct-$runId-driver-b' && driverId == 'ct-$runId-driver-105');
    }
    return false;
  }
}
